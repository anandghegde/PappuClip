import Foundation
import PappuCore
import PappuHarness
import XPC

/// Spike 5: what a sandboxed JavaScript helper without the JIT costs, and whether `XPCSession` carries it.
///
/// What the design assumes, and this run checks:
/// 1. A warm helper populates inside the population stage: ≤ 15 ms a function, 30 ms for all of them. (JS-16, JS-19)
/// 2. A cold helper does not, which is why it is started at launch and population is skipped when it is cold. (architecture §10.6)
/// 3. `XPCSession` with `Codable` messages is enough transport, including a blocking call from the
///    helper back to the app while the app waits on the helper. (architecture §10.2)
/// 4. One VM per extension on its own thread means a slow extension holds up nobody else. (architecture §10.1)
/// 5. The sandbox leaves the helper no network and no files, and without `allow-jit` no JIT memory. (SEC-1)
/// 6. The app can watch the helper's CPU and memory from outside, and kill and re-warm it. (architecture §10.7)
///
/// launchd will not start a service again until ten seconds after a start that ended early ("Service only ran
/// for 0 seconds. Pushing respawn out by 10 seconds."). So every cold round lets its helper live past that before
/// telling it to go, or the figure is launchd's delay and not a start; and the delay is measured once, on purpose,
/// because it is also what a helper that crashes while warming up would cost.
///
/// The warm helper's memory budget is set from this spike (PRD §11.1), so memory is reported and not judged.
///
/// What it cannot check: real extensions. The fixtures are synthetic, because the corpus arrives in M2.
/// Needs no permission at all.
struct JSHelperSpike: Spike {
    let id = "spike-5-js-helper"
    let title = "5 · JavaScript in a sandboxed helper"
    let question = """
        JavaScriptCore in a sandboxed XPC helper: startup time, warm-helper memory, pre-warming on mouse-down, \
        host-proxied network, and interpreter-only performance without the JIT entitlement.
        """
    let instructions = """
        Needs no permission and no hands. Close heavy apps first, because startup time is sensitive to load, \
        and run it headless a few times: the first run after a build also pays for the system's first look at \
        the helper's signature. Afterwards run App/SpikeFixtures/bench.js in the jsc tool, with and without --useJIT=false, \
        for the JIT side of the comparison.
        """

    let options = [
        SpikeOption(
            id: Option.scale, title: "Fifty VMs",
            detail: "Loads fifty extensions to get memory per VM, the figure the helper's budget is set from.", defaultOn: true
        ),
        SpikeOption(
            id: Option.watchdog, title: "Runaway and watchdog",
            detail: "Sends a VM into an endless loop, watches its CPU from the app, kills the helper and re-warms it.", defaultOn: true
        ),
        SpikeOption(
            id: Option.benchmark, title: "CPU benchmark",
            detail: "SpikeFixtures/bench.js inside the helper, about half a second of interpreter-only JavaScript.", defaultOn: true
        ),
    ]

    private enum Option {
        static let scale = "scale"
        static let watchdog = "watchdog"
        static let benchmark = "benchmark"
    }

    private static let coldStarts = 6
    /// A helper younger than this when it goes is started again late. launchd counts whole seconds.
    private static let respawnThrottle: Duration = .seconds(11)
    private static let warmPings = 200
    private static let populations = 100
    private static let largeSelectionBytes = 100_000
    private static let selectionSizes = [4_000, 16_000, 50_000]
    private static let scaledVMs = 50

