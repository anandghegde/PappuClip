import Foundation

/// Every word Settings → App says (PRD §7.5, §11.4).
///
/// In a table of their own, `AppTab.strings`: the same contract as `DeveloperStrings` — each key is in
/// `all`, and a test walks `all` against the table.
public enum AppTabStrings {
    public static let table = "AppTab"

    public static var tab: String { localized("app.tab", "App") }

    // MARK: About

    public static var aboutHeading: String { localized("app.about", "About") }

    public static func version(_ marketing: String, _ build: String) -> String {
        String(localized: "app.version", defaultValue: "Version \(marketing) (\(build))", table: table, bundle: .module,
               comment: "The first %@ is the version, the second the build number.")
    }

    public static var sourceCode: String { localized("app.link.source", "Source Code") }
    public static var issues: String { localized("app.link.issues", "Report an Issue") }

    public static func linkLabel(_ title: String) -> String {
        String(localized: "app.link.label", defaultValue: "\(title), opens in your browser", table: table, bundle: .module,
               comment: "Accessibility label for a link button. %@ is the link's title.")
    }

    // MARK: Software Update

    public static var updatesHeading: String { localized("app.updates", "Software Update") }
    public static var policy: String { localized("app.updates.policy", "Updates") }
    public static var policyOff: String { localized("app.updates.policy.off", "Off") }
    public static var policyNotify: String { localized("app.updates.policy.notify", "Notify only") }
    public static var policyInstall: String { localized("app.updates.policy.install", "Install automatically") }

    public static var policyHelp: String {
        localized(
            "app.updates.policy.help",
            "Checks once a day. Every update is verified against PappuClip's signing key before it is installed."
        )
    }

    public static var includeBetas: String { localized("app.updates.betas", "Include beta versions") }

    public static var includeBetasHelp: String {
        localized(
            "app.updates.betas.help",
            "Betas arrive earlier and may have problems. Turning this off does not go back to an older version; the next stable release replaces the beta."
        )
    }

    public static var checkNow: String { localized("app.updates.check", "Check for Updates Now") }
    public static var neverChecked: String { localized("app.updates.never", "Not checked yet.") }

    public static func lastChecked(_ when: String) -> String {
        String(localized: "app.updates.last", defaultValue: "Last checked \(when).", table: table, bundle: .module,
               comment: "%@ is a date and time.")
    }

    /// Development builds, and any build made without an update feed and key.
    public static var updatesUnavailable: String {
        localized("app.updates.unavailable", "This build does not update itself. Release builds do.")
    }

    // MARK: Start at login

    public static var startupHeading: String { localized("app.startup", "Startup") }
    public static var startAtLogin: String { localized("app.startup.login", "Start at login") }

    public static var loginItemNeedsApproval: String {
        localized(
            "app.startup.login.approval",
            "Allow PappuClip in System Settings \u{2192} General \u{2192} Login Items to finish."
        )
    }

    public static var loginItemOpenSettings: String {
        localized("app.startup.login.open", "Open Login Items Settings")
    }

    public static var loginItemUnavailable: String {
        localized(
            "app.startup.login.unavailable",
            "This copy of PappuClip cannot start at login. Move it to the Applications folder and try again."
        )
    }

    public static var loginItemFailed: String {
        localized("app.startup.login.failed", "The login item could not be changed. Try again from System Settings.")
    }

    // MARK: Troubleshooting

    public static var troubleshootingHeading: String { localized("app.troubleshooting", "Troubleshooting") }
    public static var debugConsole: String { localized("app.console", "Open Debug Console") }

    public static var debugConsoleHelp: String {
        localized("app.console.help", "What extensions printed and how their actions ended since launch.")
    }

    public static var bundle: Bundle { .module }

    /// Every key above, in the order they are declared.
    public static let all: [String] = [
        "app.tab",
        "app.about",
        "app.version",
        "app.link.source",
        "app.link.issues",
        "app.link.label",
        "app.updates",
        "app.updates.policy",
        "app.updates.policy.off",
        "app.updates.policy.notify",
        "app.updates.policy.install",
        "app.updates.policy.help",
        "app.updates.betas",
        "app.updates.betas.help",
        "app.updates.check",
        "app.updates.never",
        "app.updates.last",
        "app.updates.unavailable",
        "app.startup",
        "app.startup.login",
        "app.startup.login.approval",
        "app.startup.login.open",
        "app.startup.login.unavailable",
        "app.startup.login.failed",
        "app.troubleshooting",
        "app.console",
        "app.console.help",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: table, bundle: .module)
    }
}
