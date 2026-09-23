import Foundation
import PappuSelection
import PappuTestSupport
import Testing

/// Virtual key codes, as `HotkeyShortcut` takes them.
private enum Key {
    static let a: UInt16 = 0
    static let v: UInt16 = 9
    static let f5: UInt16 = 96
    static let f13: UInt16 = 105
}

/// Runs `body` against a service and returns every press it put on its stream. The stream ends when
/// the service goes, so `body` must not let one escape.
private func presses(
    taken: Set<HotkeyShortcut> = [],
    _ body: (HotkeyService, FakeHotkeyRegistrar) throws -> Void
) async rethrows -> [HotkeyShortcut] {
    let registrar = FakeHotkeyRegistrar(taken: taken)
    let stream: AsyncStream<HotkeyService.Press>
    do {
        let service = HotkeyService(registrar: registrar)
        stream = service.presses
        try body(service, registrar)
    }
    var all: [HotkeyShortcut] = []
    for await press in stream { all.append(press.shortcut) }
    return all
}

@Suite struct HotkeyShortcutTests {
    // MARK: ACT-5, what may be a shortcut

    @Test(arguments: [
        (HotkeyShortcut(keyCode: Key.v, modifiers: [.command]), true),
        (HotkeyShortcut(keyCode: Key.v, modifiers: [.control]), true),
        (HotkeyShortcut(keyCode: Key.v, modifiers: [.option]), true),
        (HotkeyShortcut(keyCode: Key.v, modifiers: [.shift, .command]), true),
        (HotkeyShortcut(keyCode: Key.f5, modifiers: [.control, .option, .command]), true),
        // A bare function key types nothing, so it needs no modifier.
        (HotkeyShortcut(keyCode: Key.f5), true),
        (HotkeyShortcut(keyCode: Key.f13), true),
        // ⇧ and a letter is typing, and so is a letter on its own.
        (HotkeyShortcut(keyCode: Key.a, modifiers: [.shift]), false),
        (HotkeyShortcut(keyCode: Key.a), false),
        // A function key with ⇧ alone is neither modified nor bare.
        (HotkeyShortcut(keyCode: Key.f5, modifiers: [.shift]), false),
    ])
    func theRuleIsAControlOptionOrCommandOrABareFunctionKey(shortcut: HotkeyShortcut, isUsable: Bool) {
        #expect(shortcut.isUsableAsGlobalShortcut == isUsable)
    }

    @Test func aShortcutSurvivesBeingWrittenOutAndReadBack() throws {
        let shortcut = HotkeyShortcut(keyCode: Key.v, modifiers: [.control, .command])
        let data = try JSONEncoder().encode(shortcut)
        #expect(try JSONDecoder().decode(HotkeyShortcut.self, from: data) == shortcut)
    }
}

@Suite struct HotkeyServiceTests {
    private let controlOptionV = HotkeyShortcut(keyCode: Key.v, modifiers: [.control, .option])
    private let commandF5 = HotkeyShortcut(keyCode: Key.f5, modifiers: [.command])

    @Test func aShortcutIsRegisteredAndItsPressesArriveInOrder() async {
        let seen = await presses { service, registrar in
            #expect(service.use(controlOptionV) == .registered)
            #expect(service.current == controlOptionV)
            #expect(registrar.registered?.shortcut == controlOptionV)
            #expect(registrar.press())
            #expect(registrar.press())
        }
        #expect(seen == [controlOptionV, controlOptionV])
    }

    @Test func nothingIsRegisteredUntilTheUserChoosesOne() async {
        let seen = await presses { service, registrar in
            #expect(service.current == nil)
            #expect(registrar.registered == nil)
            // A press of a combination nobody holds goes to the app in front, not to us.
            #expect(!registrar.press())
        }
        #expect(seen == [])
    }

    @Test func changingTheShortcutTakesTheOldCombinationBack() async throws {
        let seen = await presses { service, registrar in
            service.use(controlOptionV)
            let old = registrar.registered
            #expect(service.use(commandF5) == .registered)
            #expect(old?.isRegistered == false)
            #expect(registrar.registered?.shortcut == commandF5)
            registrar.press()
        }
        #expect(seen == [commandF5])
    }

