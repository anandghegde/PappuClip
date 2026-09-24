import Foundation
import PappuDiagnostics

/// Every word the menu bar and the app's own alerts say, looked up rather than written in place
/// (PRD §7.12).
///
/// The keys are listed in `all` as well as used, and a test walks that list against the catalogue, so
/// a string added here without an entry beside it fails the build rather than shipping as its own key.
/// `BarStrings` is the same arrangement for the bar, and `SettingsStrings` for the settings window;
/// each module owns the words it says, because each has its own bundle to say them from.
public enum AppStrings {
    // MARK: The menu bar item (PRD §7.5)

    /// The status item has no title, so this is the only name a screen reader has for it.
    public static var menuBarLabel: String {
        localized("menu.accessibility.label", "PappuClip")
    }

    public static var appearAutomatically: String {
        localized("menu.appearAutomatically", "Appear Automatically")
    }

    public static var pauseForOneHour: String {
        localized("menu.pauseForOneHour", "Pause for One Hour")
    }

    public static var pauseUntilResumed: String {
        localized("menu.pauseUntilResumed", "Pause Until Resumed")
    }

    public static var resume: String {
        localized("menu.resume", "Resume")
    }

    public static var settings: String {
        localized("menu.settings", "Settings…")
    }

    public static var debugConsole: String {
        localized("menu.debugConsole", "Debug Console")
    }

    public static var quit: String {
        localized("menu.quit", "Quit PappuClip")
    }

    /// ACT-18's pause status, when the pause has an end the user can be told about.
    public static func pausedUntil(_ time: String) -> String {
        String(
            localized: "menu.status.pausedUntil",
            defaultValue: "Paused until \(time)",
            bundle: .module,
            comment: "%@ is a time of day, already formatted for the user's locale."
        )
    }

    public static var pausedUntilResumed: String {
        localized("menu.status.pausedUntilResumed", "Paused")
    }

    /// Shown in the menu when the automatic path cannot work because the grant is missing (ONB-1). The
    /// menu is the one surface a user reaches when nothing else is happening, so it is where the reason
    /// belongs; pressing it opens the onboarding window.
    public static var accessibilityMissing: String {
        localized("menu.accessibilityMissing", "Accessibility Permission Needed…")
    }

    /// ONB-4: trusted and refused anyway. A different sentence, because the tick the user can see is
    /// already there and telling them to grant it again sends them in a circle.
    public static var accessibilityStale: String {
        localized("menu.accessibilityStale", "Repair Accessibility Permission…")
    }

    // MARK: The onboarding window (ONB-1, ONB-4)

    /// The window's title. It is an ordinary window with a title bar, because a first run that opens a
    /// panel with no way back is a first run the user cannot leave and return to.
    public static var onboardingWindowTitle: String {
        localized("onboarding.window.title", "Welcome to PappuClip")
    }

    public static var onboardingWelcomeTitle: String {
        localized("onboarding.welcome.title", "Select text. Act on it.")
    }

    /// What the app does, in the words the user will recognise a minute later when it happens.
    public static var onboardingWelcomeBody: String {
        localized(
            "onboarding.welcome.body",
            "Select text anywhere and a small bar appears beside it, with what you can do with that text — copy it, search for it, open a link, change its case."
        )
    }

    public static var onboardingWelcomeContinue: String {
        localized("onboarding.welcome.continue", "Continue")
    }

    public static var onboardingPermissionTitle: String {
        localized("onboarding.permission.title", "PappuClip needs Accessibility permission")
    }

    /// ONB-1 asks for the reason, not just the request. macOS puts reading the selection behind
    /// Accessibility, and a user who is not told that has been asked for a wide permission for nothing.
    public static var onboardingPermissionBody: String {
        localized(
            "onboarding.permission.body",
            "macOS only lets an app read the text you have selected once you allow it in Privacy & Security → Accessibility. PappuClip reads the selection to decide what to offer you, and nothing else."
        )
    }

    public static var onboardingPermissionOpen: String {
        localized("onboarding.permission.open", "Open Accessibility Settings")
    }

    /// The window watches the trust database and closes itself, so there is no Done button to press and
    /// no way to arrive at a finished setup that still says it is unfinished.
    public static var onboardingPermissionWaiting: String {
        localized(
            "onboarding.permission.waiting",
            "This window closes itself as soon as the permission is granted."
        )
    }

