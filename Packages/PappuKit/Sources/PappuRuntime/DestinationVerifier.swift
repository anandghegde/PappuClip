import Foundation
import PappuAX
import PappuCore
import PappuSelection

/// RUN-2: the one place that decides whether text may be written to where it came from
/// (architecture §8.2, safety spec §S3).
///
/// Everything it needs it is handed: the evidence comes from `DestinationProbing`, the rules from
/// `PrivacyGate` and `DetectionPolicyStore`, the input count from `InputEpochReading`, the time from
/// a closure. What is *here* is the judgement, which is why it is the part with the tests.
///
/// Three properties are worth naming because they are structural rather than promised:
///
/// - **A policy can only take away.** The tier is computed from evidence; `DetectionPolicy.quiescence`
///   is consulted in one place and can only turn the middle tier off (RUN-2h). No field of any policy,
///   local or signed, is read on the path that mints a permit at the top tier, and none can reach the
///   bottom one, because there is no code that mints a permit for `.unverifiable`.
/// - **The privacy rules run first, every time** (RUN-2f), and their permit is what pays for the
///   selection re-read. A verification that skipped the gate would have nothing to read with.
/// - **Silence is never agreement.** Every piece of evidence is three-valued, and a `nil` fails the
///   Accessibility tier rather than passing it.
public struct DestinationVerifier: Sendable {
    private let gate: PrivacyGate
    private let probe: any DestinationProbing
    private let policies: DetectionPolicyStore
    private let epochs: any InputEpochReading
    private let frontmost: @Sendable () -> TargetApp?
    private let secureInputIsActive: @Sendable () -> Bool
    private let timing: InvocationTiming
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - frontmost: The app in front. `NSWorkspace.frontmostApplication` in the app; there is no
    ///     default because this module does not depend on AppKit (architecture §15).
    ///   - epochs: The tap service, which counts input the user made and never input PappuClip posted
    ///     (architecture §3.4).
    public init(
        gate: PrivacyGate,
        probe: any DestinationProbing,
        policies: DetectionPolicyStore,
        epochs: any InputEpochReading,
        frontmost: @escaping @Sendable () -> TargetApp?,
        secureInputIsActive: @escaping @Sendable () -> Bool = { SecureInput.isActiveSystemWide },
        timing: InvocationTiming = .initial,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.gate = gate
        self.probe = probe
        self.policies = policies
        self.epochs = epochs
        self.frontmost = frontmost
        self.secureInputIsActive = secureInputIsActive
        self.timing = timing
        self.now = now
    }

    /// Verifies the destination of `invocation` against `snapshot`, now (RUN-2a).
    ///
    /// Called before every host-controlled effect, and again at click time for the explicit Replace
    /// and Insert controls (RUN-2e) — the same call, because there is only one rule.
    public func verify(
        _ invocation: InvocationID,
        against snapshot: DestinationSnapshot
    ) async -> DestinationVerification {
        let target = snapshot.target

        // 1. The privacy rules, first and every time (RUN-2f). Its permit is what the re-read spends.
        //
        //    The secure-input state is the system-wide flag alone. The focused field's own role was
        //    judged when the selection was read; if focus has since moved into a password field, the
        //    element comparison below fails anyway, and the system-wide flag is the half that can
        //    become true under an invocation that is already running (ACT-12).
        let decision = gate.evaluateAtExecution(
            route: snapshot.route,
            target: target,
            secureInput: SecureInputState(systemWide: secureInputIsActive(), focusedFieldIsSecure: false)
        )
        // Read the reason before taking the permit: `permit()` consumes the decision.
        let denial = decision.denial?.reason
        guard let permit = decision.permit() else {
            return .blocked(
                DestinationBlock(
                    invocation: invocation,
                    target: target,
                    failures: [.privacyRefused],
                    denial: denial
                )
            )
        }

        // 2. One look at the world, spending the permit on it.
        let evidence = await probe.look(
            for: snapshot.handle,
            in: target,
            frontmost: frontmost(),
            permit: permit
        )

        // 3. The top tier, if the selection was read through Accessibility at all.
        var failures: [DestinationFailure] = []
        if snapshot.wasReadThroughAccessibility {
            let accessibility = accessibilityFailures(snapshot, evidence)
            if accessibility.isEmpty {
                return .verified(
                    MutationPermit(
                        invocation: invocation,
                        tier: .accessibility,
                        target: target,
                        range: evidence.range ?? snapshot.range
                    )
                )
            }
            failures = accessibility
        } else {
            failures = [.notReadThroughAccessibility]
        }

        // 4. The middle tier. Reached two ways: the text was read without Accessibility, or it was
        //    read with it and the destination has since moved beyond recognition. The second is the
        //    one worth being careful about — a known-different window or element is a *worse* answer
        //    than no answer, so it disqualifies the middle tier too, and `quiescenceFailures` says so
        //    rather than leaving it to the reader.
        let quiescence = quiescenceFailures(snapshot, evidence)
        if quiescence.isEmpty {
            return .verified(
                MutationPermit(
                    invocation: invocation,
                    tier: .quiescence,
                    target: target,
                    range: evidence.range ?? snapshot.range
                )
            )
        }

        // 5. Unverifiable (RUN-2c). The caller shows the result for explicit copy and writes nothing.
        //
        //    The middle tier's failures come first because they are the operative ones — it was the
        //    last tier that could have said yes — and `primary` is what the bar shows the user. A
        //    snapshot that was never read through Accessibility keeps `.notReadThroughAccessibility`
        //    at the end of the list: it explains why the top tier was not tried, which is a thing the
        //    inspector wants and not a thing to tell the user their paste failed for.
        return .blocked(
            DestinationBlock(
                invocation: invocation,
                target: target,
                failures: quiescence + failures.filter { !quiescence.contains($0) },
                fault: evidence.fault
            )
        )
    }

