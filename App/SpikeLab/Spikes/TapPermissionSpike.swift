import CoreGraphics
import Foundation
import PappuHarness
import Synchronization

/// Spike 2: event-tap type versus permission prompts, and the on-demand key tap (ACT-19).
///
/// What the design assumes, and this run checks:
/// 1. An active (`.defaultTap`) tap is created with the Accessibility grant alone, so users see one
///    permission prompt. A listen-only tap needs Input Monitoring, a second prompt. (PRD §12)
/// 2. A key-down tap can be installed when a surface opens and removed when it closes, cheaply
///    enough that nobody waits for it, and it sees a key pressed straight after. (ACT-19)
/// 3. A tap the system disabled can be detected and switched back on. (architecture §4.1)
/// 4. The Accessibility grant survives a rebuild when the signing certificate stays the same. (PRD §12)
///
/// What it cannot check: that another app receives an event we let through. We only see our own
/// tap. Spike 6 covers delivery.
struct TapPermissionSpike: Spike {
    let id = "spike-2-taps"
    let title = "2 · Event taps and permissions"
    let question = "Event-tap type versus permission prompts, including installing the key-down tap only while it is needed (ACT-19)."
    let instructions = """
        Run once per permission state and say which in the field below: nothing granted, Accessibility only, \
        Accessibility and Input Monitoring. Remove SpikeLab from both lists in System Settings between states. \
        Write down every system prompt you see, and when. When the log asks, click and scroll for a few seconds. \
        Then rebuild without changing anything else and run \
        again: the run compares itself with the previous one to see whether the grant survived.
        """

    let options = [
        SpikeOption(
            id: Option.listenOnly, title: "Try listen-only taps",
            detail: "Without Input Monitoring this is expected to make macOS show its prompt. Note whether it does.",
            defaultOn: true
        ),
        SpikeOption(
            id: Option.mouseWatch, title: "Count real mouse events",
            detail: "Waits 6 s for you to click, drag or scroll, to see whether the mouse taps are sent anything.",
            defaultOn: true
        ),
        SpikeOption(
            id: Option.stall, title: "Provoke a tap timeout",
            detail: "Blocks the key tap for 2 s. Keys you press meanwhile arrive late. Don't type during the run.",
            defaultOn: false
        ),
    ]

    private enum Option {
        static let listenOnly = "listen-only"
        static let mouseWatch = "mouse-watch"
        static let stall = "stall"
    }

    /// ACT-19 installs the tap while a surface is being put on screen, inside the 30 ms render stage.
    /// A third of that is the most it may take without becoming the thing people wait for.
    private static let installCeilingMs = 10.0
    private static let cycles = 50
    private static let deliverySamples = 100
    private static let mouseWatchSeconds = 6.0

    private static let mouseEvents: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    func run(recorder: RunRecorder, enabled: Set<String>) {
        let before = PermissionSnapshot.current()
        recorder.log("Permissions before: \(before.summary)")
        recorder.setParameter("permissionsBefore", before.summary)
        recorder.setParameter("keyTapCycles", String(Self.cycles))
        recorder.setParameter("installCeilingMs", String(Self.installCeilingMs))

        compareWithPreviousRun(recorder: recorder, permissions: before)

        let thread = TapThread(name: "spike.taps")
        defer { thread.stop() }

        let activeKeyTapWorks = creationMatrix(recorder: recorder, thread: thread, enabled: enabled, permissions: before)
        if enabled.contains(Option.mouseWatch) { mouseDelivery(recorder: recorder, thread: thread, enabled: enabled) }

        if activeKeyTapWorks {
            leaseCost(recorder: recorder, thread: thread)
            if before.postEvent {
                delivery(recorder: recorder, thread: thread)
                disableAndReenable(recorder: recorder, thread: thread)
                if enabled.contains(Option.stall) { timeout(recorder: recorder, thread: thread) }
            } else {
                recorder.observe("keyTap.delivery", .inconclusive, "Cannot post synthetic events without post-event access.")
            }
        } else {
            recorder.observe("keyTap.lease", .inconclusive, "No active key-down tap could be created, so ACT-19 was not measured.")
        }

        let after = PermissionSnapshot.current()
        recorder.setParameter("permissionsAfter", after.summary)
        if after != before {
            recorder.observe("permissions.changedDuringRun", .info, "\(before.summary) → \(after.summary)")
        }
        rememberThisRun(permissions: after)
    }

    // MARK: 1. Which taps can be created

