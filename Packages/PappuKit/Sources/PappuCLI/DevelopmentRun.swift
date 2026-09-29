import Foundation
import PappuCore
import PappuJSBridge
import PappuJSHost
import PappuRuntime
import Synchronization

/// DEV-2: `pappuclip run <file> [function]` (architecture §10.8).
///
/// The file is run by the helper's own code — `JSHost`, in this process rather than over XPC — so a
/// script behaves here as it does in the app: the same globals, the same `require`, the same
/// TypeScript. Its host calls are answered by `HeadlessHost`, which applies the app's refusals and
/// performs nothing.
///
/// **What runs.** A module (a file with `export`, `module.exports` or `defineExtension`) has the
/// exported function named `function` called, by default `test`, as PopClip calls an action's code:
/// `test(input, options, context)`. A file with none of those is an action script and is run as one.
/// Either way, the files around it are loaded as the package it belongs to, so a `require('./lib')`
/// works as it would installed.
///
/// **What it answers.** Exit 0 when the function returns or its promise resolves, 1 when it throws or
/// rejects, the file will not load, the function is not there, or the run outlives its timeout.
public struct DevelopmentRun: Sendable {
    public struct Request: Sendable {
        public var file: URL
        /// The export to call. Nil for `test` in a module, or the whole file for a script.
        public var function: String?
        /// Run the file as an action script even if it looks like a module.
        public var asScript: Bool
        /// `popclip.input.text`.
        public var text: String
        public var options: [String: String]
        public var gates: Set<GatedCapability>
        public var clipboard: String?
        public var timeout: Duration

        public init(
            file: URL,
            function: String? = nil,
            asScript: Bool = false,
            text: String = "Hello, world.",
            options: [String: String] = [:],
            gates: Set<GatedCapability> = [],
            clipboard: String? = nil,
            timeout: Duration = .seconds(30)
        ) {
            self.file = file
            self.function = function
            self.asScript = asScript
            self.text = text
            self.options = options
            self.gates = gates
            self.clipboard = clipboard
            self.timeout = timeout
        }
    }

    public enum Ending: Sendable, Equatable {
        /// It returned, with a string or nil.
        case returned(String?)
        /// It threw, or its promise rejected.
        case threw(String)
        /// It never started: the file, the package or the export was not there, or would not compile.
        case notRun(String)
        /// It was still running at the timeout, and was stopped.
        case timedOut
    }

    public struct Outcome: Sendable, Equatable {
        public var ending: Ending
        /// What it printed, in order.
        public var log: [String]
        /// What it asked of the app, in order.
        public var calls: [HeadlessHost.Call]

        public init(ending: Ending, log: [String], calls: [HeadlessHost.Call]) {
            self.ending = ending
            self.log = log
            self.calls = calls
        }

        public var exitCode: Int32 {
            if case .returned = ending { return 0 }
            return 1
        }
    }

    /// The export run when none is named.
    public static let defaultFunction = "test"

    public init() {}

    /// Whether `source` is a module rather than an action script: it exports something. The helper's own
    /// test for ES module syntax, and CommonJS's and AMD's spellings as statements.
    public static func looksLikeModule(_ source: String) -> Bool {
        let esm = #/(?m)^[ \t]*(?:import(?:[ \t]+[\w$*'"{]|[ \t]*[{*'"])|export(?:[ \t]+[\w$]|[ \t]*[{*]))/#
        // CommonJS and AMD, as a statement of their own at the start of a line: `typeof exports` in a
        // script that looks at its environment is not an export.
        let commonJS = #/(?m)(?:^|;)[ \t]*(?:module\.exports\b|exports\.[\w$]+[ \t]*=|exports\[|(?:define|defineExtension(?:[ \t]*<[^()\n]*>)?)[ \t]*\()/#
        return source.contains(esm) || source.contains(commonJS)
    }

    /// The package `file` belongs to: the nearest folder above it that is a package, or its own folder.
    public static func packageRoot(of file: URL) -> URL {
        let packageExtensions = Set(ProductIdentity.FileExtension.package)
        var folder = file.deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            if packageExtensions.contains(folder.pathExtension.lowercased()) { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return file.deletingLastPathComponent()
    }

    public func run(_ request: Request) async -> Outcome {
        let log = LogLines()
        let host = HeadlessHost(gates: request.gates, clipboard: request.clipboard)
        let finish = { (ending: Ending) in Outcome(ending: ending, log: log.lines, calls: host.recorded) }

        let file = request.file.standardizedFileURL
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            return finish(.notRun("Cannot read \(request.file.path)."))
        }
        let root = Self.packageRoot(of: file).standardizedFileURL
        guard case .success(var files) = PackageSources.read(root) else {
            return finish(.notRun("Cannot read the package at \(root.path)."))
        }
        let relative = file.path.hasPrefix(root.path + "/") ? String(file.path.dropFirst(root.path.count + 1)) : file.lastPathComponent
        files[relative] = source

        let jsHost = JSHost(qos: .userInitiated, call: host.serve) { _, line in log.append(line) }
        let name = "pappuclip-run"
        switch await ask(jsHost, .load(JSLoad(extensionName: name, generation: "1", files: files))) {
        case .loaded: break
        case .loadFailed(let why): return finish(.notRun(why))
        case let other: return finish(.notRun("The package did not load: \(other)."))
        }

        let isModule = !request.asScript && (request.function != nil || Self.looksLikeModule(source))
        let invoke = JSInvoke(
            invocation: 1,
            extensionName: name,
            generation: "1",
            entry: .file(relative),
            input: JSInput(text: request.text, matchedText: request.text),
            context: JSSelectionContext(),
            options: request.options,
            typeScript: file.pathExtension.lowercased() == "ts",
            export: isModule ? (request.function ?? Self.defaultFunction) : nil
        )
        let reply = await ask(jsHost, .invoke(invoke), within: request.timeout)
        guard let reply else {
            _ = await ask(jsHost, .drop(invocation: 1))
            return finish(.timedOut)
        }
        _ = await ask(jsHost, .unload(extension: name))
        switch reply {
        case .returned(let value): return finish(.returned(value))
        case .threw(let why):
            if why.hasPrefix("The module has no action at ") {
                return finish(.notRun("The module exports no function \(invoke.export ?? "")."))
            }
            return finish(.threw(why))
        case let other: return finish(.notRun("The helper answered \(other)."))
        }
    }
}

/// Asks the in-process helper one thing and waits for its answer.
func ask(_ host: JSHost, _ request: JSHostRequest) async -> JSHostReply {
    await withCheckedContinuation { continuation in
        host.handle(request) { continuation.resume(returning: $0) }
    }
}

/// Asks, and gives up at `timeout`: nil then, and the answer, when it comes, is dropped.
func ask(_ host: JSHost, _ request: JSHostRequest, within timeout: Duration) async -> JSHostReply? {
    await withCheckedContinuation { (continuation: CheckedContinuation<JSHostReply?, Never>) in
        let answered = Mutex(false)
        let settle: @Sendable (JSHostReply?) -> Void = { reply in
            let first = answered.withLock { answered in
                defer { answered = true }
                return !answered
            }
            if first { continuation.resume(returning: reply) }
        }
        host.handle(request) { settle($0) }
        Task {
            try? await Task.sleep(for: timeout)
            settle(nil)
        }
    }
}

/// Lines printed by a script, from whichever queue printed them.
final class LogLines: Sendable {
    private let stored = Mutex<[String]>([])
    var lines: [String] { stored.withLock { $0 } }
    func append(_ line: String) { stored.withLock { $0.append(line) } }
}
