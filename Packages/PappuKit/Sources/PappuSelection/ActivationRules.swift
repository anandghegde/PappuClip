import PappuAX
import PappuCore

/// Whether a bar appears, and — when it does not — the reason the inspector gives (DIA-2, BAR-13).
public enum AppearanceVerdict: String, Sendable, Codable, CaseIterable {
    /// Text came back, and the gesture is what selected it.
    case selection
    /// A caret in a field one can type into, with nothing selected: ACT-3's long press, and the
    /// double-click or Shift-click in an empty field.
    case caret
    /// The selection is exactly where it was before the gesture, so the gesture selected nothing and the
    /// text that came back is the one the user already had.
    case unchangedRange
    /// The chain ran and nothing came back.
    case noText
    /// Nothing textual was under the pointer or focused, and nothing came back.
    case nothingTextual
    /// No strategy could read this app at all.
    case unreadable
    /// The app's detection policy does not allow a bar on this path (ACT-11a).
    case policyDisallows
    /// The user held ⌘ during the gesture, which says "not this one" (ACT-7).
    case suppressed
    /// The read did not finish inside the hard cutoff (ACT-16a).
    case outOfBudget

    public var showsBar: Bool { self == .selection || self == .caret }
}

/// The signals ACT-14 asks to be weighed together, gathered in one value so that the weighing is a pure
/// function and every case of it is a test.
public struct ActivationSignals: Sendable, Equatable {
    public var route: ActivationRoute
    /// Nil for the routes with no pointer: the shortcut and the scripting interfaces.
    public var gesture: Gesture?
    /// The structure the mouse-down probe found (architecture §4.3).
    public var focus: AXFocus
    /// Where the selection was at mouse-down. Nil when the app would not say, and for the routes that
    /// have no mouse-down to read it at.
    public var baseline: AXTextRange?
    public var read: SelectionRead

    public init(
        route: ActivationRoute,
        gesture: Gesture? = nil,
        focus: AXFocus = AXFocus(),
        baseline: AXTextRange? = nil,
        read: SelectionRead
    ) {
        self.route = route
        self.gesture = gesture
        self.focus = focus
        self.baseline = baseline
        self.read = read
    }

    /// ACT-3 asks for an editable place, not merely a textual one: a bar with no selection exists so that
    /// Paste is reachable, and there is nothing to paste into a paragraph one can only read.
    var isEditablePlace: Bool {
        (focus.underPointer?.isEditableText ?? false) || (focus.focused?.isEditableText ?? false)
    }

    var isTextualPlace: Bool {
        (focus.underPointer?.isTextual ?? false) || (focus.focused?.isTextual ?? false)
    }
}

/// ACT-14: the several signals, weighed in one place.
///
/// Cursor shape is not among them. It is the signal ACT-14 names as the one that must never decide alone,
/// and it turns out not to be needed at all: the gesture says what the pointer did, the roles say where it
/// did it, and the baseline says whether anything changed. If it is ever added it can only break a tie.
public enum ActivationRules {
    public static func verdict(for signals: ActivationSignals) -> AppearanceVerdict {
        switch signals.read.outcome {
        case .outOfBudget:
            return .outOfBudget

        case .refused:
            return .unreadable

        case .text:
            guard let text = signals.read.text, !text.isEmpty else { return .noText }
            // The one signal that can take a bar away: a selection sitting exactly where it was before
            // the gesture is the user's old selection, not a new one. A deliberate route is exempt —
            // the user has just asked for actions on whatever is selected, old or new.
            if !signals.route.isDeliberate,
               let baseline = signals.baseline,
               !baseline.isEmpty,
               signals.read.range == baseline {
                return .unchangedRange
            }
            return .selection

        case .caretOnly:
            guard signals.isEditablePlace else { return .nothingTextual }
            switch signals.gesture {
            // No gesture at all is the shortcut or a script: the user asked, so Paste is reachable.
            case .none, .longPress, .multiClick, .shiftClick:
                return .caret
            // A drag that ends on a caret selected nothing, however editable the place is.
            case .dragSelect, .suppressed:
                return .noText
            }

        case .nothing:
            return signals.isTextualPlace ? .noText : .nothingTextual
        }
    }
}
