import Foundation
import PappuSelection
import PappuSettings
import Testing

/// What a stored shortcut is called on screen (ACT-5, PRD §7.5).
///
/// A shortcut is stored as a virtual key code, so the field showing it after a relaunch is a table
/// lookup, and a table is a thing to get wrong. The parts worth pinning are the ones a user would
/// notice: the modifier order every Mac menu uses, the function keys, and the fact that a key with no
/// entry still shows as something rather than as an empty field.
@Suite struct ShortcutTextTests {
    @Test func theModifiersAreInTheOrderEveryMenuDrawsThem() {
        #expect(ShortcutText.modifiers([.command, .control, .shift, .option]) == "⌃⌥⇧⌘")
        #expect(ShortcutText.modifiers([]).isEmpty)
    }

    @Test func aShortcutIsNamedTheWayAMenuNamesIt() {
        #expect(ShortcutText.describe(HotkeyShortcut(keyCode: 8, modifiers: [.command, .shift])) == "⇧⌘C")
        #expect(ShortcutText.describe(HotkeyShortcut(keyCode: 49, modifiers: [.option])) == "⌥Space")
        #expect(ShortcutText.describe(HotkeyShortcut(keyCode: 36, modifiers: [.command])) == "⌘↩")
    }

    /// One table decides both whether a function key may be used on its own (ACT-5) and what it is
    /// called, so F7 cannot be allowed under one name and drawn under another.
    @Test func everyFunctionKeyIsNamedFromTheTableThatAllowsIt() {
        for (offset, keyCode) in HotkeyShortcut.functionKeys.enumerated() {
            #expect(ShortcutText.key(keyCode) == "F\(offset + 1)")
            #expect(HotkeyShortcut(keyCode: keyCode).isUsableAsGlobalShortcut)
        }
        #expect(HotkeyShortcut.functionKeys.count == 20)
    }

    /// The keys that are drawn rather than spelled, and are the same on every keyboard layout.
    @Test func theKeysWithGlyphsGetThem() {
        #expect(ShortcutText.key(53) == "⎋")
        #expect(ShortcutText.key(51) == "⌫")
        #expect(ShortcutText.key(48) == "⇥")
        #expect(ShortcutText.key(126) == "↑")
        #expect(ShortcutText.key(125) == "↓")
        #expect(ShortcutText.key(123) == "←")
        #expect(ShortcutText.key(124) == "→")
    }

    @Test func aLetterIsUpperCasedAndADigitIsItself() {
        #expect(ShortcutText.key(0) == "A")
        #expect(ShortcutText.key(6) == "Z")
        #expect(ShortcutText.key(18) == "1")
        #expect(ShortcutText.key(29) == "0")
        #expect(ShortcutText.key(44) == "/")
    }

    /// A key code in no table is written as its number. It is not a good thing to show a user, but a
    /// shortcut that works and has an empty field cannot be recognised — or cleared.
    @Test func aKeyWithNoNameIsStillSomething() {
        #expect(ShortcutText.key(200) == "#200")
        #expect(!ShortcutText.describe(HotkeyShortcut(keyCode: 200, modifiers: [.command])).isEmpty)
    }

    /// Two key codes are not in the table because they are not one key: 10 and 52 differ by keyboard,
    /// and nothing should claim to know what they say.
    @Test func noTwoKeyCodesShareAName() {
        let named = (0...127).map { ShortcutText.key(UInt16($0)) }.filter { !$0.hasPrefix("#") }
        #expect(Set(named).count == named.count)
    }
}

@Suite struct SettingsStringsTests {
    @Test func everyStringTheSettingsWindowSaysIsInTheCatalogue() {
        let bundle = SettingsStrings.bundle
        for key in SettingsStrings.all {
            let missing = "\u{1}missing\u{1}"
            #expect(
                bundle.localizedString(forKey: key, value: missing, table: nil) != missing,
                "\(key) has no entry in Localizable.strings"
            )
        }
    }

    @Test func nothingTheSettingsWindowSaysIsWrittenInPlace() {
        #expect(SettingsStrings.windowTitle == "PappuClip Settings")
        #expect(SettingsStrings.appearAutomatically == "Appear automatically")
        #expect(!SettingsStrings.shortcutRefused.isEmpty)
        #expect(!SettingsStrings.accessibilityStale.isEmpty)
    }
}
