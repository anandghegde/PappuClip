import Foundation

/// The user's global shortcut (ACT-5), as it is stored and registered.
///
/// It is not a tap. `RegisterEventHotKey` needs no permission and sits outside the event stream
/// (architecture §4.1), so the shortcut is the one activation route still standing when the
/// Accessibility grant is missing or has been taken away — the route that can say why nothing else
/// works (ONB-4). It is also why no key tap is needed to hear it (ACT-19).
public struct HotkeyShortcut: Sendable, Hashable, Codable {
    /// A virtual key code, not a character, numbered as `KeyPress.keyCode` is.
    public var keyCode: UInt16
    public var modifiers: PointerEvent.Modifiers

    public init(keyCode: UInt16, modifiers: PointerEvent.Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ACT-5: a shortcut has to be something nobody presses while writing. ⌃, ⌥ or ⌘ must be held —
    /// ⇧ does not count, since ⇧ and a letter is typing — and a function key on its own is the
    /// exception, because it types nothing. A function key with ⇧ alone is neither, and is refused.
    public var isUsableAsGlobalShortcut: Bool {
        if !modifiers.isDisjoint(with: [.control, .option, .command]) { return true }
        return modifiers.isEmpty && Self.functionKeyCodes.contains(keyCode)
    }

    /// F1–F20 by virtual key code, in that order. They are not one run of numbers and there is no
    /// header constant that lists them, so they are written out — once, here, because the settings
    /// window names the key the user pressed from the same table that decides whether it is allowed.
    public static let functionKeys: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13–F20
    ]

    public static let functionKeyCodes: Set<UInt16> = Set(functionKeys)
}
