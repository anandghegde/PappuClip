import Foundation

/// One key press a Key Press action asks for, parsed (§8.4).
///
/// PopClip's format is `<modifiers> <key>` — `command b`, `option shift .`, `option numpad /`, `f1`,
/// `0x74` — and the older plists spell the same thing as a dictionary of a key code or a character and
/// a modifier mask. Both become this, and nothing after this knows which one the author wrote.
///
/// **A character stays a character.** `command a` is "the key that types *a*", and which key that is
/// depends on the keyboard layout: on AZERTY it is the key an ANSI table calls Q. The parser therefore
/// keeps the character and leaves the question of the key to whoever posts the event and can ask the
/// current layout (`SystemKeyPresser`). `ansiKeyCode` is the answer for a US layout, which is what the
/// load-time check and the tests use, and what the poster falls back on when the layout has no key
/// for the character at all.
public struct KeyCombo: Sendable, Equatable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        /// PopClip's `numpad`: the key on the numeric keypad rather than the main block. It is a
        /// modifier in the format and a choice of key in the event, so it is resolved here and also
        /// kept, because a keypad event carries the keypad flag.
        public static let numericPad = Modifiers(rawValue: 1 << 4)

        /// The legacy mask: `NSEvent.ModifierFlags` raw values, which are also §8.7's
        /// `POPCLIP_MODIFIER_FLAGS` values.
        public init(legacyMask mask: Int) {
            var modifiers: Modifiers = []
            if mask & 131_072 != 0 { modifiers.insert(.shift) }
            if mask & 262_144 != 0 { modifiers.insert(.control) }
            if mask & 524_288 != 0 { modifiers.insert(.option) }
            if mask & 1_048_576 != 0 { modifiers.insert(.command) }
            if mask & 2_097_152 != 0 { modifiers.insert(.numericPad) }
            self = modifiers
        }
    }

    public enum Key: Sendable, Equatable, Hashable {
        /// A virtual key code (Carbon's `kVK_*`), from a name, a hex code or a keypad character.
        case code(UInt16)
        /// A printed character, lowercased. Which key types it is the layout's business.
        case character(Character)
    }

    public var modifiers: Modifiers
    public var key: Key

    public init(modifiers: Modifiers = [], key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Why a combo string could not be read. Codes, for the load diagnostic to put into words.
    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        /// The last word is not a character, a key name or a hex code.
        case unknownKey(String)
        /// A word before the key that is not a modifier.
        case unknownModifier(String)
        /// `numpad` with a key the keypad does not have.
        case notOnKeypad(String)
        /// A hex code past the last virtual key code.
        case codeOutOfRange(String)

        public var description: String {
            switch self {
            case .empty: "the key combo is empty"
            case .unknownKey(let word): "\"\(word)\" is not a key: use one character, a key name such as return or f5, or a hex code such as 0x74"
            case .unknownModifier(let word): "\"\(word)\" is not a modifier: use command, option, control, shift or numpad"
            case .notOnKeypad(let word): "\"\(word)\" is not a key on the numeric keypad"
            case .codeOutOfRange(let word): "\(word) is past the last key code, 0x7F"
            }
        }
    }

    /// Reads PopClip's `<modifiers> <key>`.
    ///
    /// Words are separated by spaces and read without case. The last word is the key, except that a
    /// combo ending in a space character — `command  ` — cannot be written that way, which is why
    /// PopClip has the name `space`. A repeated modifier is harmless and accepted.
    public static func parse(_ text: String) throws(Problem) -> KeyCombo {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let last = words.last else { throw .empty }

        var modifiers: Modifiers = []
        for word in words.dropLast() {
            guard let modifier = modifierNames[word.lowercased()] else { throw .unknownModifier(word) }
            modifiers.insert(modifier)
        }
        let key = try self.key(last, numericPad: modifiers.contains(.numericPad))
        return KeyCombo(modifiers: modifiers, key: key)
    }

    /// The legacy dictionary. A key code wins over a character when a plist gives both, as PopClip's
    /// did: the code is the more specific of the two.
    public static func legacy(keyCode: Int?, keyCharacter: String?, modifiers mask: Int) throws(Problem) -> KeyCombo {
        let modifiers = Modifiers(legacyMask: mask)
        if let keyCode {
            guard (0...0x7F).contains(keyCode) else { throw .codeOutOfRange(String(keyCode)) }
            return KeyCombo(modifiers: modifiers, key: .code(UInt16(keyCode)))
        }
        guard let keyCharacter, keyCharacter.count == 1, let character = keyCharacter.lowercased().first else {
            throw .unknownKey(keyCharacter ?? "")
        }
        return KeyCombo(modifiers: modifiers, key: .character(character))
    }

    /// The step as the parser read it, parsed. Waits have no combo and answer nil.
    public static func parse(_ step: KeyPressAction.Step) throws(Problem) -> KeyCombo? {
        switch step {
        case .combo(let text): try parse(text)
        case .legacyCombo(let keyCode, let keyCharacter, let modifiers):
            try legacy(keyCode: keyCode, keyCharacter: keyCharacter, modifiers: modifiers)
        case .wait: nil
        }
    }

    private static func key(_ word: String, numericPad: Bool) throws(Problem) -> Key {
        let lowered = word.lowercased()
        if numericPad {
            // `numpad enter` is the keypad's own Enter, which is not Return.
            if lowered == "enter" { return .code(0x4C) }
            guard lowered.count == 1, let code = keypad[lowered.first!] else { throw .notOnKeypad(word) }
            return .code(code)
        }
        if let code = keyNames[lowered] { return .code(code) }
        if lowered.hasPrefix("0x"), lowered.count > 2 {
            guard let code = UInt16(lowered.dropFirst(2), radix: 16) else { throw .unknownKey(word) }
            guard code <= 0x7F else { throw .codeOutOfRange(word) }
            return .code(code)
        }
        guard lowered.count == 1, let character = lowered.first else { throw .unknownKey(word) }
        return .character(character)
    }

    private static let modifierNames: [String: Modifiers] = [
        "command": .command, "cmd": .command,
        "option": .option, "opt": .option,
        "control": .control, "ctrl": .control,
        "shift": .shift,
        "numpad": .numericPad,
    ]

    /// PopClip's names, and no others: an extension that works here and not in PopClip would be a
    /// compatibility bug in the other direction. Everything else has a hex code.
    private static let keyNames: [String: UInt16] = {
        var names: [String: UInt16] = [
            "return": 0x24, "space": 0x31, "delete": 0x33, "escape": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        let functionKeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functionKeys.enumerated() { names["f\(index + 1)"] = code }
        return names
    }()

    private static let keypad: [Character: UInt16] = [
        "0": 0x52, "1": 0x53, "2": 0x54, "3": 0x55, "4": 0x56,
        "5": 0x57, "6": 0x58, "7": 0x59, "8": 0x5B, "9": 0x5C,
        ".": 0x41, "*": 0x43, "+": 0x45, "/": 0x4B, "-": 0x4E, "=": 0x51,
    ]

    // MARK: Display

    /// The combo as a Mac menu writes it — `⌃⌥⇧⌘A`, `⌘↩`, `F5` — for the consent sheet's "Presses ⌘A
    /// in the current app" (safety spec §S4). A key with no name of its own is shown by its code.
    public var symbols: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case .character(let character):
            result += character.uppercased()
        case .code(let code):
            if let symbol = Self.keySymbols[code] {
                result += symbol
            } else if let name = Self.keyNames.first(where: { $0.value == code })?.key {
                result += name.uppercased()
            } else if let digit = Self.keypad.first(where: { $0.value == code })?.key {
                result += String(digit)
            } else {
                result += String(format: "0x%02X", code)
            }
        }
        return result
    }

    private static let keySymbols: [UInt16: String] = [
        0x24: "↩", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x4C: "⌤",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]

    // MARK: The US layout

    /// The key that types `character` on a US (ANSI) layout, and whether it needs Shift to.
    ///
    /// The fallback for a layout that has no key for the character, and the whole answer wherever
    /// there is no layout to ask — the tests and the load-time check. Nil for a character no key on
    /// that layout types, which a combo can still name: the poster asks the real layout first.
    public static func ansiKeyCode(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let code = ansi[character] { return (code, false) }
        if let base = ansiShifted[character], let code = ansi[base] { return (code, true) }
        return nil
    }

    private static let ansi: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31,
    ]

    /// The shifted symbols, as the unshifted key they sit on.
    private static let ansiShifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]
}
