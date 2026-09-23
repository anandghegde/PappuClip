import Foundation

/// How a Shortcut run ended (§8.4).
public enum ShortcutResult: Sendable, Equatable {
    /// It finished. The text it returned, or nil when it returned nothing — a shortcut that only
    /// does something, which is as good an ending as one that answers.
    case returned(String?)
    /// It could not be started, or it ended with an error: no shortcut by that name, an action in it
    /// that failed, a prompt the user dismissed.
    case failed
    /// It was stopped. Whatever it was doing may have been done anyway (RUN-3e).
    case stopped
}

/// One Shortcut in flight: something to wait for and something to stop.
public protocol ShortcutRun: CancellableWork {
    func result() async -> ShortcutResult
}

/// Starts Shortcuts (§8.4). A seam because the real one needs the Shortcuts app, the named shortcut,
/// and a person to answer it if it asks anything.
public protocol ShortcutRunning: Sendable {
    /// - Returns: Nil when it could not be started at all.
    func start(_ name: String, input: String) -> (any ShortcutRun)?
}

/// Runs a Shortcut through `/usr/bin/shortcuts`, the command-line tool macOS ships.
///
/// **Why the tool and not Apple events to Shortcuts Events.** Both run the shortcut without bringing
/// the Shortcuts app forward, which §8.4 asks for. The tool is a child process we started, so it has a
/// process ID to signal, and stopping it is how a shortcut that stopped to ask a question is got rid
/// of; an Apple event can only be waited out. What the tool cannot do is stop the work it handed to
/// the Shortcuts daemon, which is why the run is `delegated` and why cancelling it is reported as
/// `askedToStop` rather than as stopped (RUN-3e).
///
/// **Files rather than pipes.** The tool reads its input from a path and writes its output to one,
/// and asking for `public.plain-text` makes the output what `after` expects: text, and not a
/// rich-text file that happens to contain some.
public struct SystemShortcutRunner: ShortcutRunning {
    public static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    public init() {}

    public func start(_ name: String, input: String) -> (any ShortcutRun)? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pappuclip-shortcut-\(UUID().uuidString)", isDirectory: true)
        let inputFile = directory.appendingPathComponent("input.txt")
        let outputFile = directory.appendingPathComponent("output.txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(input.utf8).write(to: inputFile)
            let process = try ChildProcess(
                ChildProcess.Launch(executable: Self.tool, arguments: [
                    "run", name,
                    "--input-path", inputFile.path,
                    "--output-path", outputFile.path,
                    "--output-type", "public.plain-text",
                ]),
                ownership: .delegated
            )
            return Run(process: process, directory: directory, output: outputFile)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private struct Run: ShortcutRun {
        let process: ChildProcess
        let directory: URL
        let output: URL

        var ownership: WorkOwnership { process.ownership }

        func cancel() async -> WorkCancellation {
            await process.cancel()
        }

        func result() async -> ShortcutResult {
            let ended = await process.result()
            defer { try? FileManager.default.removeItem(at: directory) }
            if ended.cancelled { return .stopped }
            guard ended.succeeded else { return .failed }
            // No output file is a shortcut that returned nothing, which is not a failure.
            guard let data = try? Data(contentsOf: output) else { return .returned(nil) }
            let text = String(decoding: data, as: UTF8.self)
            return .returned(text.isEmpty ? nil : text)
        }
    }
}