    func run(recorder: RunRecorder, enabled: Set<String>) {
        guard let fixtures = Fixtures.load() else {
            recorder.observe("fixtures", .inconclusive, "SpikeFixtures is missing from the app bundle.")
            return
        }
        recorder.setParameter("fixtures", fixtures.extensions.map { "\($0.id):\($0.source.utf8.count)B" }.joined(separator: " "))
        recorder.setParameter("selectionBytes", String(fixtures.selection.utf8.count))

        coldStart(recorder: recorder, fixtures: fixtures)

        guard let helper = quickRespawn(recorder: recorder) ?? connect(recorder: recorder) else { return }
        defer { helper.close() }
        sandbox(helper, recorder: recorder)
        warmPing(helper, recorder: recorder)
        let loaded = load(fixtures.extensions, into: helper, recorder: recorder)
        guard loaded else { return }
        populate(helper, fixtures: fixtures, recorder: recorder)
        hostCalls(helper, recorder: recorder)
        concurrency(helper, fixtures: fixtures, recorder: recorder)
        if enabled.contains(Option.benchmark) { benchmark(helper, fixtures: fixtures, recorder: recorder) }
        if enabled.contains(Option.scale) { scale(helper, fixtures: fixtures, recorder: recorder) }
        if enabled.contains(Option.watchdog) { watchdog(helper, fixtures: fixtures, recorder: recorder) }
    }

    // MARK: Cold

    /// A fresh helper process each time: to the first answer, and to the first populated bar.
    private func coldStart(recorder: RunRecorder, fixtures: Fixtures) {
        var processes: Set<Int32> = []
        for round in 0..<Self.coldStarts {
            let start = ContinuousClock.now
            guard let helper = try? HelperConnection() else {
                recorder.observe("transport.sessionOpens", .refuted, "XPCSession(xpcService:) threw on round \(round).")
                return
            }
            guard (try? helper.send(JSHostRequest(.ping))) != nil else {
                recorder.observe("transport.sessionOpens", .refuted, "The first ping got no answer on round \(round).")
                helper.close()
                return
            }
            // The first run after a build pays for more than a process, so it is kept apart.
            let labels = ["round": round == 0 ? "first" : "later"]
            recorder.record("cold.toFirstReply", labels: labels, duration: start.duration(to: .now))

            for fixture in fixtures.extensions {
                _ = try? helper.send(JSHostRequest(.load, extensionID: fixture.id, source: fixture.source))
            }
            recorder.record("cold.toWarm", labels: labels, duration: start.duration(to: .now))
            for fixture in fixtures.extensions {
                _ = try? helper.send(JSHostRequest(.populate, extensionID: fixture.id, input: fixtures.selection))
            }
            recorder.record("cold.toFirstPopulation", labels: labels, duration: start.duration(to: .now))

            if let status = try? helper.send(JSHostRequest(.status)).status { processes.insert(status.pid) }
            outliveTheThrottle(helper, recorder: recorder)
            _ = try? helper.send(JSHostRequest(.exit))
            helper.close()
            Thread.sleep(forTimeInterval: 0.5)
        }
        recorder.observe("transport.sessionOpens", .confirmed, "\(Self.coldStarts) sessions opened and answered.")
        recorder.observe(
            "cold.eachRoundWasAFreshProcess", processes.count == Self.coldStarts ? .confirmed : .refuted,
            "\(processes.count) different pids in \(Self.coldStarts) rounds. Refuted means launchd kept a process and the cold figures are not cold."
        )

        let result = recorder.finish()
        let population = recorder.budgets.budget(for: .population, on: .accessibility).milliseconds
        let cutoff = recorder.budgets.hardCutoff.milliseconds
        if let cold = result.p95("cold.toFirstPopulation", labels: ["round": "later"]) {
            recorder.observe(
                "cold.helperMissesThePopulationStage", cold > population ? .confirmed : .refuted,
                "Cold start to first population p95 \(format(cold)) ms against \(format(population)) ms. Confirmed is the case for "
                    + "starting the helper at launch and for skipping population when it is cold."
            )
            recorder.observe(
                "cold.helperFitsTheHardCutoff", cold <= cutoff ? .confirmed : .refuted,
                "p95 \(format(cold)) ms against the \(format(cutoff)) ms cutoff, with nothing else in the attempt counted."
            )
        }
    }