    /// Returns whether an active key-down tap was created, which the later parts need.
    private func creationMatrix(
        recorder: RunRecorder, thread: TapThread, enabled: Set<String>, permissions: PermissionSnapshot
    ) -> Bool {
        var kinds: [(name: String, option: CGEventTapOptions)] = [("active", .defaultTap)]
        if enabled.contains(Option.listenOnly) { kinds.append(("listenOnly", .listenOnly)) }
        let eventSets: [(name: String, events: [CGEventType])] = [("mouse", Self.mouseEvents), ("keyDown", [.keyDown])]
        var activeKeyTapWorks = false

        for kind in kinds {
            for set in eventSets {
                let labels = ["tap": kind.name, "events": set.name]
                let tap = recorder.measure("tap.create", labels: labels) {
                    EventTap(events: set.events, option: kind.option, on: thread) { _, _ in .pass }
                }
                let created = tap != nil
                tap?.invalidate()
                if kind.option == .defaultTap, set.name == "keyDown" { activeKeyTapWorks = created }

                let key = "tap.\(kind.name).\(set.name).created"
                let state = "created=\(created) with \(permissions.summary)"
                switch (kind.option, permissions.accessibility, permissions.listenEvent) {
                case (.defaultTap, true, false):
                    // The case the whole permission design rests on.
                    recorder.observe(key, created ? .confirmed : .refuted, "Accessibility alone: \(state)", labels: labels)
                case (.listenOnly, _, false):
                    recorder.observe(key, created ? .refuted : .confirmed, "Expected to need Input Monitoring: \(state)", labels: labels)
                case (.defaultTap, false, _):
                    recorder.observe(key, created ? .refuted : .confirmed, "Expected to need Accessibility: \(state)", labels: labels)
                default:
                    recorder.observe(key, .info, state, labels: labels)
                }
            }
        }
        return activeKeyTapWorks
    }

    // MARK: 1b. Whether a mouse tap that can be created is also sent events

    /// Creating a tap proves little: macOS can hand one back and then send it nothing. Synthetic mouse
    /// events need post-event access, which the permission states of interest lack, so this counts real ones.
    private func mouseDelivery(recorder: RunRecorder, thread: TapThread, enabled: Set<String>) {
        var kinds: [(name: String, option: CGEventTapOptions)] = [("active", .defaultTap)]
        if enabled.contains(Option.listenOnly) { kinds.append(("listenOnly", .listenOnly)) }

        let counts = Mutex<[String: Int]>([:])
        let taps = kinds.compactMap { kind -> (name: String, tap: EventTap)? in
            let tap = EventTap(events: Self.mouseEvents, option: kind.option, on: thread) { _, _ in
                counts.withLock { $0[kind.name, default: 0] += 1 }
                return .pass
            }
            return tap.map { (kind.name, $0) }
        }
        guard !taps.isEmpty else {
            recorder.observe("tap.mouse.receivesEvents", .inconclusive, "No mouse tap could be created.")
            return
        }

        recorder.log("Click, drag or scroll anywhere for the next \(Int(Self.mouseWatchSeconds)) s.")
        Thread.sleep(forTimeInterval: Self.mouseWatchSeconds)
        for entry in taps { entry.tap.invalidate() }

        let seen = counts.withLock { $0 }
        for entry in taps {
            let count = seen[entry.name, default: 0]
            recorder.observe(
                "tap.\(entry.name).mouse.receivesEvents", count > 0 ? .confirmed : .inconclusive,
                count > 0 ? "\(count) real mouse events in \(Int(Self.mouseWatchSeconds)) s" : "No events: either none are sent, or nobody clicked.",
                labels: ["tap": entry.name, "events": "mouse"]
            )
        }
    }

    // MARK: 2. What the ACT-19 lease costs

    private func leaseCost(recorder: RunRecorder, thread: TapThread) {
        for _ in 0..<Self.cycles {
            let tap = recorder.measure("keyTap.install") {
                EventTap(events: [.keyDown], option: .defaultTap, on: thread) { _, _ in .pass }
            }
            recorder.measure("keyTap.remove") { tap?.invalidate() }
        }
        let result = recorder.finish()
        guard let install = result.measurements.first(where: { $0.name == "keyTap.install" })?.summary else { return }
        recorder.observe(
            "keyTap.lease.installIsCheap",
            install.p95 <= Self.installCeilingMs ? .confirmed : .refuted,
            String(format: "install p95 %.3f ms, max %.3f ms over %d cycles; ceiling %.0f ms",
                   install.p95, install.max, install.count, Self.installCeilingMs)
        )
    }

    // MARK: 3. Does a fresh tap see the next key

