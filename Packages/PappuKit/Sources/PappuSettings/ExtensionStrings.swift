import Foundation

/// Every word the install review, Extension Info and the options sheet say (PRD §7.12).
///
/// Kept apart from `SettingsStrings` because the review is a window of its own that opens without the
/// Settings window, and because most of these sentences take an argument. Same contract: each key is
/// in `all`, and a test walks `all` against the catalogue.
public enum ExtensionStrings {
    public static var tab: String { localized("settings.tab.extensions", "Extensions") }

    // MARK: The review (EXM-5)

    public static func installTitle(_ name: String) -> String {
        String(localized: "consent.title.install", defaultValue: "Install \u{201C}\(name)\u{201D}?", bundle: .module,
               comment: "%@ is the extension's name.")
    }

    public static func updateTitle(_ name: String) -> String {
        String(localized: "consent.title.update", defaultValue: "Update \u{201C}\(name)\u{201D}?", bundle: .module,
               comment: "%@ is the extension's name.")
    }

    public static var listedHeading: String { localized("consent.listed.heading", "When you use it, this extension:") }

    public static var gatedHeading: String {
        localized("consent.gated.heading", "It also asks for the following. Each stays off unless you turn it on.")
    }

    public static var nothingAsked: String {
        localized("consent.nothing", "It asks for nothing beyond showing its buttons.")
    }

    /// SEC-8b: local code is never presented as trusted.
    public static var fromThisMac: String {
        localized("consent.provenance.local", "From a file on this Mac. It is not signed, and nobody has reviewed it.")
    }

    public static func collision(_ name: String) -> String {
        String(localized: "consent.collision",
               defaultValue: "You already have an extension called \u{201C}\(name)\u{201D}. This one will be installed beside it, not over it.",
               bundle: .module, comment: "%@ is the installed extension's name.")
    }

    public static var install: String { localized("consent.install", "Install") }
    public static var update: String { localized("consent.update", "Update") }
    public static var installSeparately: String { localized("consent.installSeparately", "Install Separately") }
    public static var replace: String { localized("consent.replace", "Replace It") }
    public static var cancel: String { localized("consent.cancel", "Cancel") }

    // MARK: §S4's sentences, one per capability

    public static func sendsTextToHost(_ host: String) -> String {
        String(localized: "capability.webPage.text", defaultValue: "Sends the selected text to \(host) when you click it.",
               bundle: .module, comment: "%@ is a host name.")
    }

    public static func opensHost(_ host: String) -> String {
        String(localized: "capability.webPage", defaultValue: "Opens \(host).", bundle: .module, comment: "%@ is a host name.")
    }

    public static var opensConfiguredURLWithText: String {
        localized("capability.configuredURL.text", "Opens a URL you configure, containing the selected text.")
    }

    public static var opensConfiguredURL: String { localized("capability.configuredURL", "Opens a URL you configure.") }

    public static func sendsTextToAppLink(_ scheme: String) -> String {
        String(localized: "capability.appLink.text",
               defaultValue: "Sends the selected text to the app that opens \u{201C}\(scheme):\u{201D} links.",
               bundle: .module, comment: "%@ is a URL scheme.")
    }

    public static func opensAppLink(_ scheme: String) -> String {
        String(localized: "capability.appLink", defaultValue: "Opens the app that handles \u{201C}\(scheme):\u{201D} links.",
               bundle: .module, comment: "%@ is a URL scheme.")
    }

    public static func pressesKeys(_ keys: String) -> String {
        String(localized: "capability.keys", defaultValue: "Presses \(keys) in the current app.", bundle: .module,
               comment: "%@ is a list of key combinations.")
    }

    public static func runsService(_ name: String) -> String {
        String(localized: "capability.service",
               defaultValue: "Runs the \u{201C}\(name)\u{201D} service, which can do whatever that service does.",
               bundle: .module, comment: "%@ is a Services menu item.")
    }

    public static func runsShortcut(_ name: String) -> String {
        String(localized: "capability.shortcut",
               defaultValue: "Runs the shortcut \u{201C}\(name)\u{201D}. The shortcut can do whatever Shortcuts allows.",
               bundle: .module, comment: "%@ is a shortcut's name.")
    }

    public static var readsAndReplacesText: String {
        localized("capability.readsAndReplaces", "Reads the selected text, and can copy, paste or replace it.")
    }

    public static var runsOnEveryAppearance: String {
        localized("capability.dynamic", "Runs every time the bar appears, to decide what to show.")
    }

    public static func sendsData(_ hosts: String) -> String {
        String(localized: "capability.sendsData", defaultValue: "Can send data to \(hosts).", bundle: .module,
               comment: "%@ is a list of host names.")
    }

