import Darwin
import Foundation
import PappuCore
import PappuDiagnostics
import PappuJSBridge
@testable import PappuRuntime
import Synchronization
import Testing

/// SEC-2 and §10.7: the watchdog's rule, and what the client does when it fires.
@Suite struct JSHostWatchdogTests {
    // MARK: The rule

    private static let limits = JSHostWatchdog.Limits(memoryLimit: 1_000, cpuSpan: .seconds(10), interval: .seconds(1))

    @Test func memoryOverTheLimitIsAnOverrunAtOnce() {
        var meter = JSHostWatchdog.Meter(limits: Self.limits)
        let start = ContinuousClock.now
        #expect(meter.observe(.init(cpuTime: .zero, footprint: 999), at: start) == nil)
        #expect(meter.observe(.init(cpuTime: .zero, footprint: 1_001), at: start + .seconds(1))
            == .memory(footprint: 1_001, limit: 1_000))
    }

    @Test func aCoreKeptBusyForTheSpanIsAnOverrun() {
        var meter = JSHostWatchdog.Meter(limits: Self.limits)
        let start = ContinuousClock.now
        var overrun: JSHostWatchdog.Overrun?
        for second in 0...10 where overrun == nil {
            overrun = meter.observe(.init(cpuTime: .seconds(second), footprint: 0), at: start + .seconds(second))
            if second < 10 { #expect(overrun == nil) }
        }
        #expect(overrun == .cpu(busyFor: .seconds(10)))
    }

    /// SEC-2: no fixed timeout. A script that waits costs no CPU and is never stopped, and one that
    /// takes a break starts the span again.
    @Test func waitingOrTakingABreakIsNotAnOverrun() {
        var waiting = JSHostWatchdog.Meter(limits: Self.limits)
        let start = ContinuousClock.now
        for second in 0...100 {
            #expect(waiting.observe(.init(cpuTime: .milliseconds(second), footprint: 10), at: start + .seconds(second)) == nil)
        }

        var bursty = JSHostWatchdog.Meter(limits: Self.limits)
        var cpu = Duration.zero
        for second in 0...30 {
            // Busy for nine seconds in every ten.
            if second > 0, second % 10 != 0 { cpu += .seconds(1) }
            #expect(bursty.observe(.init(cpuTime: cpu, footprint: 10), at: start + .seconds(second)) == nil)
        }
    }

    @Test func theExplanationSaysWhichLimitAndNothingElse() {
        let memory = JSHostWatchdog.Overrun.memory(footprint: 2_048 * 1_048_576, limit: 1_536 * 1_048_576)
        #expect(memory.explanation.contains("2048 MB"))
        #expect(memory.explanation.contains("1536 MB"))
        #expect(JSHostWatchdog.Overrun.cpu(busyFor: .seconds(31)).explanation.contains("31 s"))
    }

    /// The app's sampler reads a real process: this one.
    @Test func theProcessSamplerReadsAProcess() throws {
        let usage = try #require(ProcessUsageSampler.usage(of: getpid()))
        #expect(usage.footprint > 1_000_000)
        #expect(usage.cpuTime > .zero)
        #expect(ProcessUsageSampler.usage(of: 0) == nil)
        // A helper in this process has no process of its own, so it is not watched.
        #expect(ProcessUsageSampler().usage(of: InProcessJSHost.Connection(events: { _ in }, calls: { _, _ in })) == nil)
    }

    // MARK: The client

    /// A helper whose footprint is whatever the test says.
    final class Gauge: JSHostUsageSampling {
        let footprint = Mutex<UInt64>(0)
        let cpu = Mutex<Duration>(.zero)

        func usage(of connection: any JSHostConnection) -> JSHostWatchdog.Usage? {
            JSHostWatchdog.Usage(cpuTime: cpu.withLock { $0 }, footprint: footprint.withLock { $0 })
        }
    }

    final class Suspensions: Sendable {
        let owners = Mutex<[String]>([])
    }

    struct Setup {
        let transport = InProcessJSHost()
        let console = DebugConsole()
        let gauge = Gauge()
        let suspensions = Suspensions()
        let client: JSHostClient
        let package: URL

        init(cpuSpan: Duration = .seconds(60)) throws {
            client = JSHostClient(
                transport: transport,
                console: console,
                grace: .milliseconds(100),
                watchdog: JSHostWatchdog.Limits(memoryLimit: 1_000, cpuSpan: cpuSpan, interval: .milliseconds(10)),
                sampler: gauge
            )
            let suspensions = suspensions
            client.whenSuspended { owner in suspensions.owners.withLock { $0.append(owner) } }
            package = FileManager.default.temporaryDirectory.appendingPathComponent("js-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        }

        func job(_ script: String, owner: String = "ext-a", name: String = "Extension A") -> JavaScriptRunRequest {
            JavaScriptRunRequest(
                owner: owner,
                generation: "1",
                extensionName: name,
                directory: package,
                action: JavaScriptAction(source: .inline(script)),
                text: "hello",
                matchedText: "hello"
            )
        }

        func kinds(_ source: String) -> [ConsoleEntry.Kind] {
            console.entries.filter { $0.source == source }.map(\.kind)
        }
    }

    /// A runaway is charged to the extension that was running, which fails with the reason in the
    /// Debug Console; the helper is restarted and the next action runs.
    @Test func aRunawayIsKilledAndChargedToWhatWasRunning() async throws {
        let setup = try Setup()
        let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        setup.gauge.footprint.withLock { $0 = 5_000 }
        #expect(await hanging.result() == .failed)
        #expect(setup.transport.current?.wasKilled == true)
        #expect(setup.kinds("Extension A") == [.overran, .crashed])
        #expect(setup.console.entries.first?.text.contains("memory") == true)

        setup.gauge.footprint.withLock { $0 = 0 }
        #expect(await setup.client.start(setup.job("return 'again'"))?.result() == .returned("again"))
        #expect(setup.transport.opened == 2)
    }

    /// The done-when of M3 week 5: three attributed crashes suspend the extension, and only it.
    @Test func threeAttributedOverrunsSuspendTheExtension() async throws {
        let setup = try Setup()
        for _ in 0..<JSHostClient.suspensionThreshold {
            setup.gauge.footprint.withLock { $0 = 0 }
            let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
            setup.gauge.footprint.withLock { $0 = 5_000 }
            #expect(await hanging.result() == .failed)
        }
        #expect(setup.client.isSuspended("ext-a"))
        #expect(setup.kinds("Extension A").filter { $0 == .crashed }.count == 3)
        #expect(setup.kinds("Extension A").last == .suspended)
        try await eventually { setup.suspensions.owners.withLock { $0 } == ["ext-a"] }
        #expect(setup.suspensions.owners.withLock { $0 } == ["ext-a"])

        setup.gauge.footprint.withLock { $0 = 0 }
        #expect(await setup.client.start(setup.job("return 'x'")) == nil)
        #expect(await setup.client.start(setup.job("return 'b'", owner: "ext-b", name: "Extension B"))?.result() == .returned("b"))

        // Resume: it runs again, with no crashes held against it.
        setup.client.resume("ext-a")
        #expect(await setup.client.start(setup.job("return 'back'"))?.result() == .returned("back"))
    }

    /// A core kept busy for the span is a runaway; a script that waits is not, however long it waits.
    @Test func aBusyHelperIsKilledAndAWaitingOneIsNot() async throws {
        let setup = try Setup(cpuSpan: .milliseconds(100))
        let waiting = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.transport.current?.wasKilled == false)
        #expect(await waiting.cancel() == .stopped)

        // Once it is running, the gauge says two cores' worth of CPU for every second that passes.
        let busy = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        let start = ContinuousClock.now
        let gauge = setup.gauge
        let ticking = Task {
            while !Task.isCancelled {
                gauge.cpu.withLock { $0 = start.duration(to: .now) * 2 }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { ticking.cancel() }
        #expect(await busy.result() == .failed)
        #expect(!setup.client.isSuspended("ext-a"))
        #expect(setup.kinds("Extension A").suffix(2) == [.overran, .crashed])
        #expect(setup.console.entries.last { $0.kind == .overran }?.text.contains("processor") == true)
    }

    /// §10.7: a helper that goes while an extension's code is loading suspends it on the first crash.
    @Test func aCrashWhileLoadingSuspendsAtOnce() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("js-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("module.exports = {}".utf8).write(to: package.appendingPathComponent("Config.js"))
        let transport = SilentDescribes()
        let console = DebugConsole()
        let client = JSHostClient(transport: transport, console: console, describeLimit: .seconds(30))
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            transport.current?.close()
        }
        let described = await client.describe(ModuleDescribeRequest(
            owner: "ext-a",
            generation: "1",
            extensionName: "Extension A",
            directory: package,
            module: ModuleSource(source: .file("Config.js"), isTypeScript: false)
        ))
        guard case .failure = described else {
            Issue.record("A helper lost while describing is a failure")
            return
        }
        #expect(client.isSuspended("ext-a"))
        // Lost while loading the package or while describing it, it is the same charge; only the
        // latter adds the describe's own failure after it.
        #expect(Array(console.entries.map(\.kind).prefix(2)) == [.crashed, .suspended])
    }

    /// A cancel that kills the helper is not charged, and neither is a kill from the watchdog for an
    /// extension whose run was already being cancelled.
    @Test func aCancelledRunIsNotCharged() async throws {
        let setup = try Setup()
        let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        #expect(await hanging.cancel() == .stopped)
        setup.gauge.footprint.withLock { $0 = 5_000 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!setup.kinds("Extension A").contains(.crashed))
        #expect(!setup.client.isSuspended("ext-a"))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
