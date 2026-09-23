import Foundation

/// Every word the Settings window says (PRD §7.12).
///
/// Same arrangement as `AppStrings` and `BarStrings`: the keys are listed in `all` as well as used, and
/// a test walks that list against the catalogue, so a string added here without an entry beside it fails
/// the build rather than shipping as its own key.
public enum SettingsStrings {
    public static var windowTitle: String { localized("settings.window.title", "PappuClip Settings") }
    public static var general: String { localized("settings.tab.general", "General") }
    public static var actions: String { localized("settings.tab.actions", "Actions") }

    // MARK: General

    public static var appearAutomatically: String {
        localized("settings.general.appearAutomatically", "Appear automatically")
    }

    /// ACT-19's promise, said in one sentence: the shortcut is not a tap and keeps working when the
    /// automatic path is off.
    public static var appearAutomaticallyHelp: String {
        localized(
            "settings.general.appearAutomatically.help",
            "Show the bar when you select text. The keyboard shortcut keeps working either way."
        )
    }

    public static var shortcut: String { localized("settings.general.shortcut", "Keyboard shortcut") }
    public static var shortcutNone: String { localized("settings.general.shortcut.none", "None") }
    public static var shortcutRecord: String { localized("settings.general.shortcut.record", "Record") }
    public static var shortcutRecording: String { localized("settings.general.shortcut.recording", "Press keys…") }
    public static var shortcutClear: String { localized("settings.general.shortcut.clear", "Clear") }

    /// The space bar, which has no glyph anybody reads.
    public static var shortcutSpace: String { localized("settings.general.shortcut.space", "Space") }

    /// ACT-5, in the words a user can act on: the rule is "something you would not press while writing".
    public static var shortcutRefused: String {
        localized(
            "settings.general.shortcut.refused",
            "That shortcut needs Control, Option or Command — or a function key on its own."
        )
    }

    public static var position: String { localized("settings.general.position", "Position") }
    public static var positionAbove: String { localized("settings.general.position.above", "Above the text") }
    public static var positionBelow: String { localized("settings.general.position.below", "Below the text") }
    public static var rules: String { localized("settings.general.rules", "Rules") }
    public static var rulesApps: String { localized("settings.general.rules.apps", "Apps…") }

    // MARK: The Accessibility banner (ONB-1, ONB-4)

    public static var accessibilityMissing: String {
        localized(
            "settings.accessibility.missing",
            "PappuClip needs Accessibility permission to read the text you select."
        )
    }

    public static var accessibilityStale: String {
        localized(
            "settings.accessibility.stale",
            "PappuClip is listed under Accessibility, but the permission is no longer working. Remove it from the list and add it again."
        )
    }

    public static var accessibilityOpen: String {
        localized("settings.accessibility.open", "Open System Settings…")
    }

    // MARK: Apps (ACT-17a, ALM-8)

    public static var appsTitle: String { localized("settings.apps.title", "Apps") }

    public static var appsExplanation: String {
        localized(
            "settings.apps.explanation",
            "The bar stays away from these apps. “Never read text here” is stronger: nothing is read there, by any route."
        )
    }

    public static var appsExclude: String { localized("settings.apps.exclude", "Don’t appear automatically") }
    public static var appsBlock: String { localized("settings.apps.block", "Never read text here") }
    public static var appsAdd: String { localized("settings.apps.add", "Add App…") }
    public static var appsRemove: String { localized("settings.apps.remove", "Remove") }
    public static var appsEmpty: String { localized("settings.apps.empty", "No app has a rule of its own.") }

    // MARK: Actions (§7.6)

    public static var actionsExplanation: String {
        localized(
            "settings.actions.explanation",
            "The built-in actions. Renaming, reordering and adding actions arrive in a later version."
        )
    }

    public static var actionsBuiltIn: String { localized("settings.actions.builtIn", "Built-in") }
    public static var actionsOff: String { localized("settings.actions.off", "Off") }
    public static var done: String { localized("settings.done", "Done") }

    /// The module's own bundle, so the test that walks `all` can look every key up from outside.
    public static var bundle: Bundle { .module }

    /// Every key above, in the order they are declared.
    public static let all: [String] = [
        "settings.window.title",
        "settings.tab.general",
        "settings.tab.actions",
        "settings.general.appearAutomatically",
        "settings.general.appearAutomatically.help",
        "settings.general.shortcut",
        "settings.general.shortcut.none",
        "settings.general.shortcut.record",
        "settings.general.shortcut.recording",
        "settings.general.shortcut.clear",
        "settings.general.shortcut.space",
        "settings.general.shortcut.refused",
        "settings.general.position",
        "settings.general.position.above",
        "settings.general.position.below",
        "settings.general.rules",
        "settings.general.rules.apps",
        "settings.accessibility.missing",
        "settings.accessibility.stale",
        "settings.accessibility.open",
        "settings.apps.title",
        "settings.apps.explanation",
        "settings.apps.exclude",
        "settings.apps.block",
        "settings.apps.add",
        "settings.apps.remove",
        "settings.apps.empty",
        "settings.actions.explanation",
        "settings.actions.builtIn",
        "settings.actions.off",
        "settings.done",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
