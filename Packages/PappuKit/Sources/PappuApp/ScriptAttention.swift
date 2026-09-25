import AppKit
import Foundation
import PappuRuntime

/// What the app does when a script asks something of the user (§8.4, ONB-5).
///
/// **Settings** open the extension's options sheet over the Settings window (ALM-6, §8.9): the script
/// said a value it needs is missing or wrong, and the sheet is where the user sets it.
///
/// **Automation** is an alert, because it is a question only the user can answer and the answer is
/// in System Settings, not in PappuClip. macOS asks once per pair of apps and never again, so the
/// alert says where the switch is rather than suggesting the action be tried again.
///
/// **A missing app** (EXM-10) is an alert naming it, with a button for its website when the extension
/// gave one.
@MainActor
final class ScriptAttention: AttentionPresenting {
    static let automationPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")

    /// The action's title and the extension it belongs to.
    private let openOptions: @MainActor (String, String?) -> Void

    init(openOptions: @escaping @MainActor (String, String?) -> Void) {
        self.openOptions = openOptions
    }

    func present(_ attention: ExtensionRunner.Attention, for action: String, owner: String?) {
        switch attention {
        case .settings:
            openOptions(action, owner)
        case .automationPermission:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = AppStrings.automationTitle(action)
            alert.informativeText = AppStrings.automationBody
            alert.addButton(withTitle: AppStrings.automationOpen)
            alert.addButton(withTitle: AppStrings.automationDismiss)
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, let pane = Self.automationPane else { return }
            NSWorkspace.shared.open(pane)
        case .missingApp(let name, let link):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = AppStrings.missingAppTitle(name)
            alert.informativeText = AppStrings.missingAppBody(action: action, app: name)
            if link != nil { alert.addButton(withTitle: AppStrings.missingAppWebsite) }
            alert.addButton(withTitle: AppStrings.missingAppDismiss)
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, let link else { return }
            NSWorkspace.shared.open(link)
        }
    }
}