    // MARK: The tiers

    /// Same process, window and element; editable; the selection where it was and what it was.
    ///
    /// Order matters only for the message: the first failure is the one shown (RUN-2e), so the checks
    /// run from the outside in — which app, which window, which element, then what is in it.
    private func accessibilityFailures(
        _ snapshot: DestinationSnapshot,
        _ evidence: DestinationEvidence
    ) -> [DestinationFailure] {
        var failures: [DestinationFailure] = []
        if evidence.isFrontmost != true { failures.append(.notFrontmost) }
        if evidence.sameWindow == false { failures.append(.windowChanged) }

        switch evidence.sameElement {
        case .some(true):
            break
        case .some(false):
            failures.append(.elementChanged)
        case .none:
            // Nothing to compare: the app has no Accessibility tree, or would not answer this time.
            // Either way the top tier is out of reach, and silence is not agreement.
            failures.append(.accessibilityUnanswered)
        }

        if evidence.isEditable != true { failures.append(.notEditable) }

        // A caret has no range and no text to compare, and an action that mutates a caret — Paste —
        // is about where the caret is, which the element and the range below answer.
        if let expected = snapshot.range {
            if evidence.range != expected { failures.append(.selectionMoved) }
        } else if evidence.range == nil, snapshot.text != nil {
            // The strategy read text but no range, so there is nothing to compare positions with.
            failures.append(.accessibilityUnanswered)
        }

        if let expected = snapshot.text {
            switch evidence.text {
            case .some(expected): break
            case .some: failures.append(.selectionChanged)
            case .none: failures.append(.accessibilityUnanswered)
            }
        }

        return failures.reduce(into: []) { unique, failure in
            if !unique.contains(failure) { unique.append(failure) }
        }
    }

    /// Same app in front, same window as far as anyone can tell, nobody has typed, and inside the
    /// window of time (safety spec §S3).
    ///
    /// The spec's table says this tier "applies when the selection was read without Accessibility",
    /// and the code is slightly wider than that: a selection that *was* read through Accessibility but
    /// whose app has since gone quiet — no tree, no answer, a WebKit process that restarted — falls
    /// through to here rather than straight to unverifiable. The evidence required is the same as for a
    /// strategy-5 read, so the guarantee is the same one; the alternative is that a transient silence
    /// turns an ordinary transformation into a refusal in exactly the apps G4 is about. What does not
    /// fall through is a contradiction, checked below.
    ///
    /// The window check tolerates `nil` and the element check is not made at all, and that is the
    /// tier's whole point: it exists for the apps that answer nothing through Accessibility, so
    /// requiring an Accessibility answer would leave it empty. What it does not tolerate is a
    /// *contradiction* — a window we can see and can see is a different one.
    ///
    /// The residue is recorded rather than papered over: in an app that answers no window, a user who
    /// switched windows without touching the keyboard or the mouse inside the time window would pass
    /// this tier. Switching windows takes a click or a keystroke, both of which move the epoch, so the
    /// hole needs a window that changed by itself.
    private func quiescenceFailures(
        _ snapshot: DestinationSnapshot,
        _ evidence: DestinationEvidence
    ) -> [DestinationFailure] {
        var failures: [DestinationFailure] = []
        if evidence.isFrontmost != true { failures.append(.notFrontmost) }
        if evidence.sameWindow == false { failures.append(.windowChanged) }
        if evidence.sameElement == false { failures.append(.elementChanged) }
        if evidence.isEditable == false { failures.append(.notEditable) }

        // Silence is tolerated here; a contradiction is not. If the app did answer where the selection
        // is or what it says, and the answer disagrees with the snapshot, the quiet keyboard is beside
        // the point — something moved the selection, and the middle tier is not a way around an app
        // that just said so.
        if let expected = snapshot.range, let fresh = evidence.range, fresh != expected {
            failures.append(.selectionMoved)
        }
        if let expected = snapshot.text, let fresh = evidence.text, fresh != expected {
            failures.append(.selectionChanged)
        }

        // RUN-2g. A nil epoch is a missing key tap, and a missing key tap means we cannot say whether
        // anything was typed — which is a refusal, not a pass (architecture §19 item 1).
        switch snapshot.epoch {
        case .none:
            failures.append(.inputUnwatchable)
        case .some(let epoch):
            if epochs.inputEpoch != epoch { failures.append(.inputSinceSnapshot) }
        }

        if snapshot.taken.duration(to: now()) > timing.quiescenceWindow {
            failures.append(.windowExpired)
        }

        // RUN-2h, and the one place a policy is read on this path. It can turn the tier off; there is
        // no value it can carry that turns anything on.
        if !policies.policy(for: snapshot.target).quiescence {
            failures.append(.quiescenceNotAllowed)
        }

        return failures
    }
}
