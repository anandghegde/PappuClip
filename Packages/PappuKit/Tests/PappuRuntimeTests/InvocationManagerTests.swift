import Foundation
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Testing

private let selectedRange = AXTextRange(location: 10, length: 5)
private let selection = "the selected words"

/// The world as it is when nothing has moved: the same range, the same words as the request.
private let matching = settled(range: selectedRange, text: selection)

private struct Verified {
    var tier: DestinationTier
    var primary: DestinationFailure?
}

private func result(_ verification: consuming DestinationVerification) -> Verified {
    Verified(tier: verification.tier, primary: verification.block?.primary)
}

private func manager(
    _ probe: FakeDestinationProbe,
    input: FakeInput = FakeInput(),
    rules: PrivacyRules = PrivacyRules(),
    frontmost: TargetApp? = editor,
    clock: ManualTimeSource = ManualTimeSource(),
    sleep: FakeSleep = FakeSleep()
) -> InvocationManager {
    InvocationManager(
        verifier: DestinationVerifier(
            gate: PrivacyGate(rules),
            probe: probe,
            policies: policies(),
            epochs: input,
            frontmost: { frontmost },
            secureInputIsActive: { false },
            timing: .initial,
            now: clock.reader
        ),
        probe: probe,
        epochs: input,
        timing: .initial,
        sleeper: sleep,
        now: clock.reader
    )
}

private func request(
    action: String = "com.pappuclip.builtin.uppercase",
    mayMutate: Bool = true,
    target: TargetApp = editor,
    strategy: SelectionStrategyKind? = .ax
) -> InvocationRequest {
    InvocationRequest(
        attempt: AttemptID(rawValue: 3),
        route: .automatic,
        target: target,
        action: action,
        mayMutate: mayMutate,
        text: selection,
        range: selectedRange,
        strategy: strategy
    )
}

/// RUN-1 and RUN-3: what an action run holds while it is live, and what it lets go of when it stops
/// being live — whichever of the two ways it stops.
@Suite struct InvocationManagerTests {
    // MARK: The snapshot (RUN-1a)

