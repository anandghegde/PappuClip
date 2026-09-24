import PappuCore
import PappuExtensions
import SwiftUI

/// The Extensions tab: every installed extension, and Extension Info for one of them (SEC-4a–b).
struct ExtensionListView: View {
    let model: ExtensionsModel
    @State private var shown: Shown?

    var body: some View {
        Group {
            if model.rows.isEmpty {
                Text(ExtensionStrings.empty)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rows) { row in
                    Button { shown = Shown(id: row.identity) } label: {
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(row.unreadable == nil ? row.stateLabel : ExtensionStrings.stateDisabled)
                                .font(.callout)
                                .foregroundStyle(row.isApproved ? Color.secondary : Color.orange)
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await model.refresh() }
        .sheet(item: $shown) { shown in
            ExtensionInfoView(model: model, identity: shown.id) { self.shown = nil }
        }
    }
}

/// Which extension's Info sheet is open. A wrapper, so the store's identity type is not made
/// `Identifiable` for the whole program on behalf of one sheet.
private struct Shown: Identifiable {
    var id: LocalIdentity
}

/// One extension: what it can do, what it has been granted, its options, and the ways to take any of
/// that back (SEC-4a, SEC-4b, ALM-6).
struct ExtensionInfoView: View {
    let model: ExtensionsModel
    let identity: LocalIdentity
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let row = model.row(identity) {
                Form {
                    Section {
                        LabeledContent(row.name, value: row.stateLabel)
                        if let version = row.version {
                            Text(ExtensionStrings.version(version)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let unreadable = row.unreadable {
                            Text(unreadable).foregroundStyle(.secondary)
                        } else if !row.isApproved {
                            Text(ExtensionStrings.pendingHelp).foregroundStyle(.secondary)
                        }
                    }
                    if !row.listed.isEmpty {
                        Section(ExtensionStrings.capabilities) {
                            ForEach(row.listed, id: \.self) { Text($0) }
                        }
                    }
                    if !row.gates.isEmpty {
                        Section(ExtensionStrings.permissions) {
                            ForEach(row.gates) { gate in
                                Toggle(gate.sentence, isOn: Binding(
                                    get: { gate.isGranted },
                                    set: { on in Task { await model.setGate(gate.capability, granted: on, of: identity) } }
                                ))
                                .disabled(!row.isApproved)
                            }
                        }
                    }
                    Section {
                        if row.isApproved {
                            Button(ExtensionStrings.revoke, role: .destructive) { Task { await model.revoke(identity) } }
                            Text(ExtensionStrings.revokeHelp).font(.callout).foregroundStyle(.secondary)
                        } else if row.unreadable == nil {
                            Button(ExtensionStrings.approve) { Task { await model.approve(identity) } }
                        }
                    }
                    if row.unreadable == nil {
                        Section(ExtensionStrings.options) {
                            OptionsForm(model: model, identity: identity, options: row.options)
                        }
                    }
                    if let failure = model.failure {
                        Text(failure).foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Button(ExtensionStrings.uninstall, role: .destructive) {
                        Task {
                            await model.uninstall(identity)
                            done()
                        }
                    }
                    Spacer()
                    Button(SettingsStrings.done, action: done).keyboardShortcut(.defaultAction)
                }
                .padding()
            }
        }
        .frame(width: 480, height: 520)
    }
}

/// ALM-6: the per-action gear. An action with no extension of its own — a built-in — or an extension
/// with no options says so rather than showing an empty sheet.
struct OptionsSheet: View {
    let model: ExtensionsModel?
    let owner: String?
    let title: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding([.horizontal, .top])
            Form {
                if let model, let owner, let row = model.row(owner: owner), !row.options.isEmpty {
                    OptionsForm(model: model, identity: row.identity, options: row.options)
                } else {
                    Text(ExtensionStrings.noOptions).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(SettingsStrings.done, action: done).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 360)
    }
}

/// The sheet generated from an extension's `options` (§8.9): one control per type.
struct OptionsForm: View {
    let model: ExtensionsModel
    let identity: LocalIdentity
    let options: [ExtensionsModel.OptionRow]

    var body: some View {
        if options.isEmpty {
            Text(ExtensionStrings.noOptions).foregroundStyle(.secondary)
        }
        ForEach(options) { option in
            VStack(alignment: .leading, spacing: 4) {
                control(for: option)
                if let help = option.help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func control(for option: ExtensionsModel.OptionRow) -> some View {
        switch option.control {
        case .heading:
            Text(option.label).font(.headline)
        case .toggle:
            Toggle(option.label, isOn: Binding(
                get: { option.isOn },
                set: { set($0 ? OptionValues.on : OptionValues.off, option) }
            ))
        case .choice(let choices):
            Picker(option.label, selection: Binding(get: { option.value }, set: { set($0, option) })) {
                ForEach(choices, id: \.self) { Text($0.label).tag($0.value) }
            }
        case .text(let multiline):
            OptionTextField(label: option.label, value: option.value, secure: false, multiline: multiline) { set($0, option) }
        case .secret:
            OptionTextField(label: option.label, value: option.value, secure: true, multiline: false) { set($0, option) }
        case .password:
            LabeledContent(option.label) { EmptyView() }
        }
    }

    private func set(_ value: String, _ option: ExtensionsModel.OptionRow) {
        Task { await model.setOption(value, for: option.id, of: identity) }
    }
}

/// Text is committed when the user presses Return or leaves the field, not on every keystroke: each
/// commit is a store write and a catalog rebuild.
private struct OptionTextField: View {
    let label: String
    let value: String
    let secure: Bool
    let multiline: Bool
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(label: String, value: String, secure: Bool, multiline: Bool, commit: @escaping (String) -> Void) {
        self.label = label
        self.value = value
        self.secure = secure
        self.multiline = multiline
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        Group {
            if secure {
                SecureField(label, text: $draft)
            } else {
                TextField(label, text: $draft, axis: multiline ? .vertical : .horizontal)
                    .lineLimit(multiline ? 3...8 : 1...1)
            }
        }
        .focused($focused)
        .onSubmit(save)
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear(perform: save)
    }

    private func save() {
        if draft != value { commit(draft) }
    }
}
