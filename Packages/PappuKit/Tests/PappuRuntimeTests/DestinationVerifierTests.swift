import Foundation
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Testing

private let selectedRange = AXTextRange(location: 10, length: 5)

private func verifier(
    _ probe: FakeDestinationProbe,
    input: FakeInput = FakeInput(),
    rules: PrivacyRules = PrivacyRules(),
    quiescence: Bool = true,
    frontmost: TargetApp? = editor,
    secureInput: Bool = false,
    clock: ManualTimeSource = ManualTimeSource()
) -> DestinationVerifier {
    DestinationVerifier(
        gate: PrivacyGate(rules),
        probe: probe,
        policies: policies(quiescence: quiescence),
        epochs: input,
        frontmost: { frontmost },
        secureInputIsActive: { secureInput },
        timing: .initial,
        now: clock.reader
    )
}

private func snapshot(
    strategy: SelectionStrategyKind? = .ax,
    handle: DestinationHandle? = DestinationHandle(rawValue: 1),
    range: AXTextRange? = selectedRange,
    text: String? = "selected",
    epoch: InputEpoch? = InputEpoch(rawValue: 0),
    at clock: ManualTimeSource
) -> DestinationSnapshot {
    DestinationSnapshot(
        attempt: AttemptID(rawValue: 3),
        route: .automatic,
        target: editor,
        handle: handle,
        range: range,
        text: text.map(TextDigest.init),
        strategy: strategy,
        epoch: epoch,
        taken: clock.now
    )
}

/// What a test can learn about a verification without keeping the permit inside it: the tier it
/// granted, and everything that went wrong if it granted none. The permit dies with the value, which
/// is the only thing that can happen to one it does not hand to a mutation.
private struct Outcome {
    var tier: DestinationTier
    var failures: [DestinationFailure]
    var primary: DestinationFailure?
    var denial: PrivacyDenialReason?
    var range: AXTextRange?
}

private func outcome(_ verification: consuming DestinationVerification) -> Outcome {
    let block = verification.block
    var result = Outcome(
        tier: verification.tier,
        failures: block?.failures ?? [],
        primary: block?.primary,
        denial: block?.denial
    )
    result.range = verification.permit()?.range
    return result
}

/// RUN-2. The tiers, as rules over evidence: no Accessibility grant, no window server and no other app
/// is involved in any of it, because the judging and the looking are two different objects.
@Suite struct DestinationVerifierTests {
    // MARK: The Accessibility tier