    @Test func theSnapshotHasEverythingTheVerifierWillLaterAskFor() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe, clock: clock)

        let invocation = await runtime.begin(request())
        clock.advance(by: .seconds(5))
        let taken = await runtime.snapshot(of: invocation)

        #expect(taken?.attempt == AttemptID(rawValue: 3))
        #expect(taken?.route == .automatic)
        #expect(taken?.target == editor)
        #expect(taken?.range == selectedRange)
        #expect(taken?.text == TextDigest(selection))
        #expect(taken?.strategy == .ax)
        #expect(taken?.epoch == .start)
        #expect(taken?.handle != nil)
        #expect(taken?.wasReadThroughAccessibility == true)
    }

    /// The digest answers one question — "is it still the same text" — and cannot answer any other.
    @Test func theSelectionIsKeptAsADigestAndALength() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        let record = await runtime.record(of: invocation)

        #expect(record?.characters == selection.count)
        #expect(await runtime.snapshot(of: invocation)?.text == TextDigest(selection))
        #expect(TextDigest(selection) != TextDigest(selection + "."))
    }

    /// The same walk `PrivacyDenial` and `AttemptRecord` get: nothing in a record a diagnostics file
    /// could carry the user's words out in.
    @Test func noFieldOfTheRecordCanHoldTheSelection() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        _ = await runtime.verifyDestination(of: invocation)
        await runtime.finish(invocation, outcome: .completed)

        let record = try! #require(await runtime.record(of: invocation))
        for child in Mirror(reflecting: record).children {
            if let text = child.value as? String {
                #expect(!text.contains(selection))
                #expect(!selection.contains(text))
            }
            #expect(!(child.value is TextDigest))
        }
    }

    // MARK: What changed since (RUN-1b)

    @Test func theWorldMovingOnDoesNotRetargetTheRun() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(matching)
        // The user switched to Terminal while the action was running.
        let runtime = manager(probe, frontmost: terminal, clock: clock)

        let invocation = await runtime.begin(request())
        probe.evidence = DestinationEvidence(isFrontmost: false)
        await runtime.noticed(.applicationActivated, for: invocation)
        let verification = result(await runtime.verifyDestination(of: invocation))

        #expect(await runtime.snapshot(of: invocation)?.target == editor)
        #expect(verification.tier == .unverifiable)
        #expect(verification.primary == .notFrontmost)
        #expect(await runtime.changes(for: invocation) == [.applicationActivated])
    }

    @Test func changesAreKeptInTheOrderTheyHappened() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        await runtime.noticed(.selectionChanged)
        await runtime.noticed(.windowChanged)
        await runtime.noticed(.secureInputBegan, for: invocation)

        #expect(await runtime.changes(for: invocation) == [.selectionChanged, .windowChanged, .secureInputBegan])
    }

    // MARK: Our own surfaces (RUN-1c)

    @Test func focusMovingIntoOurOwnSurfaceIsNotANewDestination() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        await runtime.focusEnteredOwnSurface()
        // A watcher that only knows "focus moved" reports one. It is still our own surface.
        await runtime.noticed(.focusChanged)
        let verification = result(await runtime.verifyDestination(of: invocation))
        await runtime.focusLeftOwnSurface()

        #expect(await runtime.changes(for: invocation) == [
            .focusEnteredOwnSurface, .focusEnteredOwnSurface, .focusLeftOwnSurface,
        ])
        #expect(verification.tier == .accessibility)
    }

    // MARK: The key tap (RUN-2g, ACT-19)

    @Test func aRunThatMayMutateHoldsTheKeyTapForItsWholeLife() async {
        let probe = FakeDestinationProbe(matching)
        let input = FakeInput()
        let runtime = manager(probe, input: input)

        let invocation = await runtime.begin(request(mayMutate: true))
        let whileRunning = input.openLeases
        await runtime.finish(invocation, outcome: .completed)

        #expect(whileRunning == 1)
        #expect(input.openLeases == 0)
        #expect(input.leasesStopped == 1)
    }

    @Test func cancellingGivesTheKeyTapBackToo() async {
        let probe = FakeDestinationProbe(matching)
        let input = FakeInput()
        let runtime = manager(probe, input: input)

        let invocation = await runtime.begin(request(mayMutate: true))
        _ = await runtime.cancel(invocation)

        #expect(input.openLeases == 0)
    }

    @Test func aRunThatCannotMutateTakesNoLeaseAndCarriesNoEpoch() async {
        let probe = FakeDestinationProbe(matching)
        let input = FakeInput()
        let runtime = manager(probe, input: input)

        let invocation = await runtime.begin(request(action: "com.pappuclip.builtin.search", mayMutate: false))

        #expect(input.leasesTaken == 0)
        #expect(await runtime.snapshot(of: invocation)?.epoch == nil)
    }

    /// Without the grant there is no key tap, and a run that cannot see keystrokes says so in the one
    /// place it matters: the snapshot carries no epoch, so the quiescence tier is out of reach.
    @Test func noGrantMeansNoEpochAndTheRecordSaysSo() async {
        let probe = FakeDestinationProbe(matching)
        let input = FakeInput(keyTapAvailable: false)
        let runtime = manager(probe, input: input)

        let invocation = await runtime.begin(request(mayMutate: true))

        #expect(await runtime.snapshot(of: invocation)?.epoch == nil)
        #expect(await runtime.record(of: invocation)?.watchedInput == false)
    }

    // MARK: Handles

    @Test func theDestinationElementIsGivenBackHoweverTheRunEnds() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let finished = await runtime.begin(request())
        let cancelled = await runtime.begin(request())
        let held = probe.heldCount
        await runtime.finish(finished, outcome: .completed)
        _ = await runtime.cancel(cancelled)

        #expect(held == 2)
        #expect(probe.heldCount == 0)
        #expect(probe.released.count == 2)
    }

    @Test func anAppWithNothingToTakeHoldOfStillRuns() async {
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true))
        probe.capturesNothing()
        let runtime = manager(probe)

        let invocation = await runtime.begin(request(strategy: .syntheticCopy))
        let verification = result(await runtime.verifyDestination(of: invocation))

        #expect(await runtime.snapshot(of: invocation)?.handle == nil)
        #expect(verification.tier == .quiescence)
    }

    // MARK: Cancellation (RUN-3a–3c)

    @Test func cancellingEndsEverythingTheRunCouldStillAskFor() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        let report = await runtime.cancel(invocation)
        let verification = result(await runtime.verifyDestination(of: invocation))

        #expect(report.alreadyEnded == false)
        #expect(await runtime.state(of: invocation) == .invalidated(.cancelled))
        #expect(await runtime.accepts(invocation) == false)
        #expect(verification.tier == .unverifiable)
        #expect(verification.primary == .invocationNotRunning)
        // Nothing even looked: a cancelled invocation does not read the user's text (RUN-3b).
        #expect(probe.looks.isEmpty)
        #expect(await runtime.finish(invocation, outcome: .completed) == false)
        #expect(await runtime.attach(FakeWork(.owned), to: invocation) == false)
    }

    /// The race the whole design is for: Escape pressed while the verification is out at the
    /// Accessibility API. The permit must not outlive the invocation by one round trip.
    @Test func aVerificationInFlightWhenTheUserCancelsYieldsNoPermit() async {
        let probe = FakeDestinationProbe(matching)
        let gate = Gate()
        let runtime = manager(probe)
        let invocation = await runtime.begin(request())

        probe.holdLooks(until: gate)
        let pending = Task { result(await runtime.verifyDestination(of: invocation)) }
        #expect(await eventually { probe.looks.count == 1 })

        _ = await runtime.cancel(invocation)
        await gate.open()
        let verification = await pending.value

        #expect(verification.tier == .unverifiable)
        #expect(verification.primary == .invocationNotRunning)
        #expect(await runtime.record(of: invocation)?.failure == .invocationNotRunning)
    }

    @Test func cancellingATwiceEndedRunSaysItWasAlreadyOver() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        _ = await runtime.cancel(invocation)
        let again = await runtime.cancel(invocation)

        #expect(again.alreadyEnded)
        #expect(probe.released.count == 1)
    }

    // MARK: Stopping the work (RUN-3d, RUN-3e)

    @Test func ownedWorkIsStoppedAndSaidToBeStopped() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)
        let script = FakeWork(.owned, answers: .stopped)

        let invocation = await runtime.begin(request())
        await runtime.attach(script, to: invocation)
        let report = await runtime.cancel(invocation)

        #expect(script.timesAsked == 1)
        #expect(report.stopped == 1)
        #expect(report.mayHaveCompleted == false)
        #expect(report.graceExpired == false)
    }

    /// RUN-3e. A Shortcut or an AppleScript send is asked and nothing more, and the report says the
    /// thing the UI has to say: it may already have happened.
    @Test func delegatedWorkIsOnlyAskedAndIsNeverCalledStopped() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)
        let shortcut = FakeWork(.delegated, answers: .askedToStop)

        let invocation = await runtime.begin(request())
        await runtime.attach(shortcut, to: invocation)
        let report = await runtime.cancel(invocation)

        #expect(report.stopped == 0)
        #expect(report.asked == 1)
        #expect(report.mayHaveCompleted)
        #expect(await eventually { shortcut.timesAsked == 1 })
    }

    @Test func workThatWillNotStopEndsTheGraceRatherThanTheWait() async {
        let probe = FakeDestinationProbe(matching)
        let sleep = FakeSleep(.expiresAtOnce)
        let runtime = manager(probe, sleep: sleep)
        let stubborn = FakeWork(.owned, hangs: true)

        let invocation = await runtime.begin(request())
        await runtime.attach(stubborn, to: invocation)
        let report = await runtime.cancel(invocation)

        #expect(report.graceExpired)
        #expect(report.mayHaveCompleted)
        #expect(report.stopped == 0)
        #expect(sleep.durations == [InvocationTiming.initial.cancellationGrace])
        // The invocation is invalid either way: the waiting was never what made it so.
        #expect(await runtime.accepts(invocation) == false)
    }

    @Test func workThatCannotBeStoppedIsReportedAsSuchRatherThanAsStopped() async {
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe)

        let invocation = await runtime.begin(request())
        await runtime.attach(FakeWork(.owned, answers: .cannotStop), to: invocation)
        await runtime.attach(FakeWork(.owned, answers: .mayHaveCompleted), to: invocation)
        let report = await runtime.cancel(invocation)

        #expect(report.stopped == 0)
        #expect(report.unstoppable == 1)
        #expect(report.mayHaveCompleted)
        #expect(await runtime.record(of: invocation)?.cancellation?.unstoppable == 1)
    }

    // MARK: Pause and revocation (RUN-3f)

    @Test(arguments: [InvocationInvalidation.paused, .revoked, .privacyStateChanged])
    func pauseAndRevocationTakeEverythingInFlightTheSameWay(reason: InvocationInvalidation) async {
        let probe = FakeDestinationProbe(matching)
        let input = FakeInput()
        let runtime = manager(probe, input: input)
        let one = await runtime.begin(request())
        let two = await runtime.begin(request(action: "com.pappuclip.builtin.paste"))
        await runtime.attach(FakeWork(.owned), to: one)

        let reports = await runtime.invalidateAll(reason)

        #expect(reports.map(\.invocation) == [one, two])
        #expect(reports.allSatisfy { $0.reason == reason })
        #expect(await runtime.state(of: one) == .invalidated(reason))
        #expect(await runtime.state(of: two) == .invalidated(reason))
        #expect(await runtime.runningInvocations.isEmpty)
        #expect(input.openLeases == 0)
        #expect(probe.heldCount == 0)
    }

    // MARK: The record (DIA-2)

    @Test func theRecordSaysWhichTiersItReachedAndHowItEnded() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(matching)
        let runtime = manager(probe, clock: clock)

        let invocation = await runtime.begin(request())
        _ = await runtime.verifyDestination(of: invocation)
        probe.evidence = DestinationEvidence(isFrontmost: false)
        _ = await runtime.verifyDestination(of: invocation)
        await runtime.noteMutation(of: invocation)
        clock.advance(by: .milliseconds(120))
        await runtime.finish(invocation, outcome: .completed)

        let record = try! #require(await runtime.record(of: invocation))
        #expect(record.verifications == [.accessibility, .unverifiable])
        #expect(record.highestTier == .accessibility)
        #expect(record.failure == .notFrontmost)
        #expect(record.mutated)
        #expect(record.outcome == .completed)
        #expect(record.elapsed == .milliseconds(120))
        #expect(await runtime.records.count == 1)
    }
}
