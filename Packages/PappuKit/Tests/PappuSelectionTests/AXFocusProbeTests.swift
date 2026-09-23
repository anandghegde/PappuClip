import CoreGraphics
import PappuAX
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.apple.Safari")
private let elsewhere = TargetApp(pid: 909, bundleID: "com.apple.Terminal")
private let mouseDown = CGPoint(x: 400, y: 260)

/// The read stage's budget on the Accessibility path (PRD §11.1), in seconds, as AX takes it.
private let readTimeout = Float(0.070)

/// A permit for `target`, minted by the gate the way the coordinator will at mouse-down. `#require`
/// cannot hold a `~Copyable` value, so this throws instead.
private struct TheGateRefused: Error {}

private func permit(for app: TargetApp = target) throws -> ReadPermit {
    let decision = PrivacyGate(PrivacyRules()).evaluate(route: .automatic, target: app, secureInput: .clear)
    guard let permit = decision.permit() else { throw TheGateRefused() }
    return permit
}

private func probe(_ world: FakeAXWorld) async -> AXFocusProbe {
    await AXFocusProbe(world: world)
}

/// ACT-12's Accessibility half and ACT-14's structural signals: what the mouse-down pre-work of
/// architecture §4.3 may look at, and what it may not.
@Suite struct AXFocusProbeTests {

    // MARK: Secure fields (ACT-12)

    @Test func aSecureFieldIsRecognisedByRoleOrBySubrole() async {
        for node in [
            FakeAXWorld.Node(role: "AXTextField", subrole: AXRole.secureTextField),
            FakeAXWorld.Node(role: AXRole.secureTextField),
        ] {
            let world = FakeAXWorld()
            world.setFocused(node, in: target.pid)
            let focus = await probe(world).focus(in: target)

            #expect(focus.isFocusedFieldSecure)
            #expect(focus.hasFocusedElement)
        }
    }

    @Test func anOrdinaryTextFieldIsNotSecure() async {
        let world = FakeAXWorld()
        world.setFocused(FakeAXWorld.Node(role: "AXTextArea"), in: target.pid)
        let focus = await probe(world).focus(in: target)

        #expect(!focus.isFocusedFieldSecure)
        #expect(focus.focused?.isTextual == true)
    }

    /// The choice written down in `AXFocus.isFocusedFieldSecure`: an app with no Accessibility tree is
    /// most of the Mac, and refusing all of it would buy nothing the system-wide flag does not cover.
    @Test func anAppThatWillNotSayIsNotTakenForSecure() async {
        let world = FakeAXWorld()
        world.failApplication(target.pid, with: .unsupported)
        let focus = await probe(world).focus(in: target)

        #expect(!focus.isFocusedFieldSecure)
        #expect(!focus.hasFocusedElement)
        #expect(focus.fault == .unsupported)
    }

    @Test func aSecureFieldRefusesTheReadThroughTheGate() async {
        let world = FakeAXWorld()
        world.setFocused(FakeAXWorld.Node(role: "AXTextField", subrole: AXRole.secureTextField), in: target.pid)
        let focus = await probe(world).focus(in: target)

        let decision = PrivacyGate(PrivacyRules()).evaluate(
            route: .automatic,
            target: target,
            secureInput: focus.secureInputState(systemWide: false)
        )
        #expect(decision.denial?.reason == .secureTextField)
    }

    // MARK: Structure, never content (architecture §4.2, §4.3)

    @Test func theMouseDownProbeReadsNoAttributeThatCanHoldText() async {
        let world = FakeAXWorld()
        world.setFocused(
            FakeAXWorld.Node(role: "AXTextArea", selectedRange: AXTextRange(location: 4, length: 9), selectedText: "selected!"),
            in: target.pid
        )
        world.setUnderPointer(FakeAXWorld.Node(role: "AXStaticText", selectedText: "under the pointer"), at: mouseDown)

        _ = await probe(world).focus(in: target, at: mouseDown)

        #expect(!world.asked.isEmpty)
        #expect(world.asked.allSatisfy { !$0.carriesText })
    }

    @Test func theBaselineIsARangeAndNeverTheText() async throws {
        let world = FakeAXWorld()
        world.setFocused(
            FakeAXWorld.Node(role: "AXTextArea", selectedRange: AXTextRange(location: 4, length: 9), selectedText: "selected!"),
            in: target.pid
        )
        let probe = await probe(world)
        _ = await probe.focus(in: target)
        let range = try await probe.baselineRange(permit())

        #expect(try range.get() == AXTextRange(location: 4, length: 9))
        #expect(world.asked.filter { $0 == .selectedTextRange }.count == 1)
        #expect(world.asked.allSatisfy { !$0.carriesText })
    }

    @Test func aCaretIsAnAnswerAndNotAFailure() async throws {
        let world = FakeAXWorld()
        world.setFocused(
            FakeAXWorld.Node(role: "AXTextField", selectedRange: AXTextRange(location: 12, length: 0)),
            in: target.pid
        )
        let probe = await probe(world)
        _ = await probe.focus(in: target)

        let range = try await probe.baselineRange(permit()).get()
        #expect(range.isEmpty)
        #expect(range.location == 12)
    }

