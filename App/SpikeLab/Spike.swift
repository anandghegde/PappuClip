import Foundation
import PappuHarness

/// One M0 experiment. `run` is synchronous and is called on a thread of its own, never the main
/// thread: spikes block on semaphores and time things, and neither mixes well with an executor.
protocol Spike: Sendable {
    /// Also the results sub-directory, for example `spike-2-taps`.
    var id: String { get }
    var title: String { get }
    /// Quoted from PRD §12 so a result file stands on its own.
    var question: String { get }
    /// What the operator has to set up, and what to look for while it runs.
    var instructions: String { get }
    var options: [SpikeOption] { get }

    func run(recorder: RunRecorder, enabled: Set<String>)
}

/// A switch for a part of a spike that is slow, intrusive or needs the operator's hands.
struct SpikeOption: Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var defaultOn: Bool
}

enum SpikeRegistry {
    /// In the order of implementation plan §3: 2, 1, 3, 4, 6, 5.
    static let all: [any Spike] = [
        TapPermissionSpike(),
        PanelSpike(),
        SelectionSpike(),
        AXEnableSpike(),
        ClipboardSpike(),
        JSHelperSpike(),
        // Not a spike: M1's taps on a real session.
        TapServiceCheck(),
    ]

    static func spike(withID id: String) -> (any Spike)? {
        all.first { $0.id == id }
    }
}

enum SpikeRunner {
    /// Runs `spike` to completion off the main thread and returns the recorder, so the caller can
    /// save once now and again after the operator adds notes.
    static func run(
        _ spike: any Spike,
        enabled: Set<String>,
        parameters: [String: String],
        onLog: @escaping @Sendable (String) -> Void
    ) async -> RunRecorder {
        var parameters = parameters
        parameters["options"] = enabled.sorted().joined(separator: ",")
        // Launched from a shell, macOS holds the *terminal* responsible for our permissions, so
        // every permission result would describe the terminal. Scripts/run-spike.sh uses `open`.
        parameters["launchedByLaunchd"] = String(getppid() == 1)
        let recorder = RunRecorder(
            runID: spike.id, title: spike.title, question: spike.question, parameters: parameters, onLog: onLog
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                spike.run(recorder: recorder, enabled: enabled)
                continuation.resume()
            }
            thread.name = "spike.\(spike.id)"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        return recorder
    }

    static var defaultResultsStore: ResultsStore {
        if let root = Bundle.main.object(forInfoDictionaryKey: "PappuRepoRoot") as? String,
           FileManager.default.fileExists(atPath: root + "/Tests/results") {
            return ResultsStore(repositoryRoot: URL(filePath: root).standardizedFileURL)
        }
        return ResultsStore(directory: FileManager.default.temporaryDirectory.appending(path: "PappuClip-results"))
    }
}