    /// Lets a helper go at once and asks for another, which is what a crash while warming up looks like to launchd.
    /// - Returns: The helper that came back, to carry on with.
    private func quickRespawn(recorder: RunRecorder) -> HelperConnection? {
        guard let first = try? HelperConnection(), (try? first.send(JSHostRequest(.ping))) != nil else { return nil }
        _ = try? first.send(JSHostRequest(.exit))
        first.close()
        Thread.sleep(forTimeInterval: 0.5)

        recorder.log("Asking for a helper right after one left early. launchd is expected to hold this back for ten seconds.")
        let start = ContinuousClock.now
        guard let second = try? HelperConnection(), (try? second.send(JSHostRequest(.ping))) != nil else { return nil }
        let waited = start.duration(to: .now)
        recorder.record("cold.afterAnEarlyExit", duration: waited)
        recorder.observe(
            "launchd.holdsBackAQuickRespawn", waited > .seconds(5) ? .confirmed : .refuted,
            "\(format(waited.milliseconds)) ms to the first reply. Confirmed means a helper that dies inside its first ten seconds, "
                + "killed or crashed, leaves the app without one for the rest of them, whatever the app does."
        )
        return second
    }

    /// Waits until the helper is old enough that launchd starts its successor at once.
    private func outliveTheThrottle(_ helper: HelperConnection, recorder: RunRecorder) {
        guard let uptime = try? helper.send(JSHostRequest(.status)).status?.uptimeMs else { return }
        let remaining = Self.respawnThrottle - .milliseconds(Int(uptime))
        if remaining > .zero { Thread.sleep(forTimeInterval: remaining.milliseconds / 1_000) }
    }

    // MARK: Warm

    private func connect(recorder: RunRecorder) -> HelperConnection? {
        guard let helper = try? HelperConnection(), (try? helper.send(JSHostRequest(.ping))) != nil else {
            recorder.observe("transport.sessionOpens", .refuted, "The session for the warm measurements did not open.")
            return nil
        }
        return helper
    }

    private func sandbox(_ helper: HelperConnection, recorder: RunRecorder) {
        guard let status = try? helper.send(JSHostRequest(.status)).status else { return }
        recorder.setParameter("helperPid", String(status.pid))
        recorder.observe(
            "sandbox.helperIsContained", status.sandboxContainer && !status.canReadOutsideContainer ? .confirmed : .refuted,
            "container=\(status.sandboxContainer) canReadTheRealHome=\(status.canReadOutsideContainer)"
        )
        recorder.observe(
            "sandbox.noNetwork", status.loopbackConnectErrno == EPERM ? .confirmed : .refuted,
            "connect() to the loopback gave errno \(status.loopbackConnectErrno) (\(String(cString: strerror(status.loopbackConnectErrno)))). "
                + "EPERM is the sandbox refusing; ECONNREFUSED would be a helper that may use the network."
        )
        recorder.observe(
            "sandbox.noJITMemory", status.jitMemoryAvailable ? .refuted : .confirmed,
            status.jitMemoryAvailable
                ? "mmap(MAP_JIT) with execute permission succeeded, so JavaScriptCore can compile."
                : "mmap(MAP_JIT) with execute permission was refused, so JavaScriptCore interprets."
        )
        recordFootprint("idle, no VM", helper: helper, recorder: recorder)
    }

    /// The readiness check the app sends on mouse-down (JS-19).
    private func warmPing(_ helper: HelperConnection, recorder: RunRecorder) {
        for _ in 0..<Self.warmPings {
            _ = exchange(JSHostRequest(.ping), as: "warm.ping", with: helper, recorder: recorder)
        }
    }

    private func load(_ extensions: [Fixtures.Extension], into helper: HelperConnection, recorder: RunRecorder) -> Bool {
        for fixture in extensions {
            let reply = exchange(
                JSHostRequest(.load, extensionID: fixture.id, source: fixture.source), as: "warm.load",
                labels: ["extension": fixture.id], with: helper, recorder: recorder
            )
            guard let reply, reply.ok else {
                recorder.observe("fixtures.load", .inconclusive, "\(fixture.id) did not load: \(reply?.error ?? "no reply")")
                return false
            }
        }
        recordFootprint("3 VMs loaded", helper: helper, recorder: recorder)
        return true
    }

