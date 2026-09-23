import CoreGraphics
import PappuSelection
import PappuTestSupport
import Testing

/// Runs `body` against a service watched by a monitor, and returns everything the service put on its
/// stream. As in `EventTapServiceTests`, the stream ends when the service goes.
private func watched(
    refusing refused: Set<TapKind> = [],
    _ body: (EventTapService, TapHealthMonitor, FakeTapInstaller, FakeHealthTriggers) throws -> Void
) async rethrows -> [EventTapService.Output] {
    let installer = FakeTapInstaller(refusing: refused)
    let triggers = FakeHealthTriggers()
    let stream: AsyncStream<EventTapService.Output>
    do {
        let service = EventTapService(installer: installer)
        let monitor = TapHealthMonitor(service: service, triggers: triggers)
        stream = service.events
        try body(service, monitor, installer, triggers)
    }
    var all: [EventTapService.Output] = []
    for await output in stream { all.append(output) }
    return all
}

/// ACT-15. The tap's own disabled callback is covered by `EventTapServiceTests`; this is the other
/// half, the three moments a tap can have gone away with nobody in the callback to say so.
@Suite struct TapHealthMonitorTests {
    @Test func nothingIsCheckedBeforeTheMonitorIsStarted() async {
        _ = await watched { service, monitor, _, triggers in
            service.start()
            #expect(!triggers.send(.wake))
            #expect(monitor.checks.total == 0)
            #expect(monitor.checks.last == nil)
        }
    }

    @Test func everyNoticeRunsAHealthCheck() async {
        _ = await watched { service, monitor, _, triggers in
            service.start()
            monitor.start()
            for trigger in HealthTrigger.allCases { #expect(triggers.send(trigger)) }

            #expect(monitor.checks.total == HealthTrigger.allCases.count)
            #expect(monitor.checks.counts == [.wake: 1, .sessionBecameActive: 1, .applicationActivated: 1])
            #expect(monitor.checks.last?.mouse == .healthy)
            #expect(monitor.checks.last?.key == .notWanted)
        }
    }

    @Test func aTapThatWentAwayWhileTheMachineSleptIsRebuiltOnWake() async throws {
        let seen = try await watched { service, monitor, installer, triggers in
            service.start()
            monitor.start()
            try #require(installer.tap(.mouse)).losePort()

            triggers.send(.wake)
            #expect(monitor.checks.last?.mouse == .rebuilt)
            #expect(installer.installCount(.mouse) == 2)
            installer.send(.pointer(PointerEvent(kind: .down, location: .zero, timestampNs: 0, windowNumber: 1)), to: .mouse)
        }
        // The consumer is told, because a mouse-up may have gone by while the tap was not there.
        #expect(seen.first == .interrupted)
    }

    @Test func aGrantGivenWhileAnotherAppWasInFrontIsPickedUpOnActivation() async {
        _ = await watched(refusing: [.mouse]) { service, monitor, installer, triggers in
            #expect(!service.start())
            monitor.start()

            installer.refuse([])
            triggers.send(.applicationActivated)
            #expect(monitor.checks.last?.mouse == .rebuilt)
            #expect(service.status.mouseTapInstalled)
        }
    }

    @Test func aWithdrawnGrantShowsAsRefusedRatherThanHealthy() async throws {
        _ = try await watched { service, monitor, installer, triggers in
            service.start()
            monitor.start()
            try #require(installer.tap(.mouse)).losePort()
            installer.refuse([.mouse, .keyDown])

            triggers.send(.sessionBecameActive)
            #expect(monitor.checks.last?.mouse == .refused)
        }
    }

    @Test func startingTwiceSubscribesOnce() async {
        _ = await watched { service, monitor, _, triggers in
            service.start()
            monitor.start()
            monitor.start()
            triggers.send(.wake)
            #expect(monitor.checks.counts[.wake] == 1)
        }
    }

    @Test func aStoppedMonitorChecksNothing() async {
        _ = await watched { service, monitor, _, triggers in
            service.start()
            monitor.start()
            monitor.stop()
            #expect(!triggers.send(.wake))
            #expect(monitor.checks.total == 0)
        }
    }

    @Test func theSubscriptionGoesWithTheMonitor() {
        let installer = FakeTapInstaller()
        let triggers = FakeHealthTriggers()
        let service = EventTapService(installer: installer)
        do {
            let monitor = TapHealthMonitor(service: service, triggers: triggers)
            monitor.start()
            #expect(triggers.isObserving)
        }
        #expect(!triggers.isObserving)
    }
}
