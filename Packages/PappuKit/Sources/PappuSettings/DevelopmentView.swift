import AppKit
import PappuCore
import PappuExtensions
import SwiftUI

/// Settings → Developer (DEV-1): the development folders, and the two switches that only reach them.
struct DevelopmentView: View {
    let model: DevelopmentModel

    var body: some View {
        Form {
            if model.isActive {
                Section {
                    DevelopmentBanner()
                }
            }
            Section {
                Text(DeveloperStrings.intro).foregroundStyle(.secondary)
            }
            Section(DeveloperStrings.foldersHeading) {
                if model.rows.isEmpty {
                    Text(DeveloperStrings.noFolders).foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(row.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let status = row.status {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        Button(DeveloperStrings.reload) { Task { await model.reload(row.identity) } }
                            .accessibilityLabel(DeveloperStrings.reloadLabel(row.name))
                        Button(DeveloperStrings.remove, role: .destructive) { Task { await model.remove(row.identity) } }
                            .accessibilityLabel(DeveloperStrings.removeLabel(row.name))
                    }
                }
                Button(DeveloperStrings.addFolder) { choose() }
                    .accessibilityLabel(DeveloperStrings.addFolder)
                    .accessibilityHint(DeveloperStrings.addFolderHelp)
                if let failure = model.failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            Section(DeveloperStrings.optionsHeading) {
                Toggle(DeveloperStrings.verboseLogging, isOn: Binding(
                    get: { model.verboseLogging },
                    set: { on in Task { await model.setVerboseLogging(on) } }
                ))
                .accessibilityLabel(DeveloperStrings.verboseLogging)
                Text(DeveloperStrings.verboseLoggingHelp).font(.caption).foregroundStyle(.secondary)
                Toggle(DeveloperStrings.webInspector, isOn: Binding(
                    get: { model.webInspector },
                    set: { on in Task { await model.setWebInspector(on) } }
                ))
                .accessibilityLabel(DeveloperStrings.webInspector)
                Text(DeveloperStrings.webInspectorHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }

    /// A package folder, chosen whole: a `.popclipext` is a package, so the panel is told to pick it
    /// rather than open it.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = DeveloperStrings.chooseFolder
        panel.message = DeveloperStrings.addFolderHelp
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.add(url) }
    }
}

/// The persistent warning: drawn at the top of the Developer tab for as long as any folder is approved,
/// and echoed by the menu bar menu's status line.
struct DevelopmentBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hammer.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DeveloperStrings.modeOn).font(.headline)
                Text(DeveloperStrings.modeOnHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DeveloperStrings.modeOn)
        .accessibilityHint(DeveloperStrings.modeOnHelp)
    }
}
