import Foundation

/// Every word the crash-report and beta-diagnostics switches say (DIA-3, DIA-4).
///
/// In a table of their own, `Diagnostics.strings`: the same contract as `DeveloperStrings` — each key is
/// in `all`, and a test walks `all` against the table.
public enum DiagnosticsStrings {
    public static let table = "Diagnostics"

    public static var heading: String { localized("diagnostics.heading", "Diagnostics") }

    public static var crashReports: String { localized("diagnostics.crash", "Send crash reports") }

    public static var crashReportsHelp: String {
        localized(
            "diagnostics.crash.help",
            "When PappuClip or its JavaScript helper crashes, a report is sent once a day: the app and macOS versions, the error code and where in the program it stopped. Never selected text, clipboard contents, extension options or the names of your apps."
        )
    }

    public static var betaDiagnostics: String { localized("diagnostics.beta", "Share beta diagnostics") }

    public static var betaDiagnosticsHelp: String {
        localized(
            "diagnostics.beta.help",
            "Once a day, send how many times PappuClip started and crashed and how long the bar took to appear, with the app and macOS versions. No identifier, no text, no app names and no option values."
        )
    }

    public static var discarded: String {
        localized("diagnostics.discarded", "Turning a switch off deletes what it collected and has not sent.")
    }

    public static var showPreview: String { localized("diagnostics.preview", "Show What Is Sent\u{2026}") }

    public static var showPreviewHelp: String {
        localized("diagnostics.preview.help", "The reports waiting to be sent, exactly as they would be sent.")
    }

    public static var previewCrashReports: String { localized("diagnostics.preview.crash", "Crash reports") }
    public static var previewBetaDiagnostics: String { localized("diagnostics.preview.beta", "Beta diagnostics") }
    public static var previewNothing: String {
        localized("diagnostics.preview.nothing", "Nothing is collected while both switches are off.")
    }

    public static var done: String { localized("diagnostics.done", "Done") }

    public static var bundle: Bundle { .module }

    /// Every key above, in the order they are declared.
    public static let all: [String] = [
        "diagnostics.heading",
        "diagnostics.crash",
        "diagnostics.crash.help",
        "diagnostics.beta",
        "diagnostics.beta.help",
        "diagnostics.discarded",
        "diagnostics.preview",
        "diagnostics.preview.help",
        "diagnostics.preview.crash",
        "diagnostics.preview.beta",
        "diagnostics.preview.nothing",
        "diagnostics.done",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: table, bundle: .module)
    }
}
