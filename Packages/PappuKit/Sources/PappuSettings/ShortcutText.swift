import Foundation
import PappuSelection

/// What a stored shortcut is called on screen (ACT-5, PRD §7.5).
///
/// A shortcut is stored as a virtual key code, because that is what `RegisterEventHotKey` takes and
/// what the key that was pressed *is* — a position on the keyboard, not a character. Turning it back
/// into something a user recognises therefore needs a table, and this is it.
///
/// **The table is the US layout, and that is a known limit rather than an oversight.** The honest
/// answer asks the current keyboard layout through `UCKeyTranslate`, so that key code 6 reads as "W" on
/// AZERTY and "Z" here; that is a system seam, it belongs with the other Carbon call in
/// `SystemHotkeyRegistrar`, and it is worth doing when the shortcut recorder is more than one field.
/// Until then the words the *user* chose are unaffected: the recorder shows what it heard as it hears
/// it, and this is only what the field says after a relaunch. The keys nobody can misread — the
/// modifiers, the function keys, Return, Space, the arrows — are right on every layout.
public enum ShortcutText {
    /// The glyphs in the order every Mac menu draws them: ⌃⌥⇧⌘ (HIG, Keyboard Shortcuts).
    public static func describe(_ shortcut: HotkeyShortcut) -> String {
        modifiers(shortcut.modifiers) + key(shortcut.keyCode)
    }

    public static func modifiers(_ modifiers: PointerEvent.Modifiers) -> String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "\u{2303}" }
        if modifiers.contains(.option) { glyphs += "\u{2325}" }
        if modifiers.contains(.shift) { glyphs += "\u{21E7}" }
        if modifiers.contains(.command) { glyphs += "\u{2318}" }
        return glyphs
    }

    /// The key itself, named the way a menu names it.
    ///
    /// A code in no table below is written as its number. It is not a good thing to show a user, but it
    /// is better than an empty field: a shortcut that works and has no name can at least be recognised
    /// as *something*, and cleared.
    public static func key(_ keyCode: UInt16) -> String {
        if let index = HotkeyShortcut.functionKeys.firstIndex(of: keyCode) {
            return "F\(index + 1)"
        }
        if let glyph = glyphs[keyCode] { return glyph }
        if keyCode == spaceKeyCode { return SettingsStrings.shortcutSpace }
        if let character = characters[keyCode] { return String(character).uppercased() }
        return "#\(keyCode)"
    }

    private static let spaceKeyCode: UInt16 = 49

    /// The keys that are drawn rather than spelled, and are the same on every layout.
    private static let glyphs: [UInt16: String] = [
        36: "\u{21A9}",  // Return
        48: "\u{21E5}",  // Tab
        51: "\u{232B}",  // Delete
        53: "\u{238B}",  // Escape
        71: "\u{2327}",  // Clear
        76: "\u{2305}",  // Enter, on the keypad
        115: "\u{2196}", // Home
        116: "\u{21DE}", // Page Up
        117: "\u{2326}", // Forward Delete
        119: "\u{2198}", // End
        121: "\u{21DF}", // Page Down
        123: "\u{2190}", // Left
        124: "\u{2192}", // Right
        125: "\u{2193}", // Down
        126: "\u{2191}", // Up
    ]

    /// The letters, digits and punctuation of the US layout, by virtual key code. Not a run of numbers
    /// in any order anyone would guess, which is why it is written out in code order.
    private static let characters: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n",
        46: "m", 47: ".", 50: "`",
    ]
}