    public static func controlsApps(_ apps: String) -> String {
        String(localized: "capability.controlsApps", defaultValue: "Its scripts control \(apps).", bundle: .module,
               comment: "%@ is a list of application names.")
    }

    public static var gateScript: String {
        localized("capability.gate.script", "Runs a script outside the sandbox, with your user permissions")
    }

    public static var gateNetwork: String { localized("capability.gate.network", "Can send the selected text to any server") }
    public static var gateSyntheticInput: String {
        localized("capability.gate.syntheticInput", "Can type and press keys in the current app")
    }

    public static var gateUnboundedCode: String {
        localized("capability.gate.unboundedCode", "Runs code whose reach this version of PappuClip cannot check")
    }

    // MARK: Extension Info (SEC-4a–b)

    public static var empty: String {
        localized(
            "extensions.empty",
            "No extensions are installed. Open an extension file, or select an extension\u{2019}s text and choose Install Extension."
        )
    }

    public static var stateEnabled: String { localized("extensions.state.enabled", "On") }
    public static var statePending: String { localized("extensions.state.pending", "Waiting for approval") }
    public static var stateDisabled: String { localized("extensions.state.disabled", "Off") }
    public static var stateSuspended: String { localized("extensions.state.suspended", "Stopped") }
    public static var stateRevoked: String { localized("extensions.state.revoked", "Revoked") }

    public static var capabilities: String { localized("extensions.info.capabilities", "What it can do") }
    public static var permissions: String { localized("extensions.info.permissions", "Permissions") }
    public static var approve: String { localized("extensions.info.approve", "Approve") }
    public static var revoke: String { localized("extensions.info.revoke", "Revoke Approval") }

    public static var revokeHelp: String {
        localized("extensions.info.revoke.help", "Stops anything it is running. It will not run again until you approve it.")
    }

    public static var pendingHelp: String { localized("extensions.info.pending", "It will not run until you approve it.") }
    public static var uninstall: String { localized("extensions.info.uninstall", "Uninstall") }

    public static func version(_ digest: String) -> String {
        String(localized: "extensions.info.version", defaultValue: "Installed version \(digest)", bundle: .module,
               comment: "%@ is the start of the version's content digest.")
    }

    public static func unreadable(_ reason: String) -> String {
        String(localized: "extensions.info.unreadable", defaultValue: "Its files could not be read: \(reason)", bundle: .module,
               comment: "%@ is the reason.")
    }

    public static func failed(_ reason: String) -> String {
        String(localized: "extensions.failed", defaultValue: "That did not work: \(reason)", bundle: .module,
               comment: "%@ is the reason.")
    }

    // MARK: Options (ALM-6, §8.9)

    public static var options: String { localized("extensions.options", "Options") }
    public static var optionsButton: String { localized("extensions.options.button", "Options\u{2026}") }
    public static var noOptions: String { localized("extensions.options.none", "This extension has no options.") }

    public static var passwordHelp: String {
        localized("extensions.options.password", "Asked for when signing in, and never stored.")
    }

    public static var secretHelp: String { localized("extensions.options.secret", "Kept in your Keychain.") }

    public static var bundle: Bundle { .module }

    /// Every key above, in the order they are declared.
    public static let all: [String] = [
        "settings.tab.extensions",
        "consent.title.install",
        "consent.title.update",
        "consent.listed.heading",
        "consent.gated.heading",
        "consent.nothing",
        "consent.provenance.local",
        "consent.collision",
        "consent.install",
        "consent.update",
        "consent.installSeparately",
        "consent.replace",
        "consent.cancel",
        "capability.webPage.text",
        "capability.webPage",
        "capability.configuredURL.text",
        "capability.configuredURL",
        "capability.appLink.text",
        "capability.appLink",
        "capability.keys",
        "capability.service",
        "capability.shortcut",
        "capability.readsAndReplaces",
        "capability.dynamic",
        "capability.sendsData",
        "capability.controlsApps",
        "capability.gate.script",
        "capability.gate.network",
        "capability.gate.syntheticInput",
        "capability.gate.unboundedCode",
        "extensions.empty",
        "extensions.state.enabled",
        "extensions.state.pending",
        "extensions.state.disabled",
        "extensions.state.suspended",
        "extensions.state.revoked",
        "extensions.info.capabilities",
        "extensions.info.permissions",
        "extensions.info.approve",
        "extensions.info.revoke",
        "extensions.info.revoke.help",
        "extensions.info.pending",
        "extensions.info.uninstall",
        "extensions.info.version",
        "extensions.info.unreadable",
        "extensions.failed",
        "extensions.options",
        "extensions.options.button",
        "extensions.options.none",
        "extensions.options.password",
        "extensions.options.secret",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
