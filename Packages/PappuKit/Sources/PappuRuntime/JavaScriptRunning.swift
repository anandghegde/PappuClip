import Foundation
import PappuCore

/// Everything one JavaScript action is run with (§8.8).
public struct JavaScriptRunRequest: Sendable, Equatable {
    /// The installed extension, as its local identity's text: which world in the helper this runs in.
    public var owner: String
    /// The approved bytes' digest. A world built from other bytes is not used (SEC-8c).
    public var generation: String
    /// The extension's name, for the Debug Console.
    public var extensionName: String
    /// The package folder, whose script files the helper is sent.
    public var directory: URL
    public var action: JavaScriptAction
    /// `popclip.input.text`: the whole selection.
    public var text: String
    /// `popclip.input.matchedText`.
    public var matchedText: String
    public var options: [String: String]

    public init(
        owner: String,
        generation: String,
        extensionName: String,
        directory: URL,
        action: JavaScriptAction,
        text: String,
        matchedText: String,
        options: [String: String] = [:]
    ) {
        self.owner = owner
        self.generation = generation
        self.extensionName = extensionName
        self.directory = directory
        self.action = action
        self.text = text
        self.matchedText = matchedText
        self.options = options
    }
}

/// Runs JavaScript actions, which in the app means asking the JavaScript helper (architecture §10).
public protocol JavaScriptRunning: Sendable {
    /// - Returns: Nil when it could not be started: the extension is suspended, its package would
    ///   not read, or the helper would not load it.
    func start(_ job: JavaScriptRunRequest) async -> (any ScriptRun)?
}

/// For a runner assembled without a JavaScript helper: every action fails to start.
public struct NoJavaScript: JavaScriptRunning {
    public init() {}

    public func start(_ job: JavaScriptRunRequest) async -> (any ScriptRun)? { nil }
}

/// JS-11: a script that throws one of these wants its settings looked at.
enum JavaScriptFailure {
    static let settingsPrefixes = ["settings error", "not signed in"]

    static func result(forThrown message: String) -> ScriptResult {
        let lowered = message.lowercased()
        return settingsPrefixes.contains(where: lowered.hasPrefix) ? .needsSettings : .failed
    }
}

/// The files a package's scripts may `require`, read for sending to the helper (JS-10).
///
/// The helper cannot read the package itself — it has no file access at all (SEC-1a) — so it is sent
/// the text of every script and JSON file, and nothing else: JavaScript in its CommonJS and module
/// spellings, TypeScript, which the helper transpiles (JS-14), and JSON. A file reached through a link
/// out of the package is not sent, and nor is anything past the limits: a package this large is not
/// one the helper should be asked to hold.
enum PackageSources {
    static let extensions: Set<String> = ["js", "cjs", "mjs", "ts", "json"]
    static let fileLimit = 1 << 20
    static let totalLimit = 8 << 20
    static let countLimit = 2_000

    enum Failure: Error, Equatable {
        case unreadable
        case tooLarge
    }

    static func read(_ directory: URL) -> Result<[String: String], Failure> {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return .failure(.unreadable) }
        var files: [String: String] = [:]
        var total = 0
        for case let url as URL in walker {
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            let file = url.resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(prefix) else { continue }
            let size = values.fileSize ?? 0
            total += size
            guard size <= fileLimit, total <= totalLimit, files.count < countLimit else { return .failure(.tooLarge) }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            files[String(file.path.dropFirst(prefix.count))] = text
        }
        return .success(files)
    }
}
