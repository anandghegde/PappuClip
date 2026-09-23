import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rules → Apps (PRD §7.5, ACT-17a, ALM-8): the apps PappuClip treats differently, and how.
///
/// Two independent ticks per app rather than one menu of three, because they are two different promises.
/// "Don't appear automatically" is about the bar: it stays away, and the shortcut still works, which is
/// the whole point of an exclusion. "Never read text here" is about reading: nothing in that app is read
/// by any route, ever, and `PrivacyGate` refuses before a permit is minted. A user who wants the second
/// almost always wants the first as well, but a user who wants only the first would be badly served by a
/// control that gave them both.
struct AppRulesView: View {
    let model: SettingsModel

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SettingsStrings.appsTitle)
                .font(.headline)
            Text(SettingsStrings.appsExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            list
                .frame(minHeight: 200)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Button(SettingsStrings.appsAdd) { add() }
                Button(SettingsStrings.appsRemove) {
                    if let selection {
                        model.removeApp(selection)
                        self.selection = nil
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button(SettingsStrings.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var list: some View {
        if model.apps.isEmpty {
            // An empty list with no words in it reads as something that failed to load.
            VStack {
                Spacer()
                Text(SettingsStrings.appsEmpty).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(model.apps) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.name)
                        HStack(spacing: 16) {
                            Toggle(
                                SettingsStrings.appsExclude,
                                isOn: Binding(
                                    get: { rule.isExcluded },
                                    set: { model.setExcluded($0, forApp: rule.bundleID) }
                                )
                            )
                            Toggle(
                                SettingsStrings.appsBlock,
                                isOn: Binding(
                                    get: { rule.isHardBlocked },
                                    set: { model.setHardBlocked($0, forApp: rule.bundleID) }
                                )
                            )
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    }
                    .padding(.vertical, 2)
                    .tag(rule.bundleID)
                }
            }
        }
    }

    /// An app is named by its bundle identifier, because that is what a rule can be written about: a
    /// path changes when the app moves and a name changes when it is renamed. An application bundle with
    /// no identifier at all cannot be named in a rule (`PrivacyRules.mode(for:)` says so), so choosing
    /// one adds nothing — there is nothing to add.
    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        model.addApp(bundleID)
        selection = bundleID
    }
}
