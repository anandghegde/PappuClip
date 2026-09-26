import Foundation
import PappuCore
import PappuJSBridge

/// External scripts from JavaScript (JS-5): `popclip.runShellScript`, `runShellScriptFile`, the `$` tag,
/// `runAppleScript`, `runAppleScriptFile` and `runShortcut`, which the helper sends as three host calls.
///
/// Each runs outside the sandbox with the user's permissions, which is what the `script` gate says, so
/// every call needs it granted, and the extension must have the `script` entitlement besides: a grant
/// given for a Shell Script action is not a way for the same extension's JavaScript to start processes
/// it never declared (SEC-7d).
///
/// They run as the actions of the same kinds do: a shell script as a child process with the small
/// environment and the package folder as its working directory, a file found only inside the package,
/// an AppleScript in the Runner, a Shortcut through `/usr/bin/shortcuts`. Each is attached to the
/// invocation, so Escape stops it (RUN-3d).
///
/// **Shell answers.** A shell script settles to `{ status, stdout, stderr, terminationReason }` whatever
/// its exit, and the helper resolves to its output for a zero status and rejects with all four
/// otherwise: a script's own failure is an answer the extension may want to read, not a refusal.
public struct ScriptHostCalls: HostCallHandling {
    public static let shell = "runShellScript"
    public static let appleScript = "runAppleScript"
    public static let shortcut = "runShortcut"
    /// The most of each output passed back to a script.
    public static let outputLimit = 4 << 20

    private let manager: InvocationManager
    private let appleScripts: any AppleScriptRunning
    private let shortcuts: any ShortcutRunning

    public init(manager: InvocationManager, appleScripts: any AppleScriptRunning, shortcuts: any ShortcutRunning) {
        self.manager = manager
        self.appleScripts = appleScripts
        self.shortcuts = shortcuts
    }

    public var methods: Set<String> { [Self.shell, Self.appleScript, Self.shortcut] }

    public func gate(for method: String, in run: HostAPIDispatcher.Run) -> GatedCapability? {
        .script
    }

    struct Shell: Decodable {
        /// Inline source, or `file`, relative to the package.
        var script: String?
        var file: String?
        var interpreter: String?
        var shellMode: ShellScriptAction.Mode?
        var stdin: String?
        var env: [String: String]?
    }

    struct AppleScript: Decodable {
        var source: String?
        var file: String?
        var handler: String?
        var params: [String]?
    }

    struct Shortcut: Decodable {
        var name: String
        var input: String?
    }

