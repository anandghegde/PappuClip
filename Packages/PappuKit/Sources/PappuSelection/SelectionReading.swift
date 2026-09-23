import CoreGraphics
import PappuAX
import PappuCore

/// What one run of the strategy chain came back with (architecture §4.5).
///
/// The outcome is its own value rather than a `String?` because "there is a caret here and nothing is
/// selected" and "there is nothing here to read" lead to different bars: the first is ACT-3's, where
/// Paste must be reachable, and the second is no bar at all.
public struct SelectionRead: Sendable, Equatable {
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        /// A strategy read a selection.
        case text
        /// A place a caret can sit, with nothing selected (ACT-3).
        case caretOnly
        /// Every strategy in the chain ran and none of them found anything.
        case nothing
        /// No strategy could run: an empty chain, or an app that refused every one of them.
        case refused
        /// The hard cutoff arrived first (ACT-16a, PRD §11.1).
        case outOfBudget
    }

    public var outcome: Outcome
    /// The selection. Nil for every outcome but `.text`.
    public var text: String?
    /// Where the selection is now, which is what ACT-14's baseline is compared against.
    public var range: AXTextRange?
    /// Where to draw the bar (BAR-3). Nil when the app would not say, and then the pointer is used.
    public var bounds: CGRect?
    /// Which strategy answered, for the inspector (DIA-2) and for the per-app policy work (ACT-11a).
    public var strategy: SelectionStrategyKind?

    public init(
        outcome: Outcome,
        text: String? = nil,
        range: AXTextRange? = nil,
        bounds: CGRect? = nil,
        strategy: SelectionStrategyKind? = nil
    ) {
        self.outcome = outcome
        self.text = text
        self.range = range
        self.bounds = bounds
        self.strategy = strategy
    }

    public static let nothing = SelectionRead(outcome: .nothing)
}

/// The strategy chain of ACT-9, as the coordinator sees it: one call, the whole chain, first success wins.
///
/// `SelectionStrategyChain` is the implementation; this stays a protocol because the coordinator has a
/// great deal to say about attempts and nothing to say about Accessibility, and a test of the gate, the
/// budget or the invalidation rules should not have to stand up an AX tree to say it.
///
/// It consumes the permit: there is no way to call it without one, and no way to call it twice with the
/// same one (architecture §3.1). The attempt travels beside the permit rather than on it because the
/// permit answers "may this app be read", which is a question about the app, and strategy 5 needs a
/// second permit of its own that names the attempt the one ⌘C belongs to (ACT-10j).
public protocol SelectionReading: Sendable {
    func read(
        _ permit: consuming ReadPermit,
        attempt: AttemptID,
        chain: [SelectionStrategyKind],
        clock: AttemptClock
    ) async -> SelectionRead
}
