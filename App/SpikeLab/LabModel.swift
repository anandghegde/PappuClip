import AppKit
import Observation
import PappuHarness

@MainActor
@Observable
final class LabModel {
    let spikes = SpikeRegistry.all
    var selectedID: String? = SpikeRegistry.all.first?.id {
        didSet { resetForSelection() }
    }
    var enabledOptions: Set<String> = []
    /// What the operator set up before the run, for example "Accessibility only, fresh grant".
    var tccState = ""
    var notes = ""
    var log: [String] = []
    var isRunning = false
    var permissions = PermissionSnapshot.current()
    var savedURL: URL?
    var errorMessage: String?

    private var recorder: RunRecorder?
    private let store = SpikeRunner.defaultResultsStore

    init() {
        resetForSelection()
    }

    var selected: (any Spike)? {
        selectedID.flatMap(SpikeRegistry.spike(withID:))
    }

    var resultsDirectory: URL { store.directory }

    func refreshPermissions() {
        permissions = .current()
    }

    func run() {
        guard let spike = selected, !isRunning else { return }
        isRunning = true
        log = []
        savedURL = nil
        errorMessage = nil
        let parameters = ["mode": "window", "tccState": tccState.isEmpty ? "not recorded" : tccState]
        Task {
            let recorder = await SpikeRunner.run(spike, enabled: enabledOptions, parameters: parameters) { line in
                Task { @MainActor [weak self] in self?.log.append(line) }
            }
            self.recorder = recorder
            isRunning = false
            refreshPermissions()
            save()
        }
    }

    /// Called after the run and again whenever the operator wants their notes in the file.
    func save() {
        guard let recorder else { return }
        do {
            let result = recorder.finish(notes: notes)
            if let savedURL { try? FileManager.default.removeItem(at: savedURL) }
            savedURL = try store.write(result)
        } catch {
            errorMessage = "Could not write the result: \(error.localizedDescription)"
        }
    }

    func revealResult() {
        NSWorkspace.shared.activateFileViewerSelecting([savedURL ?? resultsDirectory])
    }

    private func resetForSelection() {
        enabledOptions = Set(selected?.options.filter(\.defaultOn).map(\.id) ?? [])
        recorder = nil
        savedURL = nil
        log = []
    }
}
