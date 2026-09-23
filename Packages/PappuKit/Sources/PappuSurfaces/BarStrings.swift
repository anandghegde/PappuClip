import Foundation

/// Every word the bar shows or says, looked up rather than written in place (PRD §7.12).
///
/// The keys are listed in `all` as well as used, and a test walks that list against the catalogue, so a
/// string added here without an entry beside it fails the build rather than shipping as its own key.
public enum BarStrings {
    public static var barLabel: String {
        localized("bar.accessibility.label", "PappuClip actions")
    }

    /// Posted when the bar appears, alongside the layout-changed notification (BAR-14).
    public static var barAppeared: String {
        localized("bar.accessibility.appeared", "PappuClip actions available")
    }

    public static var cancel: String {
        localized("bar.cancel", "Cancel")
    }

    public static var feedbackRunning: String {
        localized("bar.feedback.running", "Working")
    }

    public static var feedbackCopied: String {
        localized("bar.feedback.copied", "Copied")
    }

    /// What is said when an action's answer replaces the buttons (BAR-12b, BAR-14).
    public static func feedbackResult(_ text: String) -> String {
        String(
            localized: "bar.feedback.result",
            defaultValue: "Result: \(text)",
            bundle: .module,
            comment: "Announced when an action's result is shown in the bar. %@ is the result."
        )
    }

    public static var feedbackSucceeded: String {
        localized("bar.feedback.succeeded", "Done")
    }

    public static var feedbackFailed: String {
        localized("bar.feedback.failed", "The action did not finish")
    }

    /// A disabled button says why, in the tooltip and to VoiceOver (BAR-14).
    public static func disabledTooltip(name: String, explanation: String) -> String {
        String(
            localized: "bar.tooltip.disabled",
            defaultValue: "\(name) — \(explanation)",
            bundle: .module,
            comment: "An action's name, then why it cannot be run."
        )
    }

    /// The module's own bundle, so that the test which walks `all` can look every key up from
    /// outside the module.
    public static var bundle: Bundle { .module }

    /// Every key above. The order is the order they are declared in.
    public static let all: [String] = [
        "bar.accessibility.label",
        "bar.accessibility.appeared",
        "bar.cancel",
        "bar.feedback.running",
        "bar.feedback.copied",
        "bar.feedback.result",
        "bar.feedback.succeeded",
        "bar.feedback.failed",
        "bar.tooltip.disabled",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
