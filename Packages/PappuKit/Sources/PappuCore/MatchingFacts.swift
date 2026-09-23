import Foundation

/// Everything the matching pipeline is allowed to ask about one selection (§8.5).
///
/// **Why a separate type rather than the analysis and the context themselves.** The pipeline runs in
/// three places that do not share a machine: the app, `pappu-dev` checking a manifest from a file, and
/// the registry's CI deciding whether a submitted extension would ever show a button. Only the first
/// has an Accessibility tree, a focused element or a frontmost app. Stating the pipeline's whole input
/// as a value keeps the other two honest — a fact that is not on this list is a fact no requirement
/// can ever turn on — and it is what makes `ActionMatching` a pure function worth testing exhaustively.
///
/// Assembling one is `ActionResolver`'s job (architecture §6.3), because it is the only place that
/// holds the analysis, the context and the clipboard at once.
public struct MatchingFacts: Sendable, Equatable {
    /// One thing in the selection a requirement can narrow to (§8.5 step 3).
    ///
    /// A flattened `Detection` with only what matching needs. Both `http` and non-`http` addresses are
    /// `.url` here, the same rule `AnalyzedSelection.isSingleURL` follows: an action that asks for a
    /// link means a link, and `omnifocus:///task/1` is one. Nothing downstream loses the distinction —
    /// Open Link reads the analysis, not this.
    public struct Address: Sendable, Equatable, Hashable, Codable {
        public var kind: NarrowingKind
        public var span: TextSpan
        /// Normalised, as the analyser produced it: a scheme on a bare domain, `~` resolved in a path.
        public var value: String

        public init(kind: NarrowingKind, span: TextSpan, value: String) {
            self.kind = kind
            self.span = span
            self.value = value
        }
    }

    /// The selection as read. Stays available whatever an action narrows to (§8.5 step 5).
    public var text: String
    /// In the order they appear in the text.
    public var addresses: [Address]
    /// `isurl`: the selection is one address and nothing else.
    public var isSingleAddress: Bool
    /// What `requiredApps` and `excludedApps` are matched against. Nil for a process with no bundle,
    /// which is not a reason to hide unrestricted actions — only restricted ones.
    public var bundleID: String?
    /// FLT-6, after the read-only rule has been applied to what the Edit menu said.
    public var canCut: Bool
    public var canPaste: Bool
    /// The control can describe its text with attributes.
    public var hasFormatting: Bool

    public init(
        text: String,
        addresses: [Address] = [],
        isSingleAddress: Bool = false,
        bundleID: String? = nil,
        canCut: Bool = false,
        canPaste: Bool = false,
        hasFormatting: Bool = false
    ) {
        self.text = text
        self.addresses = addresses
        self.isSingleAddress = isSingleAddress
        self.bundleID = bundleID
        self.canCut = canCut
        self.canPaste = canPaste
        self.hasFormatting = hasFormatting
    }

    /// There is a selection (`text`, and its older spelling `copy`).
    ///
    /// Untrimmed on purpose: whether whitespace alone counts as a selection is the *activation*
    /// question, settled before any of this by the gesture policies, and answering it twice with two
    /// different rules is how an action comes and goes for reasons nobody can name.
    public var hasText: Bool { !text.isEmpty }

    public func addresses(_ kind: NarrowingKind) -> [Address] {
        addresses.filter { $0.kind == kind }
    }

    public func firstAddress(_ kind: NarrowingKind) -> Address? {
        addresses.first { $0.kind == kind }
    }
}
