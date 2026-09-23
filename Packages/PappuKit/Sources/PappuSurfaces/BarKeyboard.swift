import PappuCore
import PappuSelection

/// The keys compact keyboard mode knows about (BAR-9a), as virtual key codes mean nothing on their own.
///
/// A key held with ⌘, ⌃, ⌥ or ⇧ is `.other` whatever it is. That is the rule that keeps ⇧← extending the
/// user's selection and ⌘C copying in the app underneath: the bar owns the bare navigation keys and
/// nothing else, and everything else goes where it was going (BAR-10, ACT-19).
public enum BarKey: Sendable, Equatable {
    case left
    case right
    case up
    case down
    case enter
    case escape
    case other

    public init(_ press: KeyPress) {
        guard press.modifiers.isEmpty else {
            self = .other
            return
        }
        switch press.keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        case 36, 76: self = .enter
        case 53: self = .escape
        default: self = .other
        }
    }
}

/// What a key press did, and what became of the key itself.
public enum BarKeyOutcome: Sendable, Equatable {
    /// The highlight moved. The key is consumed (BAR-9a).
    case moved(to: Int)
    /// Return on a highlighted button. Consumed.
    case run(index: Int)
    /// Esc. Consumed: the bar is what it closed, so the app underneath never hears it.
    case dismissed
    /// An ordinary key. The bar goes and the key goes on to the app (BAR-10).
    case dismissedAndPassedOn
    /// Nothing to do, and nothing taken: a navigation key on an empty bar, or an auto-repeat that has
    /// already run its button.
    case ignored

    /// What the key tap's handler returns for this outcome (ACT-19). Only a bar's own keys are taken.
    public var disposition: TapDisposition {
        switch self {
        case .moved, .run, .dismissed: .consume
        case .dismissedAndPassedOn, .ignored: .pass
        }
    }

    public var dismisses: Bool {
        switch self {
        case .dismissed, .dismissedAndPassedOn, .run: true
        case .moved, .ignored: false
        }
    }
}

/// BAR-9a's compact keyboard mode, as a value.
///
/// It is a value and not a controller because the decision has to be made on the event tap's thread,
/// which must answer at once and cannot wait for the main actor: `BarController` keeps one of these
/// behind a mutex, the handler advances it and returns, and the highlight catches up on the main actor
/// afterwards.
///
/// Two choices worth naming. The highlight **clamps** at either end rather than wrapping, so that
/// holding ← never cycles back round past the button the user was aiming for. And the bar is not in
/// keyboard mode until a navigation key arrives on the automatic path — a bar that grabbed ← the moment
/// it appeared would take the key that deselects text away from every app on the Mac. The shortcut is
/// the exception: ACT-6a says it opens keyboard mode, because the user asked for the bar by keyboard
/// and their hands are already there.
public struct BarKeyboardMode: Sendable, Equatable {
    public private(set) var itemCount: Int
    /// Nil until a navigation key arrives, or from the start on the shortcut route (ACT-6a).
    public private(set) var highlighted: Int?

    public var isActive: Bool { highlighted != nil }

    public init(itemCount: Int, route: ActivationRoute = .automatic) {
        self.itemCount = max(0, itemCount)
        // ACT-6a: the shortcut and the scripted routes are the user asking by keyboard.
        self.highlighted = route.isDeliberate && self.itemCount > 0 ? 0 : nil
    }

    public mutating func press(_ key: BarKey) -> BarKeyOutcome {
        guard itemCount > 0 else {
            return key == .escape ? .dismissed : .dismissedAndPassedOn
        }
        switch key {
        case .left:
            return move(to: highlighted.map { $0 - 1 } ?? itemCount - 1)
        case .right:
            return move(to: highlighted.map { $0 + 1 } ?? 0)
        case .enter:
            // Return with nothing highlighted is the app's Return, not ours.
            guard let highlighted else { return .dismissedAndPassedOn }
            return .run(index: highlighted)
        case .escape:
            return .dismissed
        // ↑ and ↓ enter and leave folders in BAR-9b, which is M4. Until there are folders they are
        // ordinary keys, and an ordinary key dismisses and passes through.
        case .up, .down, .other:
            return .dismissedAndPassedOn
        }
    }

    private mutating func move(to index: Int) -> BarKeyOutcome {
        let clamped = min(max(index, 0), itemCount - 1)
        highlighted = clamped
        return .moved(to: clamped)
    }
}
