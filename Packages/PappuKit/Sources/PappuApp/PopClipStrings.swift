import Foundation

/// Every word Import from PopClip (EXM-11) and the coexistence notice (ONB-6) say. Their own list,
/// walked against the catalogue by a test, as `AppStrings` is.
public enum PopClipStrings {
    // MARK: Import from PopClip (EXM-11)

    public static var importMenu: String { localized("popclip.import.menu", "Import from PopClip…") }

    public static var offerTitle: String { localized("popclip.import.offer.title", "Import from PopClip?") }

    /// Counts are given as numerals after a colon, so the sentence needs no plural forms.
    public static func offerBody(extensions: Int, excludedApps: Int) -> String {
        String(
            localized: "popclip.import.offer.body",
            defaultValue: "PappuClip found PopClip’s extensions on this Mac. It can bring them across, together with the apps PopClip stays away from. Nothing in PopClip is changed.\n\nExtensions: \(extensions)\nExcluded apps: \(excludedApps)\n\nThe extensions are not signed. You will see what each one can do before anything is installed.",
            bundle: .module
        )
    }

    public static var offerImport: String { localized("popclip.import.offer.import", "Review and Import…") }
    public static var offerNotNow: String { localized("popclip.import.offer.notNow", "Not Now") }

    public static var resultTitle: String { localized("popclip.import.result.title", "Import from PopClip") }

    public static func resultApproved(_ names: String) -> String {
        String(localized: "popclip.import.result.approved", defaultValue: "Installed and turned on: \(names)", bundle: .module)
    }

    public static func resultWaiting(_ names: String) -> String {
        String(localized: "popclip.import.result.waiting", defaultValue: "Installed but turned off until you approve them in Settings › Extensions: \(names)", bundle: .module)
    }

    public static func resultAlreadyInstalled(_ count: Int) -> String {
        String(localized: "popclip.import.result.alreadyInstalled", defaultValue: "Already installed: \(count)", bundle: .module)
    }

    public static func resultFailed(_ lines: String) -> String {
        String(localized: "popclip.import.result.failed", defaultValue: "Could not be imported:\n\(lines)", bundle: .module)
    }

    public static func resultExcluded(_ count: Int) -> String {
        String(localized: "popclip.import.result.excluded", defaultValue: "Apps the bar now stays away from: \(count)", bundle: .module)
    }

    public static var resultNothing: String { localized("popclip.import.result.nothing", "There was nothing new to import.") }

    public static var ok: String { localized("popclip.ok", "OK") }

    // MARK: Coexistence (ONB-6)

    public static var coexistenceTitle: String { localized("popclip.coexistence.title", "PopClip Is Running") }

    public static var coexistenceBody: String {
        localized(
            "popclip.coexistence.body",
            "PopClip and PappuClip both show a bar when you select text, so you may see two. PappuClip does not change or quit PopClip.\n\nWhile PopClip is running, PappuClip does not copy text on your behalf when its bar appears on its own; the keyboard shortcut still works."
        )
    }

    public static var coexistencePause: String { localized("popclip.coexistence.pause", "Turn Off PappuClip’s Automatic Bar") }
    public static var coexistenceHowTo: String { localized("popclip.coexistence.howTo", "How to Turn Off PopClip’s") }
    public static var coexistenceKeepBoth: String { localized("popclip.coexistence.keepBoth", "Keep Both") }
    public static var coexistenceSuppress: String { localized("popclip.coexistence.suppress", "Don’t show this again") }

    public static var howToTitle: String { localized("popclip.howTo.title", "Turning Off PopClip’s Bar") }

    public static var howToBody: String {
        localized(
            "popclip.howTo.body",
            "PappuClip leaves PopClip’s settings to you. In PopClip:\n\n1. Open PopClip’s menu from its icon in the menu bar.\n2. Turn PopClip off there, or quit it.\n3. To keep it from starting again, remove it under System Settings › General › Login Items.\n\nWhile PopClip is not running, PappuClip’s bar works as usual."
        )
    }

    public static var bundle: Bundle { .module }

    public static let all: [String] = [
        "popclip.import.menu",
        "popclip.import.offer.title",
        "popclip.import.offer.body",
        "popclip.import.offer.import",
        "popclip.import.offer.notNow",
        "popclip.import.result.title",
        "popclip.import.result.approved",
        "popclip.import.result.waiting",
        "popclip.import.result.alreadyInstalled",
        "popclip.import.result.failed",
        "popclip.import.result.excluded",
        "popclip.import.result.nothing",
        "popclip.ok",
        "popclip.coexistence.title",
        "popclip.coexistence.body",
        "popclip.coexistence.pause",
        "popclip.coexistence.howTo",
        "popclip.coexistence.keepBoth",
        "popclip.coexistence.suppress",
        "popclip.howTo.title",
        "popclip.howTo.body",
    ]

    /// The closing alert's text for one import, or nil when the import was declined or cancelled.
    public static func summary(_ report: PopClipImporter.Report) -> String? {
        guard !report.cancelled else { return nil }
        var lines: [String] = []
        if !report.approved.isEmpty { lines.append(resultApproved(report.approved.formatted(.list(type: .and)))) }
        if !report.waiting.isEmpty { lines.append(resultWaiting(report.waiting.formatted(.list(type: .and)))) }
        if report.alreadyInstalled > 0 { lines.append(resultAlreadyInstalled(report.alreadyInstalled)) }
        if !report.excludedApps.isEmpty { lines.append(resultExcluded(report.excludedApps.count)) }
        if !report.failed.isEmpty {
            lines.append(resultFailed(report.failed.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")))
        }
        return lines.isEmpty ? resultNothing : lines.joined(separator: "\n\n")
    }

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