    @Test func theRoleUnderThePointerIsReadOnlyWhenThereIsAPointer() async {
        let world = FakeAXWorld()
        world.setFocused(FakeAXWorld.Node(role: "AXWebArea"), in: target.pid)
        world.setUnderPointer(FakeAXWorld.Node(role: "AXStaticText"), at: mouseDown)
        let probe = await probe(world)

        let withPointer = await probe.focus(in: target, at: mouseDown)
        #expect(withPointer.underPointer?.role == "AXStaticText")
        #expect(withPointer.underPointer?.isTextual == true)

        // The shortcut and the scripting routes have no pointer to ask about (ACT-5, SCR-1, SCR-2).
        let withoutPointer = await probe.focus(in: target)
        #expect(withoutPointer.underPointer == nil)
        #expect(withoutPointer.fault == nil)
    }

    @Test func aRoleTheAppWillNotGiveIsNothingToGoOnRatherThanAnEmptyRole() async {
        let world = FakeAXWorld()
        let node = FakeAXWorld.Node(role: "AXTextArea")
        node.fail(.role, with: .timedOut)
        world.setFocused(node, in: target.pid)
        let focus = await probe(world).focus(in: target)

        #expect(focus.hasFocusedElement)
        #expect(focus.focused == nil)
        #expect(focus.fault == .timedOut)
    }

    // MARK: The permit decides which element (architecture §3.1)

    @Test func aBaselineIsOnlyReadForTheProcessTheGateJudged() async throws {
        let world = FakeAXWorld()
        world.setFocused(
            FakeAXWorld.Node(role: "AXTextArea", selectedRange: AXTextRange(location: 0, length: 3)),
            in: target.pid
        )
        let probe = await probe(world)
        _ = await probe.focus(in: target)

        #expect(try await probe.baselineRange(permit(for: elsewhere)) == .failure(.unsupported))
    }

    @Test func nothingIsReadBeforeAProbeHasFoundSomethingToReadFrom() async throws {
        let world = FakeAXWorld()
        #expect(try await probe(world).baselineRange(permit()) == .failure(.unsupported))
        #expect(world.asked.isEmpty)
    }

    @Test func aFocusThatWentAwayIsForgottenRatherThanReadAgain() async throws {
        let world = FakeAXWorld()
        world.setFocused(
            FakeAXWorld.Node(role: "AXTextArea", selectedRange: AXTextRange(location: 0, length: 3)),
            in: target.pid
        )
        let probe = await probe(world)
        _ = await probe.focus(in: target)

        // The app switched to a window with no focused element between mouse-down and the gate.
        world.setFocused(nil, in: target.pid)
        _ = await probe.focus(in: target)

        #expect(try await probe.baselineRange(permit()) == .failure(.unsupported))
    }

    // MARK: Timeouts (PRD §11.1)

    @Test func everyElementIsGivenTheReadStagesTimeout() async {
        let world = FakeAXWorld()
        world.setFocused(FakeAXWorld.Node(role: "AXTextArea"), in: target.pid)
        world.setUnderPointer(FakeAXWorld.Node(role: "AXStaticText"), at: mouseDown)

        _ = await probe(world).focus(in: target, at: mouseDown)

        // The application, the focused element and the element under the pointer: a timeout is per element.
        #expect(world.timeouts == [readTimeout, readTimeout, readTimeout])
    }

    /// Zero means "use the global default" to AX, which is long enough to hand a wedged app this
    /// actor's queue; past the hard cutoff there would be no bar to show for the answer anyway.
    @Test func aTimeoutIsNeverZeroAndNeverPastTheHardCutoff() async {
        func timeouts(_ asked: Duration) async -> [Float] {
            let world = FakeAXWorld()
            world.setFocused(FakeAXWorld.Node(role: "AXTextArea"), in: target.pid)
            _ = await probe(world).focus(in: target, timeout: asked)
            return world.timeouts
        }

        #expect(await timeouts(.zero).allSatisfy { $0 == 0.001 })
        #expect(await timeouts(.seconds(10)).allSatisfy { $0 == Float(BudgetTable.initial.hardCutoffMs) / 1_000 })
    }

    // MARK: Faults (DIA-2)

    @Test func aWithdrawnGrantIsReportedAsNotPermitted() async {
        let world = FakeAXWorld()
        world.setFocused(FakeAXWorld.Node(role: "AXTextArea"), in: target.pid)
        world.failApplication(target.pid, with: .notPermitted)

        let focus = await probe(world).focus(in: target, at: mouseDown)
        #expect(focus.fault == .notPermitted)
        #expect(!focus.hasFocusedElement)
    }

    @Test func anAppThatDoesNotAnswerInTimeIsATimeoutAndNotAFailure() async {
        let world = FakeAXWorld()
        world.failApplication(target.pid, with: .timedOut)

        let focus = await probe(world).focus(in: target)
        #expect(focus.fault == .timedOut)
    }
}
