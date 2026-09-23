import Foundation
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Testing

private let sourceRange = AXTextRange(location: 10, length: 18)
private let sourceText = "the selected words"

/// How an action run ended, from the point of view of the user watching it.
private enum Ending: Equatable {
    /// Text went into the destination, at this tier.
    case mutated(DestinationTier)
    /// The result was shown with a Copy button and nothing was written anywhere (RUN-2c, RUN-2d).
    case offeredForCopy(DestinationFailure?)
    /// The result arrived after the run stopped being live and was thrown away: no paste, no copy, no
    /// tick (RUN-3c).
    case discarded
}

/// One whole run, as the app will do it: start, work, verify, and then either the effect or the
/// refusal. The scenarios below differ only in what the world does while `work` is running.
private func run(
    _ request: InvocationRequest,
    in runtime: InvocationManager,
    work: () async -> Void = {}
) async -> Ending {
    let invocation = await runtime.begin(request)
    await work()

    guard await runtime.accepts(invocation) else { return .discarded }

    let verification = await runtime.verifyDestination(of: invocation)
    let tier = verification.tier
    let failure = verification.block?.primary

    guard let permit = verification.permit() else {
        guard await runtime.finish(invocation, outcome: .blocked) else { return .discarded }
        return .offeredForCopy(failure)
    }

    // Where `TextMutator` will spend the permit. What matters here is that there is one, and that
    // nothing below this line can be reached without it.
    #expect(permit.tier.permitsMutation)
    await runtime.noteMutation(of: invocation)
    guard await runtime.finish(invocation, outcome: .completed) else { return .discarded }
    return .mutated(tier)
}

private func request(
    target: TargetApp = editor,
    action: String = "com.example.translate",
    strategy: SelectionStrategyKind? = .ax,
    text: String = sourceText,
    range: AXTextRange? = sourceRange
) -> InvocationRequest {
    InvocationRequest(
        attempt: AttemptID(rawValue: 1),
        route: .automatic,
        target: target,
        action: action,
        mayMutate: true,
        text: text,
        range: range,
        strategy: strategy
    )
}

/// The Mac, for the length of one scenario: an app to act on, taps that count what the user does, a
/// clock the test moves, and the runtime under all of it. A class because a `Mutex` cannot be copied.
private final class World: Sendable {
    let probe: FakeDestinationProbe
    let input: FakeInput
    let clock: ManualTimeSource
    let frontmost: Box<TargetApp?>
    let runtime: InvocationManager

    init(
        probe: FakeDestinationProbe,
        input: FakeInput,
        clock: ManualTimeSource,
        frontmost: Box<TargetApp?>,
        runtime: InvocationManager
    ) {
        self.probe = probe
        self.input = input
        self.clock = clock
        self.frontmost = frontmost
        self.runtime = runtime
    }
}

private func world(
    evidence: DestinationEvidence,
    rules: PrivacyRules = PrivacyRules(),
    secureInput: Box<Bool> = Box(false)
) -> World {
    let probe = FakeDestinationProbe(evidence)
    let input = FakeInput()
    let clock = ManualTimeSource()
    let frontmost = Box<TargetApp?>(editor)
    let runtime = InvocationManager(
        verifier: DestinationVerifier(
            gate: PrivacyGate(rules),
            probe: probe,
            policies: policies(),
            epochs: input,
            frontmost: { frontmost.current },
            secureInputIsActive: { secureInput.current },
            timing: .initial,
            now: clock.reader
        ),
        probe: probe,
        epochs: input,
        timing: .initial,
        now: clock.reader
    )
    return World(probe: probe, input: input, clock: clock, frontmost: frontmost, runtime: runtime)
}

/// The evidence an app gives when the selection is exactly where the action left it.
private let unmoved = DestinationEvidence(
    isFrontmost: true,
    sameWindow: true,
    sameElement: true,
    isEditable: true,
    range: sourceRange,
    text: TextDigest(sourceText)
)

/// RUN-5. The scenarios the safety spec names, each one written as the story it is.
///
/// Three things are asserted every time, and they are the three the spec asks for: no text goes to a
/// destination that is not the one it came from, nothing succeeds after it was cancelled, and nothing
/// is left holding the key tap or an element of a window that may have closed — the runtime's half of
/// "no stale bar".
@Suite struct LifecycleScenarioTests {
    private func assertNothingIsLeftOver(_ world: World) async {
        #expect(await world.runtime.runningInvocations.isEmpty)
        #expect(world.input.openLeases == 0)
        #expect(world.probe.heldCount == 0)
    }

    /// "Slow translation in Notes followed by switching to Terminal."
    @Test func aSlowActionWhoseUserHasMovedOnWritesNothingAnywhere() async {
        let world = world(evidence: unmoved)

        let ending = await run(request(), in: world.runtime) {
            world.clock.advance(by: .seconds(4))
            world.frontmost.current = terminal
            world.probe.evidence = DestinationEvidence(isFrontmost: false)
            await world.runtime.noticed(.applicationActivated)
        }

        #expect(ending == .offeredForCopy(.notFrontmost))
        await assertNothingIsLeftOver(world)
    }

