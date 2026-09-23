import AppKit
import Foundation
import PappuRuntime

/// What the app does when a script asks something of the user (§8.4, ONB-5).
///
/// **Settings** open the Settings window. The options sheet an extension's settings will have is M2
/// week 5; until it exists the window is the nearest place, and the one the sheet will open from.
///
/// **Automation** is an alert, because it is a question only the user can answer and the answer is
/// in System Settings, not in PappuClip. macOS asks once per pair of apps and never again, so the
/// alert says where the switch is rather than suggesting the action be tried again.
@MainActor
final class ScriptAttention: AttentionPresenting {
    static let automationPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")

    private let openSettings: @MainActor () -> Void

    init(openSettings: @escaping @MainActor () -> Void) {
        self.openSettings = openSettings
    }

    func present(_ attention: ExtensionRunner.Attention, for action: String) {
        switch attention {
        case .settings:
            openSettings()
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
        }
    }
}
