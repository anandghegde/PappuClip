import CoreGraphics
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

private typealias Output = EventTapService.Output

private func pointer(_ kind: PointerEvent.Kind, ms: UInt64) -> PointerEvent {
    PointerEvent(kind: kind, location: CGPoint(x: 10, y: 10), timestampNs: ms * 1_000_000, windowNumber: 7)
}

private func key(_ keyCode: UInt16) -> TapInput {
    .keyDown(KeyPress(keyCode: keyCode, timestampNs: 0))
}

/// Runs `body` against a service and returns everything the service put on its stream. The stream ends
/// when the service goes, so `body` must not let a lease escape.
private func outputs(
    refusing refused: Set<TapKind> = [],
    _ body: (EventTapService, FakeTapInstaller) throws -> Void
) async rethrows -> [Output] {
    let installer = FakeTapInstaller(refusing: refused)
    let stream: AsyncStream<Output>
    do {
        let service = EventTapService(installer: installer)
        stream = service.events
        try body(service, installer)
    }
    var all: [Output] = []
    for await output in stream { all.append(output) }
    return all
}

@Suite struct EventTapServiceTests {
    // MARK: The mouse tap

    @Test func pointerEventsArriveInOrderAndAreNeverConsumed() async {
        let events = [pointer(.down, ms: 0), pointer(.dragged, ms: 40), pointer(.up, ms: 90), pointer(.scroll, ms: 200)]
        let seen = await outputs { service, installer in
            #expect(service.start())
            for event in events { #expect(installer.send(.pointer(event), to: .mouse) == .pass) }
        }
        #expect(seen == events.map(Output.pointer))
    }

    @Test func stoppingTakesTheMouseTapAwayAndStartingBringsItBack() async {
        _ = await outputs { service, installer in
            service.start()
            service.start()
            #expect(installer.installCount(.mouse) == 1)

            service.stop()
            #expect(installer.tap(.mouse) == nil)
            #expect(service.checkHealth().mouse == .notWanted)
            #expect(installer.installCount(.mouse) == 1)

            #expect(service.start())
            #expect(installer.installCount(.mouse) == 2)
        }
    }

    @Test func theTapsGoWithTheService() async {
        let installer = FakeTapInstaller()
        var lease: KeyTapLease?
        do {
            let service = EventTapService(installer: installer)
            service.start()
            lease = service.leaseKeyTap { _ in .pass }
            #expect(installer.tap(.mouse) != nil)
            // The lease keeps the service, and so both taps, alive.
        }
        #expect(installer.tap(.keyDown) != nil)
        lease = nil
        _ = lease
        #expect(installer.tap(.mouse) == nil)
        #expect(installer.tap(.keyDown) == nil)
    }

    // MARK: ACT-19, the key tap exists only while it is needed

    @Test func noKeyTapExistsUntilSomeoneLeasesIt() async {
        _ = await outputs { service, installer in
            service.start()
            service.checkHealth()
            #expect(installer.installCount(.keyDown) == 0)
            #expect(!service.status.keyTapInstalled)
            #expect(installer.send(key(0), to: .keyDown) == nil)
        }
    }

    @Test func theKeyTapLivesFromTheFirstLeaseToTheLast() async throws {
        _ = try await outputs { service, installer in
            let bar = try #require(service.leaseKeyTap { _ in .pass })
            let invocation = try #require(service.leaseKeyTap { _ in .pass })
            #expect(installer.installCount(.keyDown) == 1)
            #expect(service.status.keyTapLeases == 2)

            bar.release()
            #expect(installer.tap(.keyDown) != nil)
            invocation.release()
            #expect(installer.tap(.keyDown) == nil)
            #expect(!service.status.keyTapInstalled)
            #expect(service.status.keyTapLeases == 0)

            let next = try #require(service.leaseKeyTap { _ in .pass })
            #expect(installer.installCount(.keyDown) == 2)
            next.release()
        }
    }

    @Test func aLeaseThatIsDroppedGivesTheTapUp() async {
        _ = await outputs { service, installer in
            do {
                let lease = service.leaseKeyTap { _ in .pass }
                #expect(lease != nil)
                #expect(installer.tap(.keyDown) != nil)
            }
            #expect(installer.tap(.keyDown) == nil)
        }
    }

    @Test func releasingTwiceDoesNotTakeAnotherHoldersTap() async throws {
        _ = try await outputs { service, installer in
            let first = try #require(service.leaseKeyTap { _ in .pass })
            let second = try #require(service.leaseKeyTap { _ in .pass })
            first.release()
            first.release()
            #expect(installer.tap(.keyDown) != nil)
            #expect(service.status.keyTapLeases == 1)
            second.release()
        }
    }

    @Test func everyHolderSeesAKeyAndAnyOfThemCanConsumeIt() async throws {
        let escape: UInt16 = 53
        let seenByBar = Mutex<[UInt16]>([])
        let seenByInvocation = Mutex<[UInt16]>([])
        _ = try await outputs { service, installer in
            let bar = try #require(service.leaseKeyTap { press in
                seenByBar.withLock { $0.append(press.keyCode) }
                return press.keyCode == escape ? .consume : .pass
            })
            let invocation = try #require(service.leaseKeyTap { press in
                seenByInvocation.withLock { $0.append(press.keyCode) }
                return .pass
            })
            #expect(installer.send(key(escape), to: .keyDown) == .consume)
            #expect(installer.send(key(0), to: .keyDown) == .pass)

            bar.release()
            #expect(installer.send(key(escape), to: .keyDown) == .pass)
            invocation.release()
        }
        #expect(seenByBar.withLock { $0 } == [escape, 0])
        #expect(seenByInvocation.withLock { $0 } == [escape, 0, escape])
    }

    @Test func keysNeverReachTheEventStream() async throws {
        let seen = try await outputs { service, installer in
            service.start()
            let lease = try #require(service.leaseKeyTap { _ in .pass })
            installer.send(key(0), to: .keyDown)
            lease.release()
        }
        #expect(seen == [])
    }

    @Test func aRefusedKeyTapGivesNoLease() async {
        _ = await outputs(refusing: [.keyDown]) { service, _ in
            #expect(service.leaseKeyTap { _ in .pass } == nil)
            #expect(service.status.keyTapLeases == 0)
        }
    }

    // MARK: ACT-15, health

    @Test func aHealthyServiceReportsNoInterruption() async {
        let seen = await outputs { service, _ in
            service.start()
            let report = service.checkHealth()
            #expect(report.mouse == .healthy)
            #expect(report.key == .notWanted)
        }
        #expect(seen == [])
    }

    @Test func aTapSwitchedOffWhileInUseIsSwitchedBackOnAtOnce() async throws {
        let seen = try await outputs { service, installer in
            service.start()
            let tap = try #require(installer.tap(.mouse))
            installer.send(.pointer(pointer(.down, ms: 0)), to: .mouse)

            tap.switchOff(notifying: .timeout)
            #expect(tap.isEnabled)
            #expect(service.status.reenables == 1)
            #expect(installer.installCount(.mouse) == 1)

            installer.send(.pointer(pointer(.down, ms: 900)), to: .mouse)
        }
        // The mouse-up of the first press may have gone by while the tap was off.
        #expect(seen == [.pointer(pointer(.down, ms: 0)), .interrupted, .pointer(pointer(.down, ms: 900))])
    }

    @Test func aKeyTapSwitchedOffWhileInUseIsSwitchedBackOnAtOnce() async throws {
        let seen = try await outputs { service, installer in
            let lease = try #require(service.leaseKeyTap { _ in .consume })
            let tap = try #require(installer.tap(.keyDown))
            tap.switchOff(notifying: .userInput)
            #expect(tap.isEnabled)
            #expect(installer.send(key(0), to: .keyDown) == .consume)
            lease.release()
        }
        #expect(seen == [.interrupted])
    }

    @Test func aTapFoundOffIsSwitchedBackOn() async throws {
        let seen = try await outputs { service, installer in
            service.start()
            let tap = try #require(installer.tap(.mouse))
            tap.switchOff()
            #expect(service.checkHealth().mouse == .reenabled)
            #expect(tap.isEnabled)
            #expect(service.status.reenables == 1)
            #expect(service.checkHealth().mouse == .healthy)
        }
        #expect(seen == [.interrupted])
    }

    @Test func aTapWhosePortIsGoneIsRebuilt() async throws {
        let seen = try await outputs { service, installer in
            service.start()
            let old = try #require(installer.tap(.mouse))
            old.switchOff()
            old.losePort()

            #expect(service.checkHealth().mouse == .rebuilt)
            #expect(old.wasRemoved)
            #expect(installer.installCount(.mouse) == 2)
            #expect(service.status.rebuilds == 1)
            installer.send(.pointer(pointer(.down, ms: 5)), to: .mouse)
        }
        #expect(seen == [.interrupted, .pointer(pointer(.down, ms: 5))])
    }

    @Test func theKeyTapIsLookedAfterOnlyWhileItIsLeased() async throws {
        _ = try await outputs { service, installer in
            service.start()
            let lease = try #require(service.leaseKeyTap { _ in .pass })
            try #require(installer.tap(.keyDown)).losePort()
            let report = service.checkHealth()
            #expect(report.mouse == .healthy)
            #expect(report.key == .rebuilt)
            #expect(installer.installCount(.keyDown) == 2)

            lease.release()
            #expect(service.checkHealth().key == .notWanted)
            #expect(installer.installCount(.keyDown) == 2)
        }
    }

    @Test func aGrantGivenLaterIsPickedUpByTheNextHealthCheck() async {
        let seen = await outputs(refusing: [.mouse]) { service, installer in
            #expect(!service.start())
            #expect(service.checkHealth().mouse == .refused)

            installer.refuse([])
            #expect(service.checkHealth().mouse == .rebuilt)
            #expect(service.status.mouseTapInstalled)
            installer.send(.pointer(pointer(.down, ms: 1)), to: .mouse)
        }
        #expect(seen == [.interrupted, .interrupted, .pointer(pointer(.down, ms: 1))])
    }

    @Test func aWithdrawnGrantIsReportedAsRefused() async throws {
        _ = try await outputs { service, installer in
            service.start()
            try #require(installer.tap(.mouse)).losePort()
            installer.refuse([.mouse, .keyDown])

            #expect(service.checkHealth().mouse == .refused)
            #expect(!service.status.mouseTapInstalled)
            #expect(service.status.rebuilds == 0)
        }
    }
}
