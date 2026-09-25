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
    /// JS-12: run a module extension's module and say what it exported. Sent, like `invoke`, only for an
    /// extension that is loaded, which is only ever one with an `ExecutionApproval`.
    case describe(JSDescribe)
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

        /// The file's path, for a message. Nil for inline text.
        public var path: String? {
            if case .file(let path) = self { return path }
            return nil
        }
    }

    public var invocation: UInt64
    public var extensionName: String
    public var generation: String
    public var entry: Entry
    public var input: JSInput
    /// `popclip.context` (JS-3).
    public var context: JSSelectionContext
    /// `popclip.modifiers` (JS-3).
    public var modifiers: JSModifiers
    /// The extension's option values, by option id (§8.9), as the rest of the app keeps them: a boolean
    /// is `1` or `0`.
    public var options: [String: String]
    /// The options among `options` that are booleans, which a script reads as `true` and `false`.
    public var booleanOptions: [String]
    /// The script is TypeScript, which the helper transpiles before running it (JS-14).
    public var typeScript: Bool
    /// JS-12: the entry is a module, and this is where in what it exported the action's code is
    /// (`action`, `actions.3`). Nil for a script.
    public var export: String?

    public init(
        invocation: UInt64,
        extensionName: String,
        generation: String,
        entry: Entry,
        input: JSInput,
        context: JSSelectionContext = JSSelectionContext(),
        modifiers: JSModifiers = JSModifiers(),
        options: [String: String] = [:],
        booleanOptions: [String] = [],
        typeScript: Bool = false,
        export: String? = nil
    ) {
        self.invocation = invocation
        self.extensionName = extensionName
        self.generation = generation
        self.entry = entry
        self.input = input
        self.context = context
        self.modifiers = modifiers
        self.options = options
        self.booleanOptions = booleanOptions
        self.typeScript = typeScript
        self.export = export
    }
}

/// JS-12: a module extension's module, to be run and described.
public struct JSDescribe: Codable, Sendable, Equatable {
    public var extensionName: String
    public var generation: String
    /// The module: a file among those sent with `load`, or a snippet's own text.
    public var entry: JSInvoke.Entry
    public var typeScript: Bool

    public init(extensionName: String, generation: String, entry: JSInvoke.Entry, typeScript: Bool) {
        self.extensionName = extensionName
        self.generation = generation
        self.entry = entry
        self.typeScript = typeScript
    }
}

/// JS-12: what a module exported, as data.
public struct JSModuleDescription: Codable, Sendable, Equatable {
    /// The exported extension object as JSON, with every function taken out. An action whose code is a
    /// function has `"code": true`, which nothing else can produce.
    public var exports: String
    /// The top-level keys whose value is a function: `actions` or `submenu` as a population function,
    /// `auth`, `test`, and any a module exports for itself.
    public var functions: [String]

    public init(exports: String, functions: [String]) {
        self.exports = exports
        self.functions = functions
    }
}

/// `popclip.input` (JS-3).
public struct JSInput: Codable, Sendable, Equatable {
    /// The pasteboard type a script reads plain text under, in `content` and everywhere else.
    public static let plainTextType = "public.utf8-plain-text"
    public static let htmlType = "public.html"
    public static let rtfType = "public.rtf"

    /// The whole selection.
    public var text: String
    /// The part of it the action's regex or requirement matched, which is the whole of it when nothing
    /// narrowed it.
    public var matchedText: String
    /// The action's regex match: the whole match, then each capture group, nil for a group that took
    /// no part. Nil when the action has no regex.
    public var regexResult: [String?]?
    /// FLT-4: the selection as HTML, sanitised, and as XHTML and Markdown made from it. Empty unless
    /// the action asked for them (`captureHtml`) and they could be captured.
    public var html: String
    public var xhtml: String
    public var markdown: String
    /// FLT-4: the selection as RTF, when the action asked (`captureRtf`).
    public var rtf: String
    /// The selection by pasteboard type: plain text always, HTML and RTF when captured.
    public var content: [String: String]
    /// The selection is one address and nothing else.
    public var isURL: Bool
    /// What analysis found in the selection, each with where it was.
    public var data: JSDetected

    public init(
        text: String,
        matchedText: String,
        regexResult: [String?]? = nil,
        html: String = "",
        xhtml: String = "",
        markdown: String = "",
        rtf: String = "",
        content: [String: String]? = nil,
        isURL: Bool = false,
        data: JSDetected = JSDetected()
    ) {
        self.text = text
        self.matchedText = matchedText
        self.regexResult = regexResult
        self.html = html
        self.xhtml = xhtml
        self.markdown = markdown
        self.rtf = rtf
        self.content = content ?? [Self.plainTextType: text]
        self.isURL = isURL
        self.data = data
    }
}