    struct ShellAnswer: Encodable, Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
        /// `exit`, or `uncaughtSignal` when `status` is the signal, as `Process` names them.
        var terminationReason: String
    }

    public func perform(_ method: String, arguments: Data, for run: HostAPIDispatcher.Run) async throws -> JSHostAnswer {
        guard run.action?.entitlements.contains(.script) == true else {
            throw HostCallRefusal("\(method) needs the script entitlement, which this extension does not have.")
        }
        switch method {
        case Self.shell: return try await shell(try JSONDecoder().decode(Shell.self, from: arguments), run)
        case Self.appleScript: return try await appleScript(try JSONDecoder().decode(AppleScript.self, from: arguments), run)
        default: return try await shortcut(try JSONDecoder().decode(Shortcut.self, from: arguments), run)
        }
    }

    // MARK: Shell

    private func shell(_ given: Shell, _ run: HostAPIDispatcher.Run) async throws -> JSHostAnswer {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("pappuclip-script-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: scratch) }
        let directory = run.action?.directory
        let script: URL
        let source: ScriptSource
        switch (given.script, given.file) {
        case (let text?, nil):
            script = scratch.appendingPathComponent("script")
            try Data(text.utf8).write(to: script)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            source = .inline(text)
        case (nil, let relative?):
            guard let directory, let found = PackageFile.resolve(relative, in: directory) else {
                throw HostCallRefusal("runShellScriptFile was not given a file in the extension's package.")
            }
            script = found
            source = .file(relative)
        default:
            throw HostCallRefusal("runShellScript was not given what it takes.")
        }
        let action = ShellScriptAction(source: source, interpreter: given.interpreter, mode: given.shellMode)
        let invocation: ShellInvocation
        do {
            invocation = try ShellInvocation.plan(
                action,
                script: script.path,
                inlineSource: given.script,
                userShell: SystemShellScriptRunner.userShell,
                isExecutable: { fileManager.isExecutableFile(atPath: $0) }
            )
        } catch {
            throw HostCallRefusal("runShellScript was not given an interpreter it can find.")
        }
        // The script's own variables may not replace the small environment's PATH, HOME or TMPDIR.
        let base = SystemShellScriptRunner.environment(scratch: scratch)
        let environment = base.merging((given.env ?? [:]).filter { base[$0.key] == nil }) { mine, _ in mine }
        let process: ChildProcess
        do {
            process = try ChildProcess(ChildProcess.Launch(
                executable: URL(fileURLWithPath: invocation.executable),
                arguments: invocation.arguments,
                environment: environment,
                workingDirectory: directory ?? scratch,
                standardInput: given.stdin.map { Data($0.utf8) }
            ))
        } catch {
            return .failed("The shell script could not be started.")
        }
        guard await manager.attach(process, to: run.invocation) else {
            _ = await process.cancel()
            throw HostCallRefusal("The action is no longer running.")
        }
        let ended = await process.result()
        if ended.cancelled { throw HostCallRefusal("The action is no longer running.") }
        return try value(Self.answer(ended))
    }

    static func answer(_ ended: ChildProcess.Result) -> ShellAnswer {
        ShellAnswer(
            status: ended.status,
            stdout: text(ended.standardOutput),
            stderr: text(ended.standardError),
            terminationReason: ended.signalled ? "uncaughtSignal" : "exit"
        )
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data.prefix(outputLimit), as: UTF8.self)
    }

    // MARK: AppleScript and Shortcuts

    private func appleScript(_ given: AppleScript, _ run: HostAPIDispatcher.Run) async throws -> JSHostAnswer {
        let source: AppleScriptRunRequest.Source
        switch (given.source, given.file) {
        case (let text?, nil):
            source = .text(text)
        case (nil, let relative?):
            guard let directory = run.action?.directory, let found = PackageFile.resolve(relative, in: directory) else {
                throw HostCallRefusal("runAppleScriptFile was not given a file in the extension's package.")
            }
            source = .file(found)
        default:
            throw HostCallRefusal("runAppleScript was not given what it takes.")
        }
        let request = AppleScriptRunRequest(source: source, handler: given.handler, arguments: given.params ?? [])
        guard let started = await appleScripts.start(request) else { return .failed("The AppleScript could not be started.") }
        return try await settle(started, run) { ended in
            switch ended {
            case .returned(let text): return try value(text)
            case .automationDenied: return .failed("The AppleScript was not allowed to control the app it talks to.")
            case .needsSettings, .failed: return .failed("The AppleScript did not work.")
            case .stopped: throw HostCallRefusal("The action is no longer running.")
            }
        }
    }

    private func shortcut(_ given: Shortcut, _ run: HostAPIDispatcher.Run) async throws -> JSHostAnswer {
        guard let started = shortcuts.start(given.name, input: given.input ?? "") else {
            return .failed("The shortcut could not be started.")
        }
        guard await manager.attach(started, to: run.invocation) else {
            _ = await started.cancel()
            throw HostCallRefusal("The action is no longer running.")
        }
        switch await started.result() {
        case .returned(let text): return try value(text)
        case .failed: return .failed("The shortcut did not work.")
        case .stopped: throw HostCallRefusal("The action is no longer running.")
        }
    }

    private func settle(
        _ started: any ScriptRun,
        _ run: HostAPIDispatcher.Run,
        _ answer: (ScriptResult) throws -> JSHostAnswer
    ) async throws -> JSHostAnswer {
        guard await manager.attach(started, to: run.invocation) else {
            _ = await started.cancel()
            throw HostCallRefusal("The action is no longer running.")
        }
        return try answer(await started.result())
    }

    private func value(_ encodable: some Encodable) throws -> JSHostAnswer {
        .value(String(decoding: try JSONEncoder().encode(encodable), as: UTF8.self))
    }
}