    /// "Editing the source while a result is pending."
    @Test func editingTheSourceWhileTheResultIsPendingWritesNothing() async {
        let world = world(evidence: unmoved)

        let ending = await run(request(), in: world.runtime) {
            var edited = unmoved
            edited.text = TextDigest(sourceText + " and a few more")
            edited.range = AXTextRange(location: 10, length: 33)
            world.probe.evidence = edited
            world.input.happened()
            await world.runtime.noticed(.selectionChanged)
        }

        #expect(ending == .offeredForCopy(.selectionMoved))
        await assertNothingIsLeftOver(world)
    }

    /// "Changing the selection." The range moved and the text with it; the app is otherwise the same.
    @Test func selectingSomethingElseWritesNothingOverIt() async {
        let world = world(evidence: unmoved)

        let ending = await run(request(), in: world.runtime) {
            var elsewhere = unmoved
            elsewhere.range = AXTextRange(location: 200, length: 4)
            elsewhere.text = TextDigest("else")
            world.probe.evidence = elsewhere
            world.input.happened()
        }

        #expect(ending == .offeredForCopy(.selectionMoved))
        await assertNothingIsLeftOver(world)
    }

    /// "Closing the source window."
    @Test func closingTheSourceWindowWritesNothingIntoWhateverIsBehindIt() async {
        let world = world(evidence: unmoved)

        let ending = await run(request(), in: world.runtime) {
            world.probe.evidence = DestinationEvidence(
                isFrontmost: true,
                sameWindow: false,
                sameElement: false,
                fault: .staleElement
            )
            await world.runtime.noticed(.windowChanged)
        }

        #expect(ending == .offeredForCopy(.windowChanged))
        await assertNothingIsLeftOver(world)
    }

    /// "Entering secure input." The gate refuses before anything looks at the destination, so this one
    /// is not even a verification failure — it is step 1 of §S1, rechecked (RUN-2f).
    @Test func secureInputStartingUnderARunningActionStopsIt() async {
        let secureInput = Box(false)
        let world = world(evidence: unmoved, secureInput: secureInput)

        let ending = await run(request(), in: world.runtime) {
            secureInput.current = true
            await world.runtime.noticed(.secureInputBegan)
        }

        #expect(ending == .offeredForCopy(.privacyRefused))
        #expect(world.probe.looks.isEmpty)
        await assertNothingIsLeftOver(world)
    }

    /// "Cancellation immediately before completion." The user's Escape lands while the verification is
    /// out at the Accessibility API — the narrowest window there is.
    @Test func cancellingJustBeforeTheEndIsNeverALateSuccess() async {
        let world = world(evidence: unmoved)
        let gate = Gate()
        let invocation = await world.runtime.begin(request())

        world.probe.holdLooks(until: gate)
        let pending = Task { () -> Ending in
            let verification = await world.runtime.verifyDestination(of: invocation)
            guard let permit = verification.permit() else {
                guard await world.runtime.finish(invocation, outcome: .blocked) else { return .discarded }
                return .offeredForCopy(nil)
            }
            return .mutated(permit.tier)
        }
        #expect(await eventually { world.probe.looks.count == 1 })

        let report = await world.runtime.cancel(invocation)
        await gate.open()
        let ending = await pending.value

        #expect(ending == .discarded)
        #expect(report.alreadyEnded == false)
        #expect(await world.runtime.record(of: invocation)?.mutated == false)
        #expect(await world.runtime.record(of: invocation)?.outcome == nil)
        await assertNothingIsLeftOver(world)
    }

    /// "A new selection racing an older detection." Both runs are live at once; only the one whose
    /// snapshot matches the world may write.
    @Test func anOlderRunCannotWriteOverWhatANewerSelectionPutThere() async {
        let world = world(evidence: unmoved)
        let newRange = AXTextRange(location: 90, length: 7)
        let newText = "another"

        let older = await world.runtime.begin(request())
        world.probe.evidence = DestinationEvidence(
            isFrontmost: true,
            sameWindow: true,
            sameElement: true,
            isEditable: true,
            range: newRange,
            text: TextDigest(newText)
        )
        world.input.happened()
        let newer = await world.runtime.begin(request(text: newText, range: newRange))

        let oldVerification = await world.runtime.verifyDestination(of: older)
        let newVerification = await world.runtime.verifyDestination(of: newer)
        let oldFailure = oldVerification.block?.primary
        let newTier = newVerification.tier
        await world.runtime.finish(older, outcome: .blocked)
        await world.runtime.finish(newer, outcome: .completed)

        #expect(oldFailure == .selectionMoved)
        #expect(newTier == .accessibility)
        await assertNothingIsLeftOver(world)
    }

    /// "A quiescence-verified paste with and without an intervening input event." One story, told
    /// twice, because the difference between the two tellings is the whole tier.
    @Test(arguments: [false, true])
    func aQuiescenceVerifiedPasteTurnsOnWhetherAnythingWasTyped(typed: Bool) async {
        // A Chromium window: read by synthetic ⌘C, answering nothing through Accessibility.
        let world = world(evidence: DestinationEvidence(isFrontmost: true))

        let ending = await run(request(strategy: .syntheticCopy), in: world.runtime) {
            world.clock.advance(by: .milliseconds(400))
            if typed { world.input.happened() }
        }

        let expected: Ending = typed ? .offeredForCopy(.inputSinceSnapshot) : .mutated(.quiescence)
        #expect(ending == expected)
        await assertNothingIsLeftOver(world)
    }
}