/// `popclip.input.data`: each kind of thing analysis detects, in the order they appear.
public struct JSDetected: Codable, Sendable, Equatable {
    /// `http` and `https` addresses.
    public var urls: [JSRangedString]
    /// Addresses with another scheme from the allowed list.
    public var nonHTTPURLs: [JSRangedString]
    public var emails: [JSRangedString]
    /// Paths that exist on disk.
    public var paths: [JSRangedString]

    public init(
        urls: [JSRangedString] = [],
        nonHTTPURLs: [JSRangedString] = [],
        emails: [JSRangedString] = [],
        paths: [JSRangedString] = []
    ) {
        self.urls = urls
        self.nonHTTPURLs = nonHTTPURLs
        self.emails = emails
        self.paths = paths
    }
}

/// One detection: its value, and where in `JSInput.text` it was, in UTF-16 code units as a script
/// counts them.
public struct JSRangedString: Codable, Sendable, Equatable {
    public var value: String
    public var location: Int
    public var length: Int

    public init(value: String, location: Int, length: Int) {
        self.value = value
        self.location = location
        self.length = length
    }
}

/// `popclip.context` (JS-3). Named for the selection because `JSContext` is JavaScriptCore's.
public struct JSSelectionContext: Codable, Sendable, Equatable {
    /// The control can hold formatting.
    public var hasFormatting: Bool
    public var canPaste: Bool
    public var canCopy: Bool
    public var canCut: Bool
    /// The page, when the app is a browser that said. Empty otherwise.
    public var browserURL: String
    public var browserTitle: String
    public var appName: String
    public var appIdentifier: String

    public init(
        hasFormatting: Bool = false,
        canPaste: Bool = false,
        canCopy: Bool = false,
        canCut: Bool = false,
        browserURL: String = "",
        browserTitle: String = "",
        appName: String = "",
        appIdentifier: String = ""
    ) {
        self.hasFormatting = hasFormatting
        self.canPaste = canPaste
        self.canCopy = canCopy
        self.canCut = canCut
        self.browserURL = browserURL
        self.browserTitle = browserTitle
        self.appName = appName
        self.appIdentifier = appIdentifier
    }
}

/// `popclip.modifiers` (JS-3): the keys held when the action was clicked.
public struct JSModifiers: Codable, Sendable, Equatable {
    public var shift: Bool
    public var control: Bool
    public var option: Bool
    public var command: Bool

    public init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.shift = shift
        self.control = control
        self.option = option
        self.command = command
    }
}

/// Helper → app: something a script asked the host for (architecture §10.2, §10.4). Every `popclip`
/// method, `pasteboard`, `RichString`, and the dictionary and spelling lookups in `util` arrive as one
/// of these; the rest of `util` is worked out in the helper and never crosses (§10.2).
///
/// **The helper says whose it is, the script says what.** `invocation` and `extensionName` are
/// filled in by the helper's own code from the world the script runs in, so a script cannot name
/// another extension's run; `method` and `arguments` are what the script asked, and the app checks
/// both before it does anything (SEC-7b).
public struct JSHostCall: Codable, Sendable, Equatable {
    /// The `JSInvoke.invocation` the script is running for.
    public var invocation: UInt64
    /// The extension's local identity, as `JSLoad.extensionName`.
    public var extensionName: String
    /// What is asked, by name: `pasteText`, `pasteboard.read` and the rest. A name the app does not
    /// know is refused.
    public var method: String
    /// The arguments, as one JSON object shaped for `method`.
    public var arguments: String

    public init(invocation: UInt64, extensionName: String, method: String, arguments: String = "{}") {
        self.invocation = invocation
        self.extensionName = extensionName
        self.method = method
        self.arguments = arguments
    }
}

/// The app's answer to a `JSHostCall`.
public enum JSHostAnswer: Codable, Sendable, Equatable {
    /// Done, and nothing to say: the promise resolves to `undefined`.
    case done
    /// Done, and this is the answer, as JSON.
    case value(String)
    /// Not allowed: the run is over, or the grants do not cover it (SEC-7b), or the arguments are not
    /// what the method takes. The promise rejects, or the call throws, with this message.
    case refused(String)
    /// Allowed and tried, and it did not work. The promise rejects with this message.
    case failed(String)
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
    /// JS-12: what the module exported. A module that would not load or describe is `threw`.
    case described(JSModuleDescription)
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