    @Test func choosingTheSameCombinationAgainRegistersItAfresh() async {
        _ = await presses { service, registrar in
            service.use(controlOptionV)
            #expect(service.use(controlOptionV) == .registered)
            #expect(registrar.registrationCount == 2)
            #expect(registrar.registered?.isRegistered == true)
        }
    }

    @Test func clearingTheShortcutUnregistersItAndTheKeyGoesBackToTheApps() async {
        let seen = await presses { service, registrar in
            service.use(controlOptionV)
            #expect(service.use(nil) == .cleared)
            #expect(service.current == nil)
            #expect(registrar.registered == nil)
            #expect(!registrar.press())
        }
        #expect(seen == [])
    }

    // MARK: ACT-5, what cannot be set

    @Test func aCombinationThatIsNotAShortcutIsRefused() async {
        _ = await presses { service, registrar in
            #expect(service.use(HotkeyShortcut(keyCode: Key.a, modifiers: [.shift])) == .notAShortcut)
            #expect(service.current == nil)
            #expect(registrar.registrationCount == 0)
        }
    }

    @Test func aRefusedChoiceEndsWithNoShortcutRatherThanTheOldOne() async {
        _ = await presses { service, registrar in
            service.use(controlOptionV)
            #expect(service.use(HotkeyShortcut(keyCode: Key.a)) == .notAShortcut)
            #expect(service.current == nil)
            #expect(registrar.registered == nil)
        }
    }

    @Test func aCombinationAnotherAppHoldsIsReportedAsTaken() async {
        let seen = await presses(taken: [commandF5]) { service, registrar in
            service.use(controlOptionV)
            #expect(service.use(commandF5) == .taken)
            #expect(service.current == nil)
            #expect(registrar.registered == nil)
            #expect(!registrar.press())
        }
        #expect(seen == [])
    }

    @Test func aCombinationGivenUpByTheOtherAppCanBeTakenNextTime() async {
        _ = await presses(taken: [commandF5]) { service, registrar in
            #expect(service.use(commandF5) == .taken)
            registrar.markTaken([])
            #expect(service.use(commandF5) == .registered)
            #expect(service.current == commandF5)
        }
    }

    // MARK: ACT-19, the shortcut is not a tap

    @Test func aRegisteredShortcutInstallsNoKeyTap() async {
        let installer = FakeTapInstaller()
        let taps = EventTapService(installer: installer)
        taps.start()
        _ = await presses { hotkeys, registrar in
            hotkeys.use(controlOptionV)
            registrar.press()
            // macOS keeps the combination from every app and hands it straight to the handler, so
            // nothing about the shortcut puts PappuClip in the path of ordinary typing.
            #expect(!taps.status.keyTapInstalled)
            #expect(installer.installCount(.keyDown) == 0)
        }
        taps.stop()
    }

    // MARK: Lifetime

    @Test func theRegistrationGoesWithTheService() {
        let registrar = FakeHotkeyRegistrar()
        do {
            let service = HotkeyService(registrar: registrar)
            service.use(controlOptionV)
            #expect(registrar.registered != nil)
        }
        #expect(registrar.registered == nil)
    }

    @Test func aPressThatArrivesAfterTheServiceHasGoneIsDropped() async {
        let registrar = FakeHotkeyRegistrar()
        let stream: AsyncStream<HotkeyService.Press>
        var held: FakeHotkeyRegistrar.Registration?
        do {
            let service = HotkeyService(registrar: registrar)
            stream = service.presses
            service.use(controlOptionV)
            held = registrar.registered
        }
        #expect(registrar.registered == nil)
        // As if macOS had dispatched a press just as the service went.
        held?.fire()
        var seen: [HotkeyShortcut] = []
        for await press in stream { seen.append(press.shortcut) }
        #expect(seen == [])
    }
}
