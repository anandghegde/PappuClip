import AppKit

extension PointerEvent.Modifiers {
    /// The modifiers of an `NSEvent`, which the tap's own `CGEventFlags` initialiser cannot be handed.
    ///
    /// Two surfaces need this and neither of them is the tap: the bar reads the flags held at a click
    /// (BAR-11, so that ⌘-clicking a button reaches the action with ⌘ held), and the settings window
    /// reads them while recording a shortcut (ACT-5). It lives here, beside the `CGEventFlags` one and
    /// with the type it builds, so that there is one table of four bits in the app rather than one per
    /// surface that happens to need it.
    public init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
    }
}
