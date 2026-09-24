import Foundation

/// What the app and `PappuClipJSHost.xpc` say to each other (architecture §10.2).
///
/// The helper is told values, never where they came from: an extension arrives as a name, a
/// generation and the text of its files, never as a path it could open — it could not open one
/// anyway, being sandboxed with nothing granted (SEC-1a) — and an invocation arrives as the script
/// and the strings it runs with. The app decides what may run; the helper runs what it is sent, and
/// the only thing it keeps between messages is one JavaScript world per extension (SEC-1b).
public enum JSHostService {
    /// The service's bundle identifier, which is the name launchd knows it by.
    public static let name = "app.pappuclip.PappuClip.JSHost"
}

public enum JSHostRequest: Codable, Sendable, Equatable {
    /// Who are you: the process identifier, which is what a cancel that is not heeded kills.
    case identify
    /// Makes a fresh world for an extension, replacing any it had, with these files to `require` from.
    case load(JSLoad)
    case invoke(JSInvoke)
    /// Stop waiting for this invocation. Its reply is `dropped`, and anything it settles to afterwards
    /// is thrown away.
    case drop(invocation: UInt64)
    /// Forget an extension's world: its globals, its module cache, its virtual machine.
    case unload(extension: String)
}

/// One extension's code, as the helper is allowed to see it.
public struct JSLoad: Codable, Sendable, Equatable {
    /// The extension's local identity, as text. What the helper keys its worlds by.
    public var extensionName: String
    /// Which bytes these are: the approved digest. An `invoke` for a different generation is answered
    /// `notLoaded`, so a world built from yesterday's files never runs today's action.
    public var generation: String
    /// Every script and JSON file in the package, by path relative to its root: JavaScript, TypeScript
    /// and JSON (`PackageSources`).
    public var files: [String: String]

    public init(extensionName: String, generation: String, files: [String: String]) {
        self.extensionName = extensionName
        self.generation = generation
        self.files = files
    }
}

/// §8.8: an action's script, and what it runs on.
public struct JSInvoke: Codable, Sendable, Equatable {
    public enum Entry: Codable, Sendable, Equatable {
        /// `javascript:` in the manifest.
        case inline(String)
        /// `javascript file:`, relative to the package root, among the files sent in `load`.
        case file(String)
    }

    public var invocation: UInt64
    public var extensionName: String
    public var generation: String
    public var entry: Entry
    public var input: JSInput
    /// The extension's option values, by option id (§8.9).
    public var options: [String: String]
    /// The script is TypeScript, which the helper transpiles before running it (JS-14).
    public var typeScript: Bool

    public init(
        invocation: UInt64,
        extensionName: String,
        generation: String,
        entry: Entry,
        input: JSInput,
        options: [String: String] = [:],
        typeScript: Bool = false
    ) {
        self.invocation = invocation
        self.extensionName = extensionName
        self.generation = generation
        self.entry = entry
        self.input = input
        self.options = options
        self.typeScript = typeScript
    }
}

/// `popclip.input`, as much of it as this build fills in (JS-3).
public struct JSInput: Codable, Sendable, Equatable {
    /// The whole selection.
    public var text: String
    /// The part of it the action's regex or requirement matched, which is the whole of it when nothing
    /// narrowed it.
    public var matchedText: String

    public init(text: String, matchedText: String) {
        self.text = text
        self.matchedText = matchedText
    }
}

public enum JSHostReply: Codable, Sendable, Equatable {
    case identity(processID: Int32)
    case loaded
    /// A file would not compile, or the load itself was malformed. For the Debug Console.
    case loadFailed(String)
    /// No world for this extension at this generation: the helper was restarted, or the extension was
    /// updated. The app loads it and asks again.
    case notLoaded
    /// The script ran to the end. A string it returned, or nil for anything else.
    case returned(String?)
    /// The script threw, or its promise rejected. The message, for the Debug Console and for §8.8's
    /// "settings error" and "not signed in" prefixes.
    case threw(String)
    case dropped
    case unloaded
    case badRequest(String)
}

/// What the helper says without being asked (architecture §10.2), on the session the app opened.
public enum JSHostEvent: Codable, Sendable, Equatable {
    /// `print()` and `console.log()`, one line each (JS-1, DIA-1).
    case log(extensionName: String, line: String)
}
