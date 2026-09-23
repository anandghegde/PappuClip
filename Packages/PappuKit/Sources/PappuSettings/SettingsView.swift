import PappuCore
import PappuSelection
import PappuSurfaces
import SwiftUI

/// The Settings window (PRD §7.5), in the two tabs M1 owes: General, and the list of actions.
///
/// **SwiftUI here, AppKit for the bar.** The bar is a non-activating panel placed to the pixel against a
/// selection it must not steal focus from, and every one of those is a fight in SwiftUI; a settings
/// window is a form, which is the one thing SwiftUI is unambiguously better at. What both surfaces share
/// is that the framework decides nothing: `SettingsModel` holds every answer, these views draw it, and
/// what a control writes goes back through a named setter rather than into a store's binding.
///
/// Three things named in §7.5 are deliberately not here. The Light/Dark/Auto choice and the size slider
/// are BAR-8b and land in M4 with the rest of the appearance controls; per-action commands and
/// reordering are ALM-2a and ALM-5, and arrive with the extension packages the action list is for; the
/// App tab is P1. Everything P0 for M1 is: the automatic-appearance toggle, the shortcut, the position,
/// the per-app rules, the Accessibility state and the built-in actions.
public struct SettingsView: View {
    public enum Tab: String, Sendable, CaseIterable {
        case general
        case actions
    }

    private let model: SettingsModel
    @State private var tab: Tab = .general
    @State private var isShowingApps = false

    public init(model: SettingsModel, tab: Tab = .general) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label(SettingsStrings.general, systemImage: "gearshape") }
                .tag(Tab.general)
            ActionListView(actions: model.actions)
                .tabItem { Label(SettingsStrings.actions, systemImage: "list.bullet") }
                .tag(Tab.actions)
        }
        .frame(width: 520, height: 400)
        .sheet(isPresented: $isShowingApps) {
            AppRulesView(model: model)
        }
    }

    private var general: some View {
        Form {
            if let warning = model.accessibilityWarning {
                Section {
                    AccessibilityBanner(warning: warning) { model.openAccessibilityPane() }
                }
            }

            Section {
                Toggle(
                    SettingsStrings.appearAutomatically,
                    isOn: Binding(
                        get: { model.appearAutomatically },
                        set: { model.setAppearAutomatically($0) }
                    )
                )
                Text(SettingsStrings.appearAutomaticallyHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(SettingsStrings.shortcut) {
                    ShortcutField(
                        shortcut: model.shortcut,
                        record: { model.record($0) },
                        clear: { model.clearShortcut() }
                    )
                }
                // ACT-5's refusal, under the field that caused it rather than in an alert: what the user
                // pressed is still on screen, and the sentence says what to press instead.
                if let refusal = model.shortcutRefusal {
                    Text(refusal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(
                    SettingsStrings.position,
                    selection: Binding(get: { model.position }, set: { model.setPosition($0) })
                ) {
                    Text(SettingsStrings.positionAbove).tag(BarPosition.aboveText)
                    Text(SettingsStrings.positionBelow).tag(BarPosition.belowText)
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                LabeledContent(SettingsStrings.rules) {
                    Button(SettingsStrings.rulesApps) { isShowingApps = true }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// ONB-1 and ONB-4 where a user who is looking for the setting will see it, with the one button that
/// helps: System Settings' own Accessibility pane. Asking again through `AXIsProcessTrustedWithOptions`
/// does nothing once the user has answered once, so the link is the honest offer.
private struct AccessibilityBanner: View {
    let warning: String
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(warning)
                Button(SettingsStrings.accessibilityOpen, action: open)
            }
        }
    }
}

/// §7.6's list, read-only in this build. It answers "where did this button come from", which is the
/// question a user has about a bar they did not configure.
private struct ActionListView: View {
    let actions: [SettingsModel.ActionRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SettingsStrings.actionsExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            List(actions) { action in
                HStack(spacing: 10) {
                    ActionIconView(icon: action.icon, title: action.title)
                        .frame(width: 22, alignment: .center)
                    Text(action.title)
                    Spacer()
                    if !action.isEnabled {
                        Text(SettingsStrings.actionsOff).foregroundStyle(.secondary)
                    }
                    Text(action.isBuiltIn ? SettingsStrings.actionsBuiltIn : action.extensionName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .opacity(action.isEnabled ? 1 : 0.5)
            }
        }
    }
}

/// The same fallback the bar makes (`BarItem.init`): an icon this build cannot draw becomes the action's
/// first letters, because a blank square says nothing.
private struct ActionIconView: View {
    let icon: BarIcon?
    let title: String

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).accessibilityHidden(true)
        case .letters(let letters):
            Text(letters).font(.caption).accessibilityHidden(true)
        case nil:
            Text(String(title.prefix(1))).font(.caption).accessibilityHidden(true)
        }
    }
}
