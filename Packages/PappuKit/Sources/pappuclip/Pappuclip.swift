import ArgumentParser
import Foundation
import PappuCLI
import PappuCore

/// The extension author's command line (architecture §2.1, §10.8). Not sandboxed, and not the app:
/// nothing it runs reaches another app, the clipboard or the network.
@main
struct Pappuclip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pappuclip",
        abstract: "Tools for PappuClip extension authors.",
        subcommands: [Run.self]
    )
}

/// DEV-2.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a module's exported function (by default `test`), or an action script, and exit 0 or 1.",
        discussion: """
        The file runs in PappuClip's own JavaScript environment. Host calls get the app's refusals and are \
        printed, not performed: nothing is pasted, copied to the real clipboard, opened, pressed or sent.
        """
    )

    @Argument(help: "A JavaScript or TypeScript file, inside its extension package or on its own.")
    var file: String

    @Argument(help: "The exported function to call. Default: test.")
    var function: String?

    @Flag(help: "Run the file as an action script even if it exports something.")
    var script = false

    @Option(help: "The selected text the script is given (popclip.input.text).")
    var text = "Hello, world."

    @Option(name: .customLong("option"), help: "An option value, as id=value. Repeatable.")
    var options: [String] = []

    @Option(name: .customLong("allow"), help: ArgumentHelp(
        "Grant a gated capability for this run. Repeatable.",
        valueName: GatedCapability.allCases.map(\.rawValue).joined(separator: "|")
    ))
    var allowed: [String] = []

    @Option(help: "What the clipboard holds as the run starts.")
    var clipboard: String?

    @Option(help: "Seconds before the run is stopped and counted as a failure.")
    var timeout: Int = 30

    @Flag(help: "Do not print the host calls the script made.")
    var quiet = false

    func validate() throws {
        for value in allowed where GatedCapability(rawValue: value) == nil {
            throw ValidationError("There is no capability \(value).")
        }
        for pair in options where !pair.contains("=") {
            throw ValidationError("--option takes id=value, not \(pair).")
        }
        guard timeout > 0 else { throw ValidationError("--timeout must be positive.") }
    }

    func run() async throws {
        var values: [String: String] = [:]
        for pair in options {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            values[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        let outcome = await DevelopmentRun().run(DevelopmentRun.Request(
            file: URL(filePath: file),
            function: function,
            asScript: script,
            text: text,
            options: values,
            gates: Set(allowed.compactMap(GatedCapability.init(rawValue:))),
            clipboard: clipboard,
            timeout: .seconds(timeout)
        ))
        for line in DevelopmentReport.lines(for: outcome, showingCalls: !quiet) {
            let handle = line.isError ? FileHandle.standardError : FileHandle.standardOutput
            handle.write(Data((line.text + "\n").utf8))
        }
        throw ExitCode(outcome.exitCode)
    }
}
