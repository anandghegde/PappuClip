import SwiftUI

struct LabView: View {
    @Bindable var model: LabModel

    var body: some View {
        NavigationSplitView {
            List(model.spikes, id: \.id, selection: $model.selectedID) { spike in
                VStack(alignment: .leading) {
                    Text(spike.title)
                    Text(spike.id).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let spike = model.selected {
                SpikeDetail(model: model, spike: spike)
            } else {
                ContentUnavailableView("Pick a spike", systemImage: "flask")
            }
        }
        .task {
            // TCC changes arrive with no notification, so poll while the window is open.
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct SpikeDetail: View {
    @Bindable var model: LabModel
    let spike: any Spike

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spike.question).font(.headline)
            Text(spike.instructions).font(.callout).foregroundStyle(.secondary)

            PermissionRow(model: model)

            ForEach(spike.options) { option in
                Toggle(isOn: binding(for: option.id)) {
                    Text(option.title)
                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("Permission state you set up for this run", text: $model.tccState)
                Button(model.isRunning ? "Running…" : "Run") { model.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                .onChange(of: model.log.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }

            Text("Notes for the spike report: prompts you saw, anything the log cannot know.").font(.caption)
            TextEditor(text: $model.notes)
                .font(.callout)
                .frame(height: 70)
                .border(.quaternary)

            HStack {
                Button("Save Notes into Result") { model.save() }.disabled(model.savedURL == nil)
                Button("Reveal in Finder") { model.revealResult() }
                Spacer()
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                } else if let url = model.savedURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle(spike.title)
    }

    private func binding(for option: String) -> Binding<Bool> {
        Binding(
            get: { model.enabledOptions.contains(option) },
            set: { isOn in
                if isOn { model.enabledOptions.insert(option) } else { model.enabledOptions.remove(option) }
            }
        )
    }
}

private struct PermissionRow: View {
    let model: LabModel

    var body: some View {
        HStack(spacing: 14) {
            badge("Accessibility", model.permissions.accessibility)
            badge("Input Monitoring", model.permissions.listenEvent)
            badge("Post events", model.permissions.postEvent)
            Spacer()
            Menu("Permissions") {
                Button("Show the Accessibility Prompt") { PermissionActions.promptForAccessibility() }
                Button("Open Accessibility Settings") { PermissionActions.openAccessibilitySettings() }
                Button("Open Input Monitoring Settings") { PermissionActions.openInputMonitoringSettings() }
            }
            .fixedSize()
        }
    }

    private func badge(_ title: String, _ granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(granted ? .green : .secondary)
    }
}
