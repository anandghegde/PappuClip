import Foundation

/// Every word the rich result panel and the text prompt show or say (JS-17, JS-18, PRD §7.12), looked
/// up rather than written in place. As with `BarStrings`, the keys are listed in `all` and a test walks
/// that list against the catalogue.
public enum PanelStrings {
    public static var resultTitle: String {
        localized("panel.result.title", "Result")
    }

    /// The result text, as VoiceOver names it.
    public static var resultTextLabel: String {
        localized("panel.result.text.label", "Result text")
    }

    public static var copy: String {
        localized("panel.result.copy", "Copy")
    }

    public static var copyHelp: String {
        localized("panel.result.copy.help", "Copy the whole result to the clipboard")
    }

    public static var replace: String {
        localized("panel.result.replace", "Replace Selection")
    }

    public static var replaceHelp: String {
        localized("panel.result.replace.help", "Replace the text the action was run on with the result")
    }

    public static var insert: String {
        localized("panel.result.insert", "Insert")
    }

    public static var insertHelp: String {
        localized("panel.result.insert.help", "Put the result after the text the action was run on, keeping it")
    }

    public static var close: String {
        localized("panel.close", "Close")
    }

    public static var copied: String {
        localized("panel.result.copied", "Copied")
    }

    public static var copyFailed: String {
        localized("panel.result.copyFailed", "The clipboard would not take the result")
    }

    public static var written: String {
        localized("panel.result.written", "Done")
    }

    public static var writeFailed: String {
        localized("panel.result.writeFailed", "The clipboard could not be used to paste, so nothing was written")
    }

    public static var checking: String {
        localized("panel.result.checking", "Checking where the text came from…")
    }

    // MARK: Why Replace and Insert are unavailable (RUN-2e)

    public static var destinationNotEditable: String {
        localized("panel.destination.notEditable", "The text the action was run on cannot be edited")
    }

    public static var destinationNotFrontmost: String {
        localized("panel.destination.notFrontmost", "The app the text came from is no longer in front")
    }

    public static var destinationMoved: String {
        localized("panel.destination.moved", "Focus has moved to a different window or field")
    }

    public static var destinationSelectionChanged: String {
        localized("panel.destination.selectionChanged", "The selection has changed since the action ran")
    }

    public static var destinationInput: String {
        localized("panel.destination.input", "There has been typing or clicking since the action ran, and this app cannot be checked any other way")
    }

    public static var destinationPrivacy: String {
        localized("panel.destination.privacy", "Your privacy settings do not allow writing into this app now")
    }

    public static var destinationUnknown: String {
        localized("panel.destination.unknown", "The app the text came from could not be checked")
    }

    public static var destinationEnded: String {
        localized("panel.destination.ended", "The action is no longer running")
    }

    /// A disabled Replace or Insert says why, alongside the explanation shown under the buttons.
    public static func unavailable(_ explanation: String) -> String {
        String(
            localized: "panel.result.unavailable",
            defaultValue: "Replace and Insert are unavailable: \(explanation)",
            bundle: .module,
            comment: "Why the result cannot be written back. %@ is the reason."
        )
    }

    // MARK: The prompt (JS-18)

    public static var promptTitle: String {
        localized("panel.prompt.title", "PappuClip")
    }

    public static var submit: String {
        localized("panel.prompt.submit", "Submit")
    }

    public static var cancel: String {
        localized("panel.prompt.cancel", "Cancel")
    }

    public static var cancelHelp: String {
        localized("panel.prompt.cancel.help", "Cancel the action")
    }

    /// Where the question comes from, so a prompt is never anonymous. %@ is the extension's name.
    public static func promptSource(_ name: String) -> String {
        String(
            localized: "panel.prompt.source",
            defaultValue: "Asked by \(name)",
            bundle: .module,
            comment: "Under a prompt's field: the extension that asked. %@ is its name."
        )
    }

    public static var bundle: Bundle { .module }

    /// Every key above, in the order they are declared.
    public static let all: [String] = [
        "panel.result.title",
        "panel.result.text.label",
        "panel.result.copy",
        "panel.result.copy.help",
        "panel.result.replace",
        "panel.result.replace.help",
        "panel.result.insert",
        "panel.result.insert.help",
        "panel.close",
        "panel.result.copied",
        "panel.result.copyFailed",
        "panel.result.written",
        "panel.result.writeFailed",
        "panel.result.checking",
        "panel.destination.notEditable",
        "panel.destination.notFrontmost",
        "panel.destination.moved",
        "panel.destination.selectionChanged",
        "panel.destination.input",
        "panel.destination.privacy",
        "panel.destination.unknown",
        "panel.destination.ended",
        "panel.result.unavailable",
        "panel.prompt.title",
        "panel.prompt.submit",
        "panel.prompt.cancel",
        "panel.prompt.cancel.help",
        "panel.prompt.source",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
