import Foundation
import PappuCore

/// How a shell script, an AppleScript or a Service ended (§8.4).
public enum ScriptResult: Sendable, Equatable {
    /// It ran to the end. What it returned for `after`, or nil for nothing.
    case returned(String?)
    /// Shell exit 2, AppleScript error 502: the extension asks for its settings to be looked at.
    case needsSettings
    /// ONB-5: the script was not allowed to control the app it talks to.
    case automationDenied
    /// Anything else that is not the end: an error, a non-zero exit, a script that will not compile.
    case failed
    /// It was stopped. Whatever it had done by then stays done (RUN-3e).
    case stopped
}

/// One script in flight: something to wait for and something to stop.
public protocol ScriptRun: CancellableWork {
    func result() async -> ScriptResult
}

/// Everything a shell script is run with.
public struct ShellScriptJob: Sendable {
    public var action: ShellScriptAction
    /// The package folder. A script file is found inside it and every script runs in it. Nil for a
    /// snippet with nowhere of its own, which runs in a private temporary folder.
    public var directory: URL?
    public var variables: ScriptVariables

    public init(action: ShellScriptAction, directory: URL?, variables: ScriptVariables) {
        self.action = action
        self.directory = directory
        self.variables = variables
    }
}

/// Starts shell scripts (§8.4). A seam so that the runner's tests do not start processes; the
/// system one's own tests do.
public protocol ShellScriptRunning: Sendable {
    /// - Returns: Nil when it could not be started: its file is missing or outside its package, its
    ///   interpreter cannot be found, or the process would not launch.
    func start(_ job: ShellScriptJob) async -> (any ScriptRun)?
}

/// Runs AppleScripts, which in the app means asking the Runner (§8.4, architecture §9.5).
public protocol AppleScriptRunning: Sendable {
    func start(_ job: AppleScriptRunRequest) async -> (any ScriptRun)?
}

/// Performs Services, which in the app means asking the Runner (§8.4).
public protocol ServiceRunning: Sendable {
    func start(service name: String, text: String) async -> (any ScriptRun)?
}

/// An AppleScript, resolved: the source or file, and the handler's arguments already looked up.
public struct AppleScriptRunRequest: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case text(String)
        case file(URL)
    }

    public var source: Source
    public var handler: String?
    public var arguments: [String]

    public init(source: Source, handler: String? = nil, arguments: [String] = []) {
        self.source = source
        self.handler = handler
        self.arguments = arguments
    }
}

/// A file named by a manifest, found inside its package — and only there.
///
/// Symbolic links are resolved before the check, so `../../` and a link out of the package are
/// both refused. Staging already refuses a package with a link in it (§9.4); this is the same
/// rule held where the file is used, for a folder that changed after it was installed.
enum PackageFile {
    static func resolve(_ relative: String, in directory: URL) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}

/// Runs shell scripts as child processes (§8.4, §8.7, RUN-3d).
///
/// **The environment is small on purpose.** A script gets `HOME`, `USER`, `LOGNAME`, `SHELL`,
/// `TMPDIR`, a UTF-8 `LANG`, the system's `PATH`, and §8.7's variables — not the app's own
/// environment, which is nobody's business but the app's. The login shell of `shellMode: login`
/// then adds whatever the user's own shell files add, which is how `python3` from Homebrew is found.
///
/// **Output.** Standard output is the result, less one line break at its end: a script that prints
/// its answer with `echo` or `print` means the answer, not the answer and a new line, and a result
/// pasted over a word should not push the rest of the line down. Anything more is the script's.
///
/// **Cancelling** is `ChildProcess`'s: the script's whole process group is sent SIGTERM and then
/// SIGKILL. The script ran on our behalf and nothing else was asked to do anything, so it is `owned`,
/// and a stopped script has stopped.
public struct SystemShellScriptRunner: ShellScriptRunning {
    public init() {}

    public func start(_ job: ShellScriptJob) async -> (any ScriptRun)? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pappuclip-script-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let script: URL
            var inline: String?
            switch job.action.source {
            case .inline(let text):
                script = scratch.appendingPathComponent("script")
                try Data(text.utf8).write(to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                inline = text
            case .file(let relative):
                guard let directory = job.directory, let found = PackageFile.resolve(relative, in: directory) else {
                    try? FileManager.default.removeItem(at: scratch)
                    return nil
                }
                script = found
            }
            let invocation = try ShellInvocation.plan(
                job.action,
                script: script.path,
                inlineSource: inline,
                userShell: Self.userShell,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
            )
            let input = job.action.stdin.flatMap(job.variables.value(named:)).map { Data($0.utf8) }
            let process = try ChildProcess(ChildProcess.Launch(
                executable: URL(fileURLWithPath: invocation.executable),
                arguments: invocation.arguments,
                environment: Self.environment(scratch: scratch).merging(job.variables.environment) { _, script in script },
                workingDirectory: job.directory ?? scratch,
                standardInput: input
            ))
            return Run(process: process, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
    }

    static var userShell: String? {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    static func environment(scratch: URL) -> [String: String] {
        let system = ProcessInfo.processInfo.environment
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TMPDIR": scratch.path,
            "SHELL": userShell ?? ShellInvocation.fallbackShell,
        ]
        for key in ["HOME", "USER", "LOGNAME"] {
            if let value = system[key] { environment[key] = value }
        }
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        return environment
    }

    /// The result, as `after` wants it.
    static func output(_ data: Data) -> String? {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r\n") {
            text.removeLast(2)
        } else if text.hasSuffix("\n") {
            text.removeLast()
        }
        return text.isEmpty ? nil : text
    }

    private struct Run: ScriptRun {
        let process: ChildProcess
        let scratch: URL

        var ownership: WorkOwnership { process.ownership }

        func cancel() async -> WorkCancellation {
            await process.cancel()
        }

        func result() async -> ScriptResult {
            let ended = await process.result()
            defer { try? FileManager.default.removeItem(at: scratch) }
            if ended.cancelled { return .stopped }
            return switch ScriptExit(status: ended.status, signalled: ended.signalled) {
            case .succeeded: .returned(SystemShellScriptRunner.output(ended.standardOutput))
            case .needsSettings: .needsSettings
            case .failed: .failed
            }
        }
    }
}
