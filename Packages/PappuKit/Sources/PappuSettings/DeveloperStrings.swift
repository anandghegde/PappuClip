import Foundation

/// Every word Settings → Developer, the development review and the development-mode status say (DEV-1).
///
/// In a table of their own, `Developer.strings`, beside `Localizable.strings`: the same contract as
/// `ExtensionStrings` — each key is in `all`, and a test walks `all` against the table.
public enum DeveloperStrings {
    public static let table = "Developer"

    public static var tab: String { localized("developer.tab", "Developer") }

    /// The banner, drawn for as long as any development folder is approved.
    public static var modeOn: String { localized("developer.mode.on", "Development mode is on") }

    public static var modeOnHelp: String {
        localized(
            "developer.mode.on.help",
            "Extensions from the folders below run unsigned code from this Mac. They get the same checks as any other extension, and each needs your approval again whenever it asks for more."
        )
    }

    /// The menu bar menu's status line while development mode is on.
    public static var menuStatus: String { localized("developer.menu.status", "Development Mode On") }

    public static var intro: String {
        localized(
            "developer.intro",
            "Load an extension from a folder you are working on. It is reviewed like any install, and reloaded only when you press Reload."
        )
    }

    public static var foldersHeading: String { localized("developer.folders", "Development Folders") }
    public static var noFolders: String { localized("developer.folders.none", "No development folders.") }
    public static var addFolder: String { localized("developer.folders.add", "Add Folder\u{2026}") }
    public static var addFolderHelp: String {
        localized("developer.folders.add.help", "Choose an extension package folder to review and load.")
    }

    public static var reload: String { localized("developer.folders.reload", "Reload") }

    public static func reloadLabel(_ name: String) -> String {
        String(localized: "developer.folders.reload.label", defaultValue: "Reload \(name)", table: table, bundle: .module,
               comment: "Accessibility label. %@ is the extension's name.")
    }

    public static var remove: String { localized("developer.folders.remove", "Remove") }

    public static func removeLabel(_ name: String) -> String {
        String(localized: "developer.folders.remove.label", defaultValue: "Remove \(name)", table: table, bundle: .module,
               comment: "Accessibility label. %@ is the extension's name.")
    }

    public static var chooseFolder: String { localized("developer.folders.choose", "Load") }

    public static var optionsHeading: String { localized("developer.options", "While Developing") }

    public static var verboseLogging: String { localized("developer.verbose", "Verbose extension logging") }

    public static var verboseLoggingHelp: String {
        localized(
            "developer.verbose.help",
            "Development folders write loads, runs and host calls to the Debug Console. Only their names and results are written, never the text they carry."
        )
    }

    public static var webInspector: String { localized("developer.inspector", "Allow Safari Web Inspector") }

    public static var webInspectorHelp: String {
        localized(
            "developer.inspector.help",
            "Development folders' JavaScript appears in Safari's Develop menu. Other extensions are never inspectable."
        )
    }

    public static var unchanged: String { localized("developer.result.unchanged", "No changes to load.") }
    public static var reloaded: String { localized("developer.result.reloaded", "Reloaded.") }
    public static var approved: String { localized("developer.result.approved", "Reloaded after your approval.") }
    public static var cancelled: String {
        localized("developer.result.cancelled", "Not reloaded. The previous version is still loaded.")
    }

    /// The install review's provenance sentence for a development folder, in place of "From a file on
    /// this Mac" (SEC-8b is kept: it says the code is unsigned and unreviewed).
    public static var consentProvenance: String {
        localized(
            "developer.consent.provenance",
            "Development folder. Its code is loaded from a folder on this Mac, is not signed, and nobody has reviewed it."
        )
    }

    public static var bundle: Bundle { .module }

    /// Every key above, in the order they are declared.
    public static let all: [String] = [
        "developer.tab",
        "developer.mode.on",
        "developer.mode.on.help",
        "developer.menu.status",
        "developer.intro",
        "developer.folders",
        "developer.folders.none",
        "developer.folders.add",
        "developer.folders.add.help",
        "developer.folders.reload",
        "developer.folders.reload.label",
        "developer.folders.remove",
        "developer.folders.remove.label",
        "developer.folders.choose",
        "developer.options",
        "developer.verbose",
        "developer.verbose.help",
        "developer.inspector",
        "developer.inspector.help",
        "developer.result.unchanged",
        "developer.result.reloaded",
        "developer.result.approved",
        "developer.result.cancelled",
        "developer.consent.provenance",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: table, bundle: .module)
    }
}
