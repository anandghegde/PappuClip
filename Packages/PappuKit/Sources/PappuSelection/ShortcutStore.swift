import Foundation
import PappuCore

/// The user's global shortcut, as it is remembered between launches (ACT-5, PRD §7.5 General).
///
/// There is no default. A shortcut nobody chose would be a shortcut nobody expects, and ACT-5 calls it
/// user-defined; until the recorder in Settings is used, the automatic path and the menu are the only
/// ways in. `HotkeyService` is what registers it and what says whether the system would take it; this
/// only remembers, and refuses to remember something ACT-5 forbids so that a bad value cannot be
/// written and then read back at the next launch as though it were fine.
public final class ShortcutStore: Sendable {
    public static let storageKey = "activation.shortcut"

    private let stored: SettingsValue<HotkeyShortcut?>

    public init(storage: any SettingsStorage) {
        stored = SettingsValue(key: Self.storageKey, default: nil, storage: storage)
    }

    public var shortcut: HotkeyShortcut? { stored.value }

    /// - Returns: False when the shortcut is one ACT-5 does not allow, in which case nothing is stored.
    ///   Clearing the shortcut — `nil` — is always allowed.
    @discardableResult
    public func set(_ shortcut: HotkeyShortcut?) -> Bool {
        if let shortcut, !shortcut.isUsableAsGlobalShortcut { return false }
        stored.set(shortcut)
        return true
    }

    /// Registration follows the setting rather than the other way round: the app registers what this
    /// says at launch and re-registers here, so the recorder does not have to know about the registrar.
    public func onChange(_ body: @escaping @Sendable (HotkeyShortcut?) -> Void) {
        stored.onChange(body)
    }
}