    private func populate(_ helper: HelperConnection, fixtures: Fixtures, recorder: RunRecorder) {
        var actionCounts: [String: Int] = [:]
        for _ in 0..<Self.populations {
            let start = ContinuousClock.now
            for fixture in fixtures.extensions {
                let reply = exchange(
                    JSHostRequest(.populate, extensionID: fixture.id, input: fixtures.selection), as: "warm.populate",
                    labels: ["extension": fixture.id], with: helper, recorder: recorder
                )
                actionCounts[fixture.id] = reply?.actionTitles?.count ?? -1
            }
            recorder.record("warm.populate.allInSequence", duration: start.duration(to: .now))
        }
        recorder.observe(
            "fixtures.populated", actionCounts.values.allSatisfy { $0 > 0 } ? .confirmed : .refuted,
            actionCounts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value) actions" }.joined(separator: ", ")
        )

        // In parallel, the way the app would ask: every VM has its own thread.
        for _ in 0..<Self.populations {
            let start = ContinuousClock.now
            let group = DispatchGroup()
            for fixture in fixtures.extensions {
                group.enter()
                helper.sendAsync(JSHostRequest(.populate, extensionID: fixture.id, input: fixtures.selection)) { _ in group.leave() }
            }
            group.wait()
            recorder.record("warm.populate.allInParallel", duration: start.duration(to: .now))
        }

        // Sizes on the way to the large one, because the cost is in the text and a limit has to be put somewhere.
        let large = String(repeating: fixtures.selection + "\n", count: Self.largeSelectionBytes / max(fixtures.selection.utf8.count, 1) + 1)
        recorder.setParameter("largeSelectionBytes", String(large.utf8.count))
        for bytes in Self.selectionSizes {
            let text = String(large.prefix(bytes))
            for _ in 0..<20 {
                for fixture in fixtures.extensions {
                    _ = exchange(
                        JSHostRequest(.populate, extensionID: fixture.id, input: text), as: "warm.populate.bySize",
                        labels: ["extension": fixture.id, "bytes": String(bytes)], with: helper, recorder: recorder
                    )
                }
            }
        }
        for _ in 0..<20 {
            for fixture in fixtures.extensions {
                _ = exchange(
                    JSHostRequest(.populate, extensionID: fixture.id, input: large), as: "warm.populate.largeSelection",
                    labels: ["extension": fixture.id], with: helper, recorder: recorder
                )
            }
        }

