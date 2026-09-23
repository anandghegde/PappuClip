import PappuAX
import PappuCore

/// How well the destination is known (safety spec §S3, RUN-2).
///
/// Ordered, and the order is the point: a rule that says "at least quiescence-verified" is written as
/// a comparison rather than as a list somebody has to keep up to date.
public enum DestinationTier: String, Sendable, Codable, CaseIterable, Comparable {
    /// Anything else. No mutation, at any tier, for any app, by any policy.
    case unverifiable
    /// Same frontmost process and window, no user input since the snapshot, inside the time window,
    /// and the app's policy allows it. For the apps whose selection could not be read through
    /// Accessibility at all.
    case quiescence
    /// Same process, window and focused element; still editable; the selection has not moved and has
    /// not changed.
    case accessibility

    private var rank: Int {
        switch self {
        case .unverifiable: 0
        case .quiescence: 1
        case .accessibility: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Whether text may be written to a destination known this well (RUN-2b, RUN-2c).
    public var permitsMutation: Bool { self > .unverifiable }
}

/// Why a destination did not reach a tier: one code per rule, as `PrivacyDenialReason` is for §S1.
///
/// A verification collects every reason that applied rather than the first, because the answer a user
/// gets — "Replace is off because you clicked in another window" (RUN-2e) — is better for naming the
/// one that will still be true a moment from now.
public enum DestinationFailure: String, Sendable, Codable, CaseIterable {
    /// The privacy rules refused at execution time (RUN-2f). The reason itself is in `denial`.
    case privacyRefused
    /// The invocation was cancelled, paused out or revoked before the check ran (RUN-3b, RUN-3f).
    case invocationNotRunning
    /// The app the text came from is not the app in front.
    case notFrontmost
    /// A different window of the same app.
    case windowChanged
    /// A different focused element: another field, another pane, or focus moved away.
    case elementChanged
    /// The element cannot be typed into, so it is not somewhere text can go (FLT-6).
    case notEditable
    /// The selection is in a different place than it was.
    case selectionMoved
    /// The selection is in the same place and says something else.
    case selectionChanged
    /// Accessibility would not answer, so nothing above could be compared.
    case accessibilityUnanswered
    /// The text was read by strategy 4 or 5, so there is no range to compare and the Accessibility
    /// tier was never available. Not a failure by itself — it is why the quiescence tier is being
    /// asked at all.
    case notReadThroughAccessibility
    /// Keys or the pointer have been used since the snapshot (RUN-2g).
    case inputSinceSnapshot
    /// The key tap could not be installed, so PappuClip cannot say whether anything was typed. It
    /// says so rather than assuming nothing was (RUN-2g).
    case inputUnwatchable
    /// More than the quiescence window has gone by.
    case windowExpired
    /// The app's detection policy turns the quiescence tier off here (RUN-2h).
    case quiescenceNotAllowed
}

/// Proof that RUN-2 ran and the destination is known well enough to write to (architecture §3.1, §3.5).
///
/// `init` is internal to this module, so `DestinationVerifier` is the only thing in the program that
/// can make one, and `TextMutator` takes one as a parameter — so a path that mutates text without
/// verifying the destination does not compile. It is `~Copyable` and consumed by the mutation it
/// authorises, so one verification cannot pay for two pastes.
public struct MutationPermit: ~Copyable, Sendable {
    public let invocation: InvocationID
    /// Never `.unverifiable`: there is no way to mint one at that tier (RUN-2c).
    public let tier: DestinationTier
    public let target: TargetApp
    /// Where the selection is now, as the verification found it. Insert collapses to its end, which is
    /// why this is the *fresh* range and not the snapshot's (architecture §8.3).
    public let range: AXTextRange?

    init(invocation: InvocationID, tier: DestinationTier, target: TargetApp, range: AXTextRange?) {
        self.invocation = invocation
        self.tier = tier
        self.target = target
        self.range = range
    }
}

/// Why a mutation was blocked, for the disabled control's explanation (RUN-2e) and the trace.
///
/// Codes and identifiers only. Nothing here can carry a word of the selection.
public struct DestinationBlock: Sendable, Equatable {
    public let invocation: InvocationID
    public let target: TargetApp
    /// Every rule that failed, in the order the verifier checks them.
    public let failures: [DestinationFailure]
    /// The privacy rule that refused, when one did (RUN-2f).
    public let denial: PrivacyDenialReason?
    /// What Accessibility would not do, when that is why.
    public let fault: AXFault?

    init(
        invocation: InvocationID,
        target: TargetApp,
        failures: [DestinationFailure],
        denial: PrivacyDenialReason? = nil,
        fault: AXFault? = nil
    ) {
        self.invocation = invocation
        self.target = target
        self.failures = failures
        self.denial = denial
        self.fault = fault
    }

    /// The reason to put in front of the user, which is the first rule that failed: the checks run
    /// from the most specific to the least, so the first is the one that says the most.
    public var primary: DestinationFailure? { failures.first }
}

/// The outcome of RUN-2: a permit or the reasons there is none. There is no third case, and neither
/// can be built from outside this module — the same shape as `PrivacyDecision`, for the same reason.
public enum DestinationVerification: ~Copyable, Sendable {
    case verified(MutationPermit)
    case blocked(DestinationBlock)

    public var isVerified: Bool {
        switch self {
        case .verified: true
        case .blocked: false
        }
    }

    /// The tier reached. `.unverifiable` when blocked, which is what that case means (RUN-2c).
    public var tier: DestinationTier {
        switch self {
        case .verified(let permit): permit.tier
        case .blocked: .unverifiable
        }
    }

    /// Why there is no permit. Nil when there is one.
    public var block: DestinationBlock? {
        switch self {
        case .verified: nil
        case .blocked(let block): block
        }
    }

    /// Takes the permit out, ending the verification. The mutator is meant to consume it at once:
    /// every moment between the check and the paste is a moment the destination can move.
    public consuming func permit() -> MutationPermit? {
        switch consume self {
        case .verified(let permit): permit
        case .blocked: nil
        }
    }
}
