import Foundation
import PappuCore

/// What the user can change about the bar, as far as M1 lets them (PRD §7.5, General → Appearance).
///
/// One setting, and the reason is BAR-8a against BAR-8b. The colour mode that *follows the system* and
/// the vibrancy are P0 and are not choices — `BarAppearance.resolve` reads the system and the three
/// accessibility settings and needs nothing from the user. The Light/Dark/Auto choice and the size
/// slider are BAR-8b, P1, and land in M4 with the rest of the appearance controls. Position is P0
/// because BAR-3 names it: it is the one thing about a single-line bar the user decides.
///
/// `BarSettings` is assembled here rather than stored whole, because `BarMetrics` is a table of
/// measurements this build does not let anyone change, and storing it would invite a saved copy of the
/// old numbers to outlive a change to them.
public final class BarPreferences: Sendable {
    public static let positionKey = "bar.position"

    private let stored: SettingsValue<BarPosition>

    public init(storage: any SettingsStorage) {
        stored = SettingsValue(key: Self.positionKey, default: .aboveText, storage: storage)
    }

    public var position: BarPosition { stored.value }

    public func setPosition(_ position: BarPosition) {
        stored.set(position)
    }

    /// What `BarController.settings` is given, at launch and again whenever the user changes it.
    public var settings: BarSettings {
        BarSettings(position: position, colorPreference: .system, metrics: .standard)
    }

    public func onChange(_ body: @escaping @Sendable (BarSettings) -> Void) {
        stored.onChange { [weak self] _ in
            guard let self else { return }
            body(settings)
        }
    }
}
