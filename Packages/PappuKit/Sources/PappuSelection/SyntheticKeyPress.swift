import Carbon.HIToolbox
import CoreGraphics
import PappuCore

/// Where a Key Press action's events go (§8.4 `keyComboTarget`), with the process the app target
/// names. `session` is PopClip's default and ours.
public struct KeyPressDelivery: Sendable, Equatable {
    public var target: KeyPressAction.Target
    /// The destination's process, for `app`. The other two targets ignore it.
    public var processID: pid_t

    public init(target: KeyPressAction.Target, processID: pid_t) {
        self.target = target
        self.processID = processID
    }
}

/// Posts one key combo from a Key Press action (§8.4).
///
/// The same seam of one call as `SyntheticPastePosting`, for the same reason. A sequence and its
/// waits are the runner's business: it checks between combos that the invocation is still wanted, so
/// a cancelled sequence stops where it is rather than typing the rest into whatever is in front.
public protocol SyntheticKeyPressPosting: Sendable {
    /// - Returns: False when the events could not be made or the key could not be found; nothing was
    ///   posted.
    func post(_ combo: KeyCombo, to delivery: KeyPressDelivery) -> Bool
}

/// The system's key press (§8.4).
///
/// What `SystemSyntheticPaste` does — the launch's tag, flags *set* so a held modifier does not leak
/// into the combo — with the target the extension chose: `session` and `hid` are the two taps, and
/// `app` posts to the destination's process alone, which reaches it even when it is not frontmost
/// and reaches nothing else.
///
/// **A character is looked up in the current layout.** `command z` on a German keyboard is the key
/// that types *z*, which is the key an ANSI table calls Y. The layout is asked for the key that types
/// the character bare or with Shift; a character it does not have falls back to the US table, which
/// is what PopClip does too, and one neither has is not posted.
public struct SystemSyntheticKeyPress: SyntheticKeyPressPosting {
    private let tag: SyntheticEventTag

    public init(tag: SyntheticEventTag) {
        self.tag = tag
    }

    public func post(_ combo: KeyCombo, to delivery: KeyPressDelivery) -> Bool {
        guard let (code, shift) = Self.keyCode(for: combo.key) else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else { return false }
        var flags = Self.flags(combo.modifiers)
        if shift { flags.insert(.maskShift) }
        for event in [down, up] {
            event.flags = flags
            tag.mark(event)
            switch delivery.target {
            case .session: event.post(tap: .cgSessionEventTap)
            case .hid: event.post(tap: .cghidEventTap)
            case .app: event.postToPid(delivery.processID)
            }
        }
        return true
    }

    static func flags(_ modifiers: KeyCombo.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.numericPad) { flags.insert(.maskNumericPad) }
        return flags
    }

    private static func keyCode(for key: KeyCombo.Key) -> (CGKeyCode, Bool)? {
        switch key {
        case .code(let code): return (code, false)
        case .character(let character):
            if let found = onMainThread({ layoutKeyCode(for: character) }) { return found }
            return KeyCombo.ansiKeyCode(for: character).map { ($0.code, $0.shift) }
        }
    }

    /// The key in the current keyboard layout that types `character`, bare first and then with Shift.
    /// On the main thread because the Text Input Sources calls expect it.
    @MainActor
    private static func layoutKeyCode(for character: Character) -> (CGKeyCode, Bool)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let wanted = String(character)
        return data.withUnsafeBytes { bytes -> (CGKeyCode, Bool)? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for shift in [false, true] {
                let state = UInt32(shift ? (shiftKey >> 8) & 0xFF : 0)
                for code in 0..<CGKeyCode(0x7F) {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
                    )
                    guard status == noErr, length > 0 else { continue }
                    if String(utf16CodeUnits: characters, count: length).lowercased() == wanted { return (code, shift) }
                }
            }
            return nil
        }
    }
}