    private func delivery(recorder: RunRecorder, thread: TapThread) {
        let probe = Probe()
        var sawFirst = 0
        let attempts = 20

        // A new tap each time: what matters is the key pressed right after a surface opens.
        for _ in 0..<attempts {
            guard let tap = EventTap(events: [.keyDown], option: .defaultTap, on: thread, handler: probe.handler) else { break }
            if let latency = probe.postAndWait(timeout: .milliseconds(500)) {
                sawFirst += 1
                recorder.record("keyTap.firstEventAfterInstall", duration: latency)
            }
            tap.invalidate()
        }
        recorder.observe(
            "keyTap.lease.seesKeyPressedRightAfterInstall",
            sawFirst == attempts ? .confirmed : .refuted,
            "\(sawFirst) of \(attempts) events posted immediately after install reached the tap"
        )

        guard let tap = EventTap(events: [.keyDown], option: .defaultTap, on: thread, handler: probe.handler) else { return }
        defer { tap.invalidate() }
        var lost = 0
        for _ in 0..<Self.deliverySamples {
            if let latency = probe.postAndWait(timeout: .milliseconds(500)) {
                recorder.record("keyTap.eventDelivery", duration: latency)
            } else {
                lost += 1
            }
        }
        recorder.observe("keyTap.delivery.lost", lost == 0 ? .confirmed : .refuted, "\(lost) of \(Self.deliverySamples) synthetic key events never reached the tap")
    }

    // MARK: 4. Disabled taps

    private func disableAndReenable(recorder: RunRecorder, thread: TapThread) {
        let probe = Probe()
        guard let tap = EventTap(events: [.keyDown], option: .defaultTap, on: thread, handler: probe.handler) else { return }
        defer { tap.invalidate() }

        tap.isEnabled = false
        let reportsDisabled = !tap.isEnabled
        // Nothing swallows this one, so the frontmost app gets an F13. That is the point of the check.
        let seenWhileDisabled = probe.postAndWait(timeout: .milliseconds(150)) != nil
        tap.isEnabled = true
        let seenAfter = probe.postAndWait(timeout: .milliseconds(500)) != nil

        recorder.observe(
            "tap.reenable",
            reportsDisabled && !seenWhileDisabled && tap.isEnabled && seenAfter ? .confirmed : .refuted,
            "reportsDisabled=\(reportsDisabled) seenWhileDisabled=\(seenWhileDisabled) seenAfterReenable=\(seenAfter)"
        )
    }

    /// Two ways to learn that the system switched a tap off: the `tapDisabledByTimeout` notice and
    /// polling `tapIsEnabled`. They are reported apart, because the product needs to know which one
    /// it can rely on. A second key is posted halfway through the stall, as a user's would be: what
    /// happens to the keys queued behind a stuck tap is the part that hurts people.
    private func timeout(recorder: RunRecorder, thread: TapThread) {
        let probe = Probe()
        let noticeArrived = DispatchSemaphore(value: 0)
        let stalled = DispatchSemaphore(value: 0)
        let stallOnce = Mutex(true)

        guard let tap = EventTap(events: [.keyDown], option: .defaultTap, on: thread, handler: { type, event in
            if type == .tapDisabledByTimeout {
                noticeArrived.signal()
                return .pass
            }
            if Probe.isOurs(event), stallOnce.withLock({ let first = $0; $0 = false; return first }) {
                Thread.sleep(forTimeInterval: 2)
                stalled.signal()
                return .swallow
            }
            return probe.handler(type, event)
        }) else { return }
        defer { tap.invalidate() }

        recorder.log("Stalling the key tap for 2 s…")
        probe.post()
        Thread.sleep(forTimeInterval: 1)
        let disabledDuringStall = !tap.isEnabled
        let queued = probe.post()
        _ = stalled.wait(timeout: .now() + 5)
        let disabledWhenStallEnded = !tap.isEnabled

        // The notice comes through the same callback, so it can only arrive once the stall is over.
        let waitStart = ContinuousClock.now
        let noticed = noticeArrived.wait(timeout: .now() + 2) == .success
        let noticeDelay = waitStart.duration(to: .now)
        let disabledAfterWait = !tap.isEnabled
        let queuedLatency = probe.takeLatency(of: queued)

        tap.isEnabled = true
        let recovered = probe.postAndWait(timeout: .milliseconds(500)) != nil

        let polls = "during stall=\(disabledDuringStall) at stall end=\(disabledWhenStallEnded) 2 s later=\(disabledAfterWait)"
        recorder.observe(
            "tap.timeout.pollDetects",
            disabledDuringStall || disabledWhenStallEnded || disabledAfterWait ? .confirmed : .refuted,
            "tapIsEnabled reported disabled: \(polls)"
        )
        recorder.observe(
            "tap.timeout.noticeReceived", noticed ? .confirmed : .refuted,
            noticed
                ? String(format: "tapDisabledByTimeout arrived %.1f ms after the stall ended", noticeDelay.milliseconds)
                : "no tapDisabledByTimeout within 2 s of the stall ending"
        )
        recorder.observe(
            "tap.timeout.keyQueuedBehindStall", .info,
            queuedLatency.map { String(format: "reached the tap %.0f ms after it was posted", $0.milliseconds) }
                ?? "never reached the tap: the system routed it past the stuck tap, or dropped it"
        )
        recorder.observe("tap.timeout.recovers", recovered ? .confirmed : .refuted, "events flow again after tapEnable: \(recovered)")
    }