    public static var onboardingRepairTitle: String {
        localized("onboarding.repair.title", "Accessibility permission needs repairing")
    }

    /// ONB-4. The tick is already in the list, so "grant the permission" would send the user round in a
    /// circle; what actually clears it is removing the entry and adding it again.
    public static var onboardingRepairBody: String {
        localized(
            "onboarding.repair.body",
            "PappuClip is already listed under Privacy & Security → Accessibility, but macOS is refusing it — which happens when an update replaces the app. Remove PappuClip from that list with the − button, then add it again."
        )
    }

    // MARK: What a script asks of the user (§8.4, ONB-5)

    public static func automationTitle(_ action: String) -> String {
        String(
            localized: "automation.alert.title",
            defaultValue: "\u{201C}\(action)\u{201D} was not allowed to control another app",
            bundle: .module,
            comment: "%@ is the action's name, as its button shows it."
        )
    }

    /// ONB-5. macOS asks once per app and remembers the answer, so a script refused once stays refused
    /// until the switch in Settings is turned on; asking again would not bring the question back.
    public static var automationBody: String {
        localized(
            "automation.alert.body",
            "macOS asks once whether PappuClip may control each app, and remembers the answer. To let this action run, turn PappuClip on for that app under Privacy & Security \u{2192} Automation."
        )
    }

    public static var automationOpen: String {
        localized("automation.alert.open", "Open Automation Settings")
    }

    public static var automationDismiss: String {
        localized("automation.alert.dismiss", "Not Now")
    }

    /// The module's own bundle, so that the test which walks `all` can look every key up from outside.
    public static var bundle: Bundle { .module }

    /// Every key above. The order is the order they are declared in.
    public static let all: [String] = [
        "menu.accessibility.label",
        "menu.appearAutomatically",
        "menu.pauseForOneHour",
        "menu.pauseUntilResumed",
        "menu.resume",
        "menu.settings",
        "menu.debugConsole",
        "menu.quit",
        "menu.status.pausedUntil",
        "menu.status.pausedUntilResumed",
        "menu.accessibilityMissing",
        "menu.accessibilityStale",
        "onboarding.window.title",
        "onboarding.welcome.title",
        "onboarding.welcome.body",
        "onboarding.welcome.continue",
        "onboarding.permission.title",
        "onboarding.permission.body",
        "onboarding.permission.open",
        "onboarding.permission.waiting",
        "onboarding.repair.title",
        "onboarding.repair.body",
        "automation.alert.title",
        "automation.alert.body",
        "automation.alert.open",
        "automation.alert.dismiss",
        "console.window.title",
        "console.empty",
        "console.clear",
        "console.copy",
        "console.kind.loadFailed",
        "console.kind.returned",
        "console.kind.threw",
        "console.kind.stopped",
        "console.kind.crashed",
        "console.kind.hung",
        "console.kind.suspended",
    ]

    // MARK: The Debug Console (DIA-1)

    public static var consoleWindowTitle: String {
        localized("console.window.title", "Debug Console")
    }

    public static var consoleEmpty: String {
        localized("console.empty", "Nothing yet. What extensions print, and how their actions end, appears here.")
    }

    public static var consoleClear: String {
        localized("console.clear", "Clear")
    }

    public static var consoleCopy: String {
        localized("console.copy", "Copy All")
    }

    /// The words the window puts beside a line of each kind. Printed text stands on its own.
    public static func consoleLabel(_ kind: ConsoleEntry.Kind) -> String? {
        switch kind {
        case .printed: nil
        case .loadFailed: localized("console.kind.loadFailed", "Could not load")
        case .returned: localized("console.kind.returned", "Returned")
        case .threw: localized("console.kind.threw", "Threw")
        case .stopped: localized("console.kind.stopped", "Stopped")
        case .crashed: localized("console.kind.crashed", "The JavaScript helper stopped while this was running")
        case .hung: localized("console.kind.hung", "Did not stop when asked; the JavaScript helper was restarted")
        case .suspended: localized("console.kind.suspended", "Crashed too often and will not run until PappuClip restarts")
        }
    }

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
