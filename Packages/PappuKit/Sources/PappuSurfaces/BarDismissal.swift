import CoreGraphics
import PappuSelection

/// Why a bar went away. Every one of them is an event; none of them is a clock (BAR-10).
public enum BarDismissalReason: String, Sendable, Codable, CaseIterable {
    /// A mouse-down anywhere but on the bar, seen by the mouse tap.
    case outsideClick
    /// A scroll, seen by the mouse tap. The bar scrolls nothing of its own, so any scroll is the user
    /// looking somewhere else.
    case scroll
    /// An ordinary key, which the bar does not take and which goes on to the app.
    case ordinaryKey
    case escape
    /// A button was pressed and its action is running or has run.
    case actionRun
    /// The attempt this bar belongs to stopped being the current one (ACT-16a).
    case attemptRetired
    /// Pause, a hard block or secure input arrived while the bar was up (ACT-12, ACT-17a, ACT-18).
    case privacyState
}

/// BAR-10's pointer half: which mouse events take the bar away.
///
/// There is no timer here and there is nowhere to put one — the decision is a function of an event and
/// a rectangle, and takes no clock at all. That is the requirement stated as a signature.
public enum BarDismissal {
    public static func reason(for event: PointerEvent, barFrame: CGRect) -> BarDismissalReason? {
        switch event.kind {
        case .scroll:
            return .scroll
        case .down:
            // A press on the bar itself is a button press, and the panel handles it. The tap sees it
            // first, which is why the test exists.
            return barFrame.contains(event.location) ? nil : .outsideClick
        case .dragged, .up:
            return nil
        }
    }
}