    // MARK: 5. Does the grant survive a rebuild

    private static let previousRunKey = "spike2.previousRun"

    private func compareWithPreviousRun(recorder: RunRecorder, permissions: PermissionSnapshot) {
        let signing = HarnessEnvironment.current().signing
        recorder.observe(
            "signing.identity", .info,
            signing.map { $0.isAdHoc ? "ad-hoc (the grant is tied to this exact build)" : "signed by \($0.authority ?? "unknown")" } ?? "unsigned"
        )
        guard Self.answersForItsOwnPermissions else {
            recorder.observe(
                "tcc.responsibleProcess", .inconclusive,
                "Not started by launchd (parent pid \(getppid())). Started from a shell, macOS answers permission questions "
                    + "about the terminal, so nothing here says what SpikeLab itself was granted. Use Scripts/run-spike.sh."
            )
            return
        }
        guard let previous = UserDefaults.standard.dictionary(forKey: Self.previousRunKey),
              let previousHash = previous["codeHash"] as? String,
              let previousTrusted = previous["accessibility"] as? Bool,
              let hash = signing?.codeHash
        else { return }

        guard previousHash != hash else {
            recorder.log("Same build as the previous run, so nothing to learn about rebuilds.")
            return
        }
        guard previousTrusted else {
            recorder.observe("tcc.grantSurvivesRebuild", .inconclusive, "New build, but the previous run had no Accessibility grant to lose.")
            return
        }
        let sameAuthority = (previous["authority"] as? String) == signing?.authority && signing?.isAdHoc == false
        let detail = "previous build trusted; this build trusted=\(permissions.accessibility); same certificate=\(sameAuthority)"
        if sameAuthority {
            recorder.observe("tcc.grantSurvivesRebuild", permissions.accessibility ? .confirmed : .refuted, detail)
        } else {
            // Ad-hoc or a changed certificate: losing the grant is what PRD §12 predicts.
            recorder.observe("tcc.grantLostWithoutStableCertificate", permissions.accessibility ? .refuted : .confirmed, detail)
        }
    }

    private static var answersForItsOwnPermissions: Bool { getppid() == 1 }

    private func rememberThisRun(permissions: PermissionSnapshot) {
        guard Self.answersForItsOwnPermissions else { return }
        let signing = HarnessEnvironment.current().signing
        UserDefaults.standard.set(
            ["codeHash": signing?.codeHash ?? "", "authority": signing?.authority ?? "", "accessibility": permissions.accessibility],
            forKey: Self.previousRunKey
        )
    }
}

/// Posts tagged F13 key-downs and times their arrival at a tap. The tap swallows them, so no app
/// sees a key nobody pressed.
private final class Probe: Sendable {
    private static let tag: Int64 = 0x5041_5050_0000_0000 // "PAPP" in the high half, sequence below
    private static let tagMask: Int64 = ~0xFFFF_FFFF
    private static let f13: CGKeyCode = 105

    private struct State {
        var sequence: Int64 = 0
        var postedAt: [Int64: ContinuousClock.Instant] = [:]
        var latency: [Int64: Duration] = [:]
    }

    private let state = Mutex(State())
    private let arrived = DispatchSemaphore(value: 0)

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) & tagMask == tag
    }

    var handler: EventTap.Handler {
        { [self] type, event in
            guard type == .keyDown, Self.isOurs(event) else { return .pass }
            let now = ContinuousClock.now
            let sequence = event.getIntegerValueField(.eventSourceUserData) & ~Self.tagMask
            state.withLock { state in
                if let posted = state.postedAt.removeValue(forKey: sequence) {
                    state.latency[sequence] = posted.duration(to: now)
                }
            }
            arrived.signal()
            return .swallow
        }
    }

    @discardableResult
    func post() -> Int64 {
        let sequence = state.withLock { state in
            state.sequence += 1
            return state.sequence
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: Self.f13, keyDown: true) else { return sequence }
        event.setIntegerValueField(.eventSourceUserData, value: Self.tag | sequence)
        state.withLock { $0.postedAt[sequence] = .now }
        event.post(tap: .cghidEventTap)
        return sequence
    }

    /// Nil when the event has not reached the tap.
    func takeLatency(of sequence: Int64) -> Duration? {
        state.withLock { $0.latency.removeValue(forKey: sequence) }
    }

    /// Nil when the event did not reach the tap in time.
    func postAndWait(timeout: Duration) -> Duration? {
        let sequence = post()
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout.milliseconds * 1_000_000))
        while arrived.wait(timeout: deadline) == .success {
            if let latency = state.withLock({ $0.latency.removeValue(forKey: sequence) }) { return latency }
        }
        return nil
    }
}