        let result = recorder.finish()
        let perFunction = recorder.budgets.populationPerFunction.milliseconds
        let aggregate = recorder.budgets.budget(for: .population, on: .accessibility).milliseconds
        let worst = fixtures.extensions.compactMap { fixture in
            result.p95("warm.populate.roundTrip", labels: ["extension": fixture.id]).map { (fixture.id, $0) }
        }.max { $0.1 < $1.1 }
        if let worst {
            recorder.observe(
                "warm.populationFitsPerFunction", worst.1 <= perFunction ? .confirmed : .refuted,
                "Slowest fixture \(worst.0): round trip p95 \(format(worst.1)) ms against \(format(perFunction)) ms."
            )
        }
        for series in ["warm.populate.allInSequence", "warm.populate.allInParallel"] {
            guard let p95 = result.p95(series) else { continue }
            recorder.observe(
                series == "warm.populate.allInSequence" ? "warm.populationFitsTheStage.inSequence" : "warm.populationFitsTheStage.inParallel",
                p95 <= aggregate ? .confirmed : .refuted,
                "\(fixtures.extensions.count) functions, p95 \(format(p95)) ms against \(format(aggregate)) ms."
            )
        }
        let worstLarge = fixtures.extensions.compactMap { fixture in
            result.p95("warm.populate.largeSelection.roundTrip", labels: ["extension": fixture.id]).map { (fixture.id, $0) }
        }.max { $0.1 < $1.1 }
        if let worstLarge {
            recorder.observe(
                "warm.largeSelectionFitsPerFunction", worstLarge.1 <= perFunction ? .confirmed : .refuted,
                "\(large.utf8.count) bytes, slowest fixture \(worstLarge.0): p95 \(format(worstLarge.1)) ms against \(format(perFunction)) ms. "
                    + "Refuted means a size limit on what population is given, or the deadline doing its work."
            )
        }
    }

    // MARK: Helper to app

    /// The blocking form of a host call, which is the shape `XMLHttpRequest` proxied by the app would take:
    /// the app is inside `sendSync` to the helper while the helper is inside `sendSync` to the app.
    private func hostCalls(_ helper: HelperConnection, recorder: RunRecorder) {
        let id = "small"
        helper.answerHostCalls { call in JSHostCallReply(value: call.method == "httpRequest" ? "{\"status\":200,\"body\":\"canned\"}" : call.argument) }

        let done = DispatchSemaphore(value: 0)
        let answer = Box<String>()
        helper.sendAsync(JSHostRequest(.evaluate, extensionID: id, script: "JSON.parse(hostCall('httpRequest', 'https://example.org/')).body")) { reply in
            answer.value = reply?.value
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success, answer.value == "canned" else {
            recorder.observe(
                "transport.blockingHostCallWorks", .refuted,
                "No answer in 3 s, or the wrong one (\(answer.value ?? "nothing")). XPCSession cannot carry the blocking form this way; "
                    + "the fallback is NSXPCConnection (architecture §10.2)."
            )
            return
        }
        recorder.observe("transport.blockingHostCallWorks", .confirmed, "JavaScript called the app, blocked, and got the app's answer, over one session.")

        for _ in 0..<100 {
            _ = exchange(JSHostRequest(.evaluate, extensionID: id, script: "1 + 1"), as: "warm.evaluate", with: helper, recorder: recorder)
            _ = exchange(
                JSHostRequest(.evaluate, extensionID: id, script: "hostCall('echo', 'x')"), as: "warm.evaluateWithHostCall",
                with: helper, recorder: recorder
            )
        }
        let result = recorder.finish()
        if let plain = result.p50("warm.evaluate.roundTrip"), let withCall = result.p50("warm.evaluateWithHostCall.roundTrip") {
            recorder.observe("transport.hostCallCost", .info, "A blocking host call adds about \(format(withCall - plain)) ms at the median.")
        }
    }

    /// One VM busy for a few hundred milliseconds, and the others asked to populate meanwhile. Twice: with the
    /// busy VM's reply handed off to its queue, and with it answered in line from the message handler.
    private func concurrency(_ helper: HelperConnection, fixtures: Fixtures, recorder: RunRecorder) {
        let busy = "var until = Date.now() + 600; var n = 0; while (Date.now() < until) { n++; } n"
        var worst: [String: Double] = [:]
        var rounds: [String: Int] = [:]
        for (reply, kind) in [("handedOff", JSHostRequest.Kind.evaluate), ("inLine", .evaluateInLine)] {
            let done = DispatchSemaphore(value: 0)
            helper.sendAsync(JSHostRequest(kind, extensionID: "large", script: busy)) { _ in done.signal() }
            Thread.sleep(forTimeInterval: 0.05)
            var answered = 0
            while done.wait(timeout: .now()) != .success, answered < 200 {
                for id in ["small", "regex"] {
                    _ = exchange(
                        JSHostRequest(.populate, extensionID: id, input: fixtures.selection), as: "busyNeighbour.populate",
                        labels: ["extension": id, "reply": reply], with: helper, recorder: recorder
                    )
                }
                _ = exchange(JSHostRequest(.ping), as: "busyNeighbour.ping", labels: ["reply": reply], with: helper, recorder: recorder)
                answered += 1
            }
            if answered >= 200 { done.wait() }
            rounds[reply] = answered

            let result = recorder.finish()
            worst[reply] = ["small", "regex"].compactMap {
                result.max("busyNeighbour.populate.roundTrip", labels: ["extension": $0, "reply": reply])
            }.max()
        }

        let perFunction = recorder.budgets.populationPerFunction.milliseconds
        let independent: Finding.Outcome = if let slowest = worst["handedOff"], slowest <= perFunction { .confirmed } else { .refuted }
        recorder.observe(
            "helper.aBusyVMHoldsUpNobodyElse", independent,
            "Replies handed off to the VM's queue (XPCReceivedMessage.handoffReply): \(rounds["handedOff"] ?? 0) rounds answered while "
                + "another VM span for 600 ms, slowest neighbour \(worst["handedOff"].map(format) ?? "n/a") ms."
        )
        let serialised: Finding.Outcome = if let slowest = worst["inLine"], slowest > 100 { .confirmed } else { .refuted }
        recorder.observe(
            "helper.inLineRepliesSerialiseTheHelper", serialised,
            "The same with the busy VM answered in line, as the plain Codable handler does: slowest neighbour "
                + "\(worst["inLine"].map(format) ?? "n/a") ms. Confirmed means per-VM threads are not enough; the replies have to be handed off."
        )
    }

    // MARK: Interpreter

    private func benchmark(_ helper: HelperConnection, fixtures: Fixtures, recorder: RunRecorder) {
        for round in 0..<3 {
            guard let value = try? helper.send(JSHostRequest(.evaluate, extensionID: "small", script: fixtures.benchmark)).value else { continue }
            for part in value.split(separator: ";") {
                let pair = part.split(separator: "=")
                guard pair.count == 2, let ms = Double(pair[1]) else { continue }
                recorder.record("benchmark.inHelper", labels: ["part": String(pair[0])], value: ms)
            }
            if round == 0 { recorder.log("Benchmark in the helper: \(value)") }
        }
        recorder.observe(
            "benchmark.compareWithJIT", .info,
            "Run App/SpikeFixtures/bench.js in /System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc, with and without "
                + "--useJIT=false, on the same machine. The helper should match the second and the ratio to the first is what the entitlement would buy."
        )
    }

    // MARK: Memory

    private func scale(_ helper: HelperConnection, fixtures: Fixtures, recorder: RunRecorder) {
        guard let before = footprint(of: helper) else { return }
        let existing = fixtures.extensions.count
        for index in existing..<Self.scaledVMs {
            let fixture = fixtures.extensions[index % fixtures.extensions.count]
            let id = "\(fixture.id)-\(index)"
            _ = try? helper.send(JSHostRequest(.load, extensionID: id, source: fixture.source))
            _ = try? helper.send(JSHostRequest(.populate, extensionID: id, input: fixtures.selection))
        }
        recordFootprint("\(Self.scaledVMs) VMs loaded", helper: helper, recorder: recorder)
        guard let after = footprint(of: helper) else { return }
        let perVM = (after - before) / Double(Self.scaledVMs - existing)
        recorder.record("memory.perVM", unit: "MB", value: perVM)
        recorder.observe(
            "memory.perVM", .info,
            "\(format(before)) MB with \(existing) VMs, \(format(after)) MB with \(Self.scaledVMs): about \(format(perVM)) MB a VM. "
                + "The warm helper's budget is set from this (PRD §11.1)."
        )

        _ = try? helper.send(JSHostRequest(.unloadAll))
        Thread.sleep(forTimeInterval: 2)
        recordFootprint("after unloading every VM", helper: helper, recorder: recorder)
        if let released = footprint(of: helper) {
            recorder.observe(
                "memory.unloadGivesItBack", released < before + (after - before) / 2 ? .confirmed : .refuted,
                "\(format(released)) MB two seconds after dropping every VM. Refuted means a memory-pressure teardown has to restart the process."
            )
        }
        // The later parts expect the three fixtures.
        for fixture in fixtures.extensions {
            _ = try? helper.send(JSHostRequest(.load, extensionID: fixture.id, source: fixture.source))
        }
    }

    private func footprint(of helper: HelperConnection) -> Double? {
        (try? helper.send(JSHostRequest(.status)).status).map { Double($0.footprintBytes) / 1_048_576 }
    }

    private func recordFootprint(_ state: String, helper: HelperConnection, recorder: RunRecorder) {
        guard let status = try? helper.send(JSHostRequest(.status)).status else { return }
        let inside = Double(status.footprintBytes) / 1_048_576
        recorder.record("memory.footprint", unit: "MB", labels: ["state": state], value: inside)
        // The watchdog reads this from outside (architecture §10.7), so the two have to agree.
        if let outside = ProcessUsage(pid: status.pid) {
            recorder.record("memory.footprint.seenFromTheApp", unit: "MB", labels: ["state": state], value: Double(outside.footprintBytes) / 1_048_576)
        }
        recorder.log("Helper footprint, \(state): \(format(inside)) MB.")
    }

    // MARK: Watchdog

    private func watchdog(_ helper: HelperConnection, fixtures: Fixtures, recorder: RunRecorder) {
        guard let pid = try? helper.send(JSHostRequest(.status)).status?.pid, let resting = ProcessUsage(pid: pid) else {
            recorder.observe("watchdog.appCanSeeTheHelper", .refuted, "proc_pid_rusage on the helper failed from the app.")
            return
        }
        recorder.observe("watchdog.appCanSeeTheHelper", .confirmed, "proc_pid_rusage reads the sandboxed helper's CPU time and footprint from the app.")
        // Old enough that what is measured after the kill is a start, and not launchd holding one back.
        outliveTheThrottle(helper, recorder: recorder)

        let failed = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        helper.sendAsync(JSHostRequest(.evaluate, extensionID: "small", script: "while (true) {}")) { _ in failed.signal() }

        // A runaway is a VM that has had a whole core for half a second.
        var previous = resting
        var previousTime = ContinuousClock.now
        var busySince: ContinuousClock.Instant?
        var detected = false
        while start.duration(to: .now) < .seconds(5) {
            Thread.sleep(forTimeInterval: 0.1)
            guard let usage = ProcessUsage(pid: pid) else { break }
            let now = ContinuousClock.now
            let share = Double(usage.cpuNanoseconds - previous.cpuNanoseconds) / (previousTime.duration(to: now).milliseconds * 1_000_000)
            (previous, previousTime) = (usage, now)
            busySince = share > 0.8 ? (busySince ?? now) : nil
            if let busySince, busySince.duration(to: now) >= .milliseconds(500) {
                detected = true
                break
            }
        }
        guard detected else {
            recorder.observe("watchdog.seesARunaway", .refuted, "An endless loop did not show as CPU time within 5 s.")
            kill(pid, SIGKILL)
            return
        }
        recorder.record("watchdog.toDetection", duration: start.duration(to: .now))
        recorder.observe("watchdog.seesARunaway", .confirmed, "The loop showed as a full core of CPU time, sampled from the app.")

        let killed = ContinuousClock.now
        kill(pid, SIGKILL)
        let told = failed.wait(timeout: .now() + 3) == .success
        if told { recorder.record("watchdog.killToFailedInvocation", duration: killed.duration(to: .now)) }
        recorder.observe(
            "watchdog.killFailsTheInvocation", told ? .confirmed : .refuted,
            told ? "The pending send failed once the helper was killed, so the app can explain the failure."
                : "The pending send was still waiting 3 s after the kill."
        )

        // Back to warm: a new process with the extensions loaded again.
        guard let fresh = try? HelperConnection(), (try? fresh.send(JSHostRequest(.ping))) != nil else {
            recorder.observe("watchdog.helperComesBack", .refuted, "No new helper answered after the kill.")
            return
        }
        defer { fresh.close() }
        for fixture in fixtures.extensions {
            _ = try? fresh.send(JSHostRequest(.load, extensionID: fixture.id, source: fixture.source))
        }
        recorder.record("watchdog.killToWarmAgain", duration: killed.duration(to: .now))
        let newPid = try? fresh.send(JSHostRequest(.status)).status?.pid
        recorder.observe(
            "watchdog.helperComesBack", newPid != nil && newPid != pid ? .confirmed : .refuted,
            "pid \(pid) → \(newPid.map(String.init) ?? "none"), warm again \(format(killed.duration(to: .now).milliseconds)) ms after the kill."
        )
    }

    // MARK: Plumbing

    /// One request, recorded twice: the round trip as the app sees it, and the part spent inside the helper.
    /// The difference is what the transport costs.
    private func exchange(
        _ request: JSHostRequest, as name: String, labels: [String: String] = [:], with helper: HelperConnection, recorder: RunRecorder
    ) -> JSHostReply? {
        let start = ContinuousClock.now
        let reply = try? helper.send(request)
        let elapsed = start.duration(to: .now)
        guard let reply else { return nil }
        recorder.record("\(name).roundTrip", labels: labels, duration: elapsed)
        if let inside = reply.helperMs { recorder.record("\(name).inHelper", labels: labels, value: inside) }
        return reply
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: -

/// One session with the helper. `XPCSession` is thread-safe and not marked `Sendable`.
final class HelperConnection: @unchecked Sendable {
    private let session: XPCSession
    private let answers = Box<@Sendable (JSHostCall) -> JSHostCallReply>()

    init() throws {
        let answers = answers
        session = try XPCSession(
            xpcService: JSHostService.name,
            incomingMessageHandler: { (call: JSHostCall) -> (any Encodable)? in answers.value?(call) ?? JSHostCallReply(value: "") },
            cancellationHandler: nil
        )
    }

    func answerHostCalls(_ answer: @escaping @Sendable (JSHostCall) -> JSHostCallReply) {
        answers.value = answer
    }

    func send(_ request: JSHostRequest) throws -> JSHostReply {
        try session.sendSync(request)
    }

    func sendAsync(_ request: JSHostRequest, reply: @escaping @Sendable (JSHostReply?) -> Void) {
        do {
            try session.send(request) { (result: Result<JSHostReply, any Error>) in reply(try? result.get()) }
        } catch {
            reply(nil)
        }
    }

    func close() {
        session.cancel(reason: "The spike is done with it.")
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// What the watchdog can see of another process without any entitlement.
struct ProcessUsage {
    let cpuNanoseconds: UInt64
    let footprintBytes: UInt64

    init?(pid: Int32) {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // Mach time units; on Apple silicon they are not nanoseconds.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        cpuNanoseconds = (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
        footprintBytes = usage.ri_phys_footprint
    }
}

struct Fixtures {
    struct Extension {
        let id: String
        let source: String
    }

    let extensions: [Extension]
    let benchmark: String
    /// A paragraph with one of everything the detectors look for. Made up, so there is nothing private to record.
    let selection = """
        Ada, the invoice for $1,250.00 is due on 2026-10-14. Details are at https://example.org/invoices/4821?ref=mail \
        and questions go to accounts@example.org or +44 20 7946 0958. The banner colour is #3366cc, the parcel is \
        1Z999AA10123456784 and the build flag is 0x1F. See you on Oct 3rd, 2026.
        """

    static func load() -> Fixtures? {
        guard let folder = Bundle.main.url(forResource: "SpikeFixtures", withExtension: nil) else { return nil }
        func read(_ name: String) -> String? { try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
        guard let small = read("small.js"), let regex = read("regex.js"), let benchmark = read("bench.js") else { return nil }
        return Fixtures(
            extensions: [Extension(id: "small", source: small), Extension(id: "regex", source: regex), Extension(id: "large", source: large(around: small))],
            benchmark: benchmark
        )
    }

    /// A bundled library ahead of a small extension: a quarter of a megabyte that has to be parsed and is mostly never called.
    private static func large(around small: String) -> String {
        var library = "var library = {};\n"
        for index in 0..<2_500 {
            library += "library.f\(index) = function (a, b) { var t = a * \(index) + (b || 0); return t % 7 === 0 ? String(t) : t + \(index % 13); };\n"
        }
        return library + small
    }
}

extension RunResult {
    func p95(_ name: String, labels: [String: String] = [:]) -> Double? {
        measurements.first { $0.name == name && $0.labels == labels }?.summary?.p95
    }

    func max(_ name: String, labels: [String: String] = [:]) -> Double? {
        measurements.first { $0.name == name && $0.labels == labels }?.summary?.max
    }

    func p50(_ name: String, labels: [String: String] = [:]) -> Double? {
        measurements.first { $0.name == name && $0.labels == labels }?.summary?.p50
    }
}
