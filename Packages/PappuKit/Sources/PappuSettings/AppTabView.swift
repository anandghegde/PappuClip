import PappuCore
import SwiftUI

/// Settings → App (PRD §7.5): the version and links, Software Update, Start at login, and the Debug
/// Console. `AppTabModel` decides everything; this draws it.
///
/// Not here yet: "Show in menu bar" (hiding the status item needs the relaunch-reopens-Settings path of
/// §7.5) and the website and sponsor links, which have nowhere to point until the site exists.
struct AppTabView: View {
    let model: AppTabModel

    var body: some View {
        Form {
            about
            updates
            startup
            diagnosticsSection
            troubleshooting
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }

    private var about: some View {
        Section(AppTabStrings.aboutHeading) {
            LabeledContent(ProductIdentity.appName) {
                Text(model.versionText).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            if !model.links.isEmpty {
                HStack {
                    ForEach(model.links) { link in
                        Button(link.title) { model.open(link) }
                            .buttonStyle(.link)
                            .accessibilityLabel(AppTabStrings.linkLabel(link.title))
                    }
                }
            }
        }
    }

    private var updates: some View {
        Section(AppTabStrings.updatesHeading) {
            Picker(
                AppTabStrings.policy,
                selection: Binding(get: { model.policy }, set: { model.setPolicy($0) })
            ) {
                Text(AppTabStrings.policyOff).tag(UpdatePolicy.off)
                Text(AppTabStrings.policyNotify).tag(UpdatePolicy.notifyOnly)
                Text(AppTabStrings.policyInstall).tag(UpdatePolicy.installAutomatically)
            }
            .accessibilityLabel(AppTabStrings.policy)
            .accessibilityHint(AppTabStrings.policyHelp)
            .disabled(!model.updatesAvailable)
            Text(AppTabStrings.policyHelp).font(.caption).foregroundStyle(.secondary)

            Toggle(
                AppTabStrings.includeBetas,
                isOn: Binding(get: { model.channel == .beta }, set: { model.setChannel($0 ? .beta : .stable) })
            )
            .accessibilityLabel(AppTabStrings.includeBetas)
            .accessibilityHint(AppTabStrings.includeBetasHelp)
            .disabled(!model.updatesAvailable)
            Text(AppTabStrings.includeBetasHelp).font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                Button(AppTabStrings.checkNow) { model.checkForUpdates() }
                    .accessibilityLabel(AppTabStrings.checkNow)
                    .disabled(!model.canCheckForUpdates)
                Spacer()
                if model.updatesAvailable {
                    Text(model.lastCheckText()).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.updatesAvailable {
                Text(AppTabStrings.updatesUnavailable).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var startup: some View {
        Section(AppTabStrings.startupHeading) {
            Toggle(
                AppTabStrings.startAtLogin,
                isOn: Binding(get: { model.loginItemIsOn }, set: { model.setStartAtLogin($0) })
            )
            .accessibilityLabel(AppTabStrings.startAtLogin)
            .disabled(!model.loginItemIsAvailable)
            switch model.loginItemState {
            case .needsApproval:
                Text(AppTabStrings.loginItemNeedsApproval).font(.caption).foregroundStyle(.secondary)
                Button(AppTabStrings.loginItemOpenSettings) { model.openLoginItemSettings() }
                    .accessibilityLabel(AppTabStrings.loginItemOpenSettings)
            case .unavailable:
                Text(AppTabStrings.loginItemUnavailable).font(.caption).foregroundStyle(.secondary)
            case .on, .off:
                EmptyView()
            }
            if let failure = model.loginItemFailure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Diagnostics (DIA-3, DIA-4) — hook
    //
    // The opt-in crash reports and beta diagnostics toggles go here, as one `Section`, between Startup
    // and Troubleshooting. Their model, strings and storage are their own (see the DIA-3/DIA-4 work);
    // nothing in Software Update or Start at login depends on them. Empty until then.
    @ViewBuilder
    private var diagnosticsSection: some View {
        EmptyView()
    }

    private var troubleshooting: some View {
        Section(AppTabStrings.troubleshootingHeading) {
            Button(AppTabStrings.debugConsole) { model.showDebugConsole() }
                .accessibilityLabel(AppTabStrings.debugConsole)
                .accessibilityHint(AppTabStrings.debugConsoleHelp)
        }
    }
}
