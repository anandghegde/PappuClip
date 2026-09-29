import AppKit
import Foundation

/// The alerts behind `PopClipImporter` and `CoexistenceNotice`: the AppKit half, with no decisions in
/// it. What they say is `PopClipStrings`; what the answers do is tested in those two types. NSAlert's
/// buttons and suppression box take their titles as their accessibility labels.
@MainActor
enum PopClipAlerts {
    /// EXM-11's offer. True to go on to the review.
    static func offer(_ offer: PopClipImporter.Offer) -> Bool {
        let alert = NSAlert()
        alert.messageText = PopClipStrings.offerTitle
        alert.informativeText = PopClipStrings.offerBody(extensions: offer.extensions, excludedApps: offer.excludedApps)
        alert.addButton(withTitle: PopClipStrings.offerImport)
        alert.addButton(withTitle: PopClipStrings.offerNotNow)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What an import did. Nothing for one that was declined or cancelled.
    static func report(_ report: PopClipImporter.Report?) {
        guard let report, let text = PopClipStrings.summary(report) else { return }
        let alert = NSAlert()
        alert.messageText = PopClipStrings.resultTitle
        alert.informativeText = text
        alert.addButton(withTitle: PopClipStrings.ok)
        NSApp.activate()
        alert.runModal()
    }

    /// ONB-6's explanation and offer.
    static func coexistence() -> (CoexistenceNotice.Response, suppress: Bool) {
        let alert = NSAlert()
        alert.messageText = PopClipStrings.coexistenceTitle
        alert.informativeText = PopClipStrings.coexistenceBody
        alert.addButton(withTitle: PopClipStrings.coexistenceKeepBoth)
        alert.addButton(withTitle: PopClipStrings.coexistencePause)
        alert.addButton(withTitle: PopClipStrings.coexistenceHowTo)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = PopClipStrings.coexistenceSuppress
        NSApp.activate()
        let response: CoexistenceNotice.Response = switch alert.runModal() {
        case .alertSecondButtonReturn: .pauseAutomaticAppearance
        case .alertThirdButtonReturn: .showHowToTurnOffPopClip
        default: .keepBoth
        }
        return (response, alert.suppressionButton?.state == .on)
    }

    /// The steps for turning PopClip's bar off, in words: PappuClip does not do it (ONB-6).
    static func howTo() {
        let alert = NSAlert()
        alert.messageText = PopClipStrings.howToTitle
        alert.informativeText = PopClipStrings.howToBody
        alert.addButton(withTitle: PopClipStrings.ok)
        NSApp.activate()
        alert.runModal()
    }
}
