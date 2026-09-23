import CryptoKit
import Foundation
import PappuAX
import PappuCore
import PappuSelection

/// A fingerprint of the selection, for asking whether it is still what it was without keeping what it
/// was (RUN-1a, RUN-2).
///
/// The Accessibility tier compares the selection at click time against the selection at invocation
/// time. Holding the text itself for the life of an invocation would put a copy of the user's
/// selection in a second place for no reason, so the snapshot holds this instead: a SHA-256 of the
/// text and its length in characters.
///
/// It is deliberately absent from `InvocationRecord`. A digest is not text, but a digest of "yes" is
/// a digest of "yes" to anyone who tries the obvious inputs, and a trace that outlives the invocation
/// is the wrong place for one. Records carry codes, identifiers and counts (architecture §4.3).
public struct TextDigest: Sendable, Equatable, Hashable {
    /// How long the text was. A length alone rules out most changes and costs nothing to compare.
    public let characters: Int
    private let bytes: [UInt8]

    public init(_ text: String) {
        characters = text.count
        bytes = Array(SHA256.hash(data: Data(text.utf8)))
    }
}

extension TextDigest: CustomStringConvertible {
    /// Short, because it appears in test failures and nowhere else; long enough to tell two apart.
    public var description: String {
        "digest(\(characters):" + bytes.prefix(4).map { String(format: "%02x", $0) }.joined() + ")"
    }
}

/// What the Accessibility side is holding for one invocation.
///
/// `AXElement` never leaves `AXActor` (architecture §4.3), so a snapshot cannot carry the focused
/// element it means. It carries this instead: a number the probe issued, which the probe can turn
/// back into the elements it captured. The elements are dropped when the invocation ends, so a
/// finished invocation holds no handle on a window that may since have closed.
public struct DestinationHandle: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "destination#\(rawValue)" }
}

/// Where an action's text came from, frozen at the moment the user asked for it (RUN-1a).
///
/// Immutable by construction: everything that happens afterwards — an app switch, a focus change, a
/// keystroke — is recorded beside it and never written into it, which is RUN-1b in one sentence. The
/// verifier compares the world against this; nothing updates it.
public struct DestinationSnapshot: Sendable, Equatable {
    /// The attempt whose read this text came from, so a trace can be followed from bar to paste.
    public let attempt: AttemptID
    public let route: ActivationRoute
    /// The app the text was read from, pinned by pid.
    public let target: TargetApp
    /// The Accessibility side's handle on the focused window and element, when there was one to take.
    /// Nil for an app with no Accessibility tree, which is exactly the case the quiescence tier exists
    /// for.
    public let handle: DestinationHandle?
    /// Where the selection was. Nil when the strategy that read it could not say.
    public let range: AXTextRange?
    /// What the selection was, as a hash. Nil for a caret, where there is nothing to compare (ACT-3).
    public let text: TextDigest?
    /// Which strategy read it, which is what decides whether the Accessibility tier is even available
    /// (strategies 1–3) or the quiescence tier is the best there is (4–5).
    public let strategy: SelectionStrategyKind?
    /// How much input the taps had seen when the snapshot was taken (RUN-2g).
    ///
    /// Nil means the key tap could not be installed, so PappuClip is blind to keystrokes and must say
    /// so rather than assume none happened. A nil epoch can never reach the quiescence tier.
    public let epoch: InputEpoch?
    /// The invocation's own monotonic start, which the quiescence window is measured from.
    public let taken: ContinuousClock.Instant

    public init(
        attempt: AttemptID,
        route: ActivationRoute,
        target: TargetApp,
        handle: DestinationHandle? = nil,
        range: AXTextRange? = nil,
        text: TextDigest? = nil,
        strategy: SelectionStrategyKind? = nil,
        epoch: InputEpoch? = nil,
        taken: ContinuousClock.Instant
    ) {
        self.attempt = attempt
        self.route = route
        self.target = target
        self.handle = handle
        self.range = range
        self.text = text
        self.strategy = strategy
        self.epoch = epoch
        self.taken = taken
    }

    /// Whether the selection was read through Accessibility, which is what the top tier needs
    /// (safety spec §S3). A snapshot with no strategy — a caret, a script route with nothing read —
    /// is not on the Accessibility path by default: the tier has to be earned.
    public var wasReadThroughAccessibility: Bool {
        guard let strategy else { return false }
        return strategy.path == .accessibility
    }
}