    @Test func nothingHasMovedSoTheTopTierIsGranted() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())

        let result = outcome(await verifier(probe, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier == .accessibility)
        #expect(result.range == selectedRange)
    }

    /// The tier's whole content: four facts about where, and two about what.
    @Test(arguments: [
        (DestinationEvidence(isFrontmost: false, sameWindow: true, sameElement: true, isEditable: true), DestinationFailure.notFrontmost),
        (DestinationEvidence(isFrontmost: true, sameWindow: false, sameElement: true, isEditable: true), .windowChanged),
        (DestinationEvidence(isFrontmost: true, sameWindow: true, sameElement: false, isEditable: true), .elementChanged),
        (DestinationEvidence(isFrontmost: true, sameWindow: true, sameElement: true, isEditable: false), .notEditable),
    ])
    func anyOneOfThemGoneIsEnoughToLoseTheTier(evidence: DestinationEvidence, failure: DestinationFailure) async {
        let clock = ManualTimeSource()
        var evidence = evidence
        evidence.range = selectedRange
        evidence.text = TextDigest("selected")

        let result = outcome(await verifier(FakeDestinationProbe(evidence), clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier != .accessibility)
        #expect(result.failures.contains(failure))
    }

    /// The text is compared as a digest, which is enough to tell "the same" from "not the same" and is
    /// the only question ever asked of it.
    @Test func editingTheSourceWhileTheResultIsPendingBlocksEverything() async {
        let clock = ManualTimeSource()
        var evidence = settled()
        evidence.text = TextDigest("selected, then edited")

        let result = outcome(await verifier(FakeDestinationProbe(evidence), clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier == .unverifiable)
        #expect(result.failures.contains(.selectionChanged))
    }

    @Test func movingTheSelectionBlocksEverything() async {
        let clock = ManualTimeSource()
        var evidence = settled()
        evidence.range = AXTextRange(location: 40, length: 5)

        let result = outcome(await verifier(FakeDestinationProbe(evidence), clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier == .unverifiable)
        #expect(result.failures.contains(.selectionMoved))
    }

    /// RUN-2c and the reason every field of `DestinationEvidence` is optional: an app that will not say
    /// whether the element is the same one has not said yes.
    @Test func silenceIsNotAgreementAtTheTopTier() async {
        let clock = ManualTimeSource()
        let input = FakeInput()
        let probe = FakeDestinationProbe(DestinationEvidence(
            isFrontmost: true,
            sameWindow: true,
            sameElement: nil,
            isEditable: true,
            range: selectedRange,
            text: TextDigest("selected")
        ))
        let taken = snapshot(at: clock)

        // Everything else agrees, so the top tier is lost on the one unanswered question alone. What
        // is left is the middle tier, which does not ask it.
        let quiet = outcome(await verifier(probe, input: input, clock: clock)
            .verify(InvocationID(rawValue: 1), against: taken))

        // Take the middle tier away too, and the unanswered question is there in the record.
        input.happened()
        let typed = outcome(await verifier(probe, input: input, clock: clock)
            .verify(InvocationID(rawValue: 2), against: taken))

        #expect(quiet.tier == .quiescence)
        #expect(typed.tier == .unverifiable)
        #expect(typed.failures.contains(.accessibilityUnanswered))
    }

    // MARK: The quiescence tier

    /// The tier G4 exists for: a Chromium window that answers nothing, read by synthetic ⌘C, with a
    /// keyboard nobody has touched.
    @Test func aClipboardReadInASilentAppIsQuiescenceVerified() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true))

        let result = outcome(await verifier(probe, clock: clock)
            .verify(
                InvocationID(rawValue: 1),
                against: snapshot(strategy: .syntheticCopy, handle: nil, at: clock)
            ))

        #expect(result.tier == .quiescence)
        // Nothing fresh to carry, so the permit carries the snapshot's own range.
        #expect(result.range == selectedRange)
    }

    /// An app that went quiet after an Accessibility read falls through to the middle tier rather than
    /// straight to unverifiable, and earns it on the same evidence a strategy-5 read would.
    @Test func anAccessibilityReadWhoseAppGoesQuietFallsThroughToQuiescence() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true, fault: .unsupported))

        let result = outcome(await verifier(probe, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier == .quiescence)
    }

    /// The contradiction rule: the middle tier tolerates an app that says nothing, never one that says
    /// the selection is somewhere else.
    @Test func aContradictionIsNotSilenceAndDoesNotFallThrough() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(
            isFrontmost: true,
            sameWindow: false,
            range: AXTextRange(location: 99, length: 1)
        ))

        let result = outcome(await verifier(probe, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(strategy: .syntheticCopy, at: clock)))

        #expect(result.tier == .unverifiable)
        #expect(result.failures.contains(.windowChanged))
        #expect(result.failures.contains(.selectionMoved))
    }

    /// RUN-2g, the event the tier is named after.
    @Test func oneKeystrokeSinceTheSnapshotEndsTheTier() async {
        let clock = ManualTimeSource()
        let input = FakeInput()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true))
        let taken = snapshot(strategy: .syntheticCopy, at: clock)

        input.happened()

        let result = outcome(await verifier(probe, input: input, clock: clock)
            .verify(InvocationID(rawValue: 1), against: taken))

        #expect(result.tier == .unverifiable)
        #expect(result.primary == .inputSinceSnapshot)
    }

    /// A snapshot with no epoch is one taken with no key tap behind it. Being blind to keystrokes is
    /// not the same as having seen none (architecture §19 item 1).
    @Test func noKeyTapMeansNoQuiescenceTier() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true))

        let result = outcome(await verifier(probe, clock: clock)
            .verify(
                InvocationID(rawValue: 1),
                against: snapshot(strategy: .syntheticCopy, epoch: nil, at: clock)
            ))

        #expect(result.tier == .unverifiable)
        #expect(result.failures.contains(.inputUnwatchable))
    }

    @Test func theWindowOfTimeCloses() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true))
        let taken = snapshot(strategy: .syntheticCopy, at: clock)

        clock.advance(by: .milliseconds(2_999))
        let inTime = outcome(await verifier(probe, clock: clock)
            .verify(InvocationID(rawValue: 1), against: taken))

        clock.advance(by: .milliseconds(2))
        let tooLate = outcome(await verifier(probe, clock: clock)
            .verify(InvocationID(rawValue: 2), against: taken))

        #expect(inTime.tier == .quiescence)
        #expect(tooLate.tier == .unverifiable)
        #expect(tooLate.failures.contains(.windowExpired))
    }

    /// RUN-5's "slow translation in Notes followed by switching to Terminal".
    @Test func switchingToAnotherAppEndsBothTiers() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: false))

        let result = outcome(await verifier(probe, frontmost: terminal, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(strategy: .syntheticCopy, at: clock)))

        #expect(result.tier == .unverifiable)
        #expect(result.primary == .notFrontmost)
    }

    // MARK: What a policy may and may not do (RUN-2h)

    @Test func aPolicyCanTurnTheMiddleTierOffForAnApp() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence(isFrontmost: true))
        let taken = snapshot(strategy: .syntheticCopy, at: clock)

        let allowed = outcome(await verifier(probe, quiescence: true, clock: clock)
            .verify(InvocationID(rawValue: 1), against: taken))
        let refused = outcome(await verifier(probe, quiescence: false, clock: clock)
            .verify(InvocationID(rawValue: 2), against: taken))

        #expect(allowed.tier == .quiescence)
        #expect(refused.tier == .unverifiable)
        #expect(refused.failures.contains(.quiescenceNotAllowed))
    }

    /// The other half of RUN-2h, and the one a policy file cannot talk its way around: there is no
    /// combination of settings that produces a permit from evidence this thin, because the only code
    /// that mints one is the two tiers above.
    @Test func noPolicyReachesTheUnverifiableTier() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(DestinationEvidence.unanswered())

        let result = outcome(await verifier(probe, quiescence: true, frontmost: nil, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(strategy: .syntheticCopy, at: clock)))

        #expect(result.tier == .unverifiable)
        #expect(result.range == nil)
        #expect(!DestinationTier.unverifiable.permitsMutation)
    }

    // MARK: The gate, first and every time (RUN-2f)

    @Test(arguments: [
        (PrivacyRules(hardBlockedApps: ["com.example.editor"]), PrivacyDenialReason.appHardBlocked),
        (PrivacyRules(pause: .untilResumed), .pausedUntilResumed),
    ])
    func aRefusalAtExecutionTimeStopsTheLookBeforeItHappens(rules: PrivacyRules, reason: PrivacyDenialReason) async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())

        let result = outcome(await verifier(probe, rules: rules, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier == .unverifiable)
        #expect(result.primary == .privacyRefused)
        #expect(result.denial == reason)
        // No permit was minted, so there was nothing to read the selection with.
        #expect(probe.looks.isEmpty)
    }

    @Test func secureInputTurningOnUnderARunningActionRefuses() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())

        let result = outcome(await verifier(probe, secureInput: true, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.denial == .secureInputActive)
        #expect(probe.looks.isEmpty)
    }

    /// The appearance settings are step 3 and have nothing to say here: the bar is already on screen
    /// and the user has already clicked it.
    @Test func turningOffAutomaticAppearanceDoesNotBlockAnActionAlreadyRunning() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())
        let rules = PrivacyRules(appearAutomatically: false, appModes: ["com.example.editor": .hotkeyOnly])

        let result = outcome(await verifier(probe, rules: rules, clock: clock)
            .verify(InvocationID(rawValue: 1), against: snapshot(at: clock)))

        #expect(result.tier == .accessibility)
    }

    @Test func theLookIsMadeOnceAndCarriesTheInvocationsOwnRoute() async {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())
        let taken = DestinationSnapshot(
            attempt: AttemptID(rawValue: 3),
            route: .hotkey,
            target: editor,
            handle: DestinationHandle(rawValue: 9),
            range: selectedRange,
            text: TextDigest("selected"),
            strategy: .ax,
            epoch: .start,
            taken: clock.now
        )

        _ = outcome(await verifier(probe, clock: clock).verify(InvocationID(rawValue: 1), against: taken))

        #expect(probe.looks.count == 1)
        #expect(probe.looks.first?.route == .hotkey)
        #expect(probe.looks.first?.handle == DestinationHandle(rawValue: 9))
        #expect(probe.looks.first?.frontmost == editor)
    }
}
