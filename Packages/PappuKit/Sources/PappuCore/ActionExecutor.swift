import Foundation

/// What a built-in action does, natively (PRD §7.4, architecture §19 item 2).
///
/// **Why this enumeration exists at all.** Principle 5 of the PRD says built-ins are extensions, and
/// they are: each one ships as a manifest in `Resources/BuiltinExtensions/`, and each can be disabled,
/// renamed, re-iconed, moved, duplicated and restored like any other. But the five P0 ones ship in M1
/// and the public API that could express them — JavaScript — arrives in M3. The decision recorded in
/// architecture §19 item 2 is to give them a **reserved executor** rather than to special-case them
/// above the extension model: they are ordinary manifests whose `executor` names something only the
/// app bundle is allowed to name. M3 and M4 move each one to the public API where the API can say it,
/// and any that cannot stay here and are documented.
///
/// The list is closed and short on purpose. Every case is a native implementation somebody has to
/// write and keep, so a case that is easy to add is the wrong shape. The three P1 built-ins —
/// Dictionary, Reveal in Finder and Spelling — are not here because they are M4; they join this list
/// when they are written, not before.
public enum BuiltinAction: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Cut the selection (PRD §7.4). ⇧ cuts as plain text.
    case cut
    /// Copy the selection. ⇧ copies as plain text.
    case copy
    /// Paste over the selection. ⇧ pastes as plain text.
    case paste
    /// Search for the selection with the chosen engine. ⇧ opens a background tab, ⌥ quotes the term.
    case search
    /// Open the addresses in the selection. ⇧ opens background tabs, ⌥ copies them as a list.
    case openLink = "open-link"
}

/// How an action runs (§8.4, architecture §9.5).
///
/// **Every type the parser reads, and a separate answer to which ones run.** In M1 this enumeration had
/// one case, on the rule that a case with no executor behind it is a promise the code does not keep.
/// M2's parser has to be able to *read* all seven types before the executors behind them exist —
/// week 1 loads the corpus, weeks 3 and 4 write the executors — so the rule moves to where it can be
/// kept: `ActionResolver` offers an action only if this build can run its executor, and says so in its
/// refusal otherwise. A manifest that names a type is read faithfully; a bar never shows a button that
/// does nothing.
///
/// The payloads hold what the manifest said, checked for shape and not yet for meaning: a key combo is
/// the author's string until the Key Press executor parses it (M2 week 3), and a file path is relative
/// to the package until the executor resolves it inside it.
public enum ActionExecutor: Sendable, Equatable, Hashable {
    /// Reserved. Only a manifest from the app's own bundle may name it (`ManifestOrigin.appBundle`).
    case builtin(BuiltinAction)
    case url(URLAction)
    case keyPress(KeyPressAction)
    case service(ServiceAction)
    case shortcut(ShortcutAction)
    case appleScript(AppleScriptAction)
    case shellScript(ShellScriptAction)
    /// P1, M3. An inline or file script; module extensions have no per-action executor until the
    /// runtime has run the module (`ExtensionManifest.module`).
    case javaScript(JavaScriptAction)

    /// The type alone, for the question "can this build run it".
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case builtin, url, keyPress, service, shortcut, appleScript, shellScript, javaScript
    }

    public var kind: Kind {
        switch self {
        case .builtin: .builtin
        case .url: .url
        case .keyPress: .keyPress
        case .service: .service
        case .shortcut: .shortcut
        case .appleScript: .appleScript
        case .shellScript: .shellScript
        case .javaScript: .javaScript
        }
    }
}

/// §8.4 URL.
public struct URLAction: Sendable, Equatable, Hashable, Codable {
    /// With `{popclip text}`, `***` or `{popclip option <id>}` placeholders, expanded at run time.
    public var template: String
    public var cleanQuery: Bool
    public var spacesAsPlus: Bool

    public init(template: String, cleanQuery: Bool = false, spacesAsPlus: Bool = false) {
        self.template = template
        self.cleanQuery = cleanQuery
        self.spacesAsPlus = spacesAsPlus
    }
}

/// §8.4 Key Press.
public struct KeyPressAction: Sendable, Equatable, Hashable, Codable {
    public enum Step: Sendable, Equatable, Hashable, Codable {
        /// `<modifiers> <key>`, as written. Parsed by the executor (M2 week 3).
        case combo(String)
        /// The older dictionary form PopClip still reads: a key code or a character, and a modifier
        /// mask. Two corpus packages use it.
        case legacyCombo(keyCode: Int?, keyCharacter: String?, modifiers: Int)
        /// `wait <ms>` between combos in `keyCombos`.
        case wait(milliseconds: Int)
    }

    /// `keyComboTarget`.
    public enum Target: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case session, app, hid
    }

    public var steps: [Step]
    /// Nil when the manifest names none; the executor chooses PopClip's default.
    public var target: Target?

    public init(steps: [Step], target: Target? = nil) {
        self.steps = steps
        self.target = target
    }
}

/// §8.4 Service: the macOS Service's menu name.
public struct ServiceAction: Sendable, Equatable, Hashable, Codable {
    public var name: String

    public init(name: String) { self.name = name }
}

/// §8.4 Shortcut: the shortcut's name in the Shortcuts app.
public struct ShortcutAction: Sendable, Equatable, Hashable, Codable {
    public var name: String

    public init(name: String) { self.name = name }
}

/// Where a script's source is: in the manifest, or in a file in the package.
public enum ScriptSource: Sendable, Equatable, Hashable, Codable {
    case inline(String)
    /// Relative to the package root. Checked to exist at load; resolved inside the package at run time.
    case file(String)
}

/// §8.4 AppleScript.
public struct AppleScriptAction: Sendable, Equatable, Hashable, Codable {
    /// `appleScriptCall`: a handler in a compiled or file script, and the names of the values passed
    /// to it (`popclip text`, `popclip option <id>` and so on).
    public struct Call: Sendable, Equatable, Hashable, Codable {
        public var handler: String
        public var parameters: [String]

        public init(handler: String, parameters: [String] = []) {
            self.handler = handler
            self.parameters = parameters
        }
    }

    public var source: ScriptSource
    public var call: Call?

    public init(source: ScriptSource, call: Call? = nil) {
        self.source = source
        self.call = call
    }
}

/// §8.4 Shell Script.
public struct ShellScriptAction: Sendable, Equatable, Hashable, Codable {
    /// `shellMode`.
    public enum Mode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case login, nonlogin, none
    }

    public var source: ScriptSource
    /// Nil when the manifest names none; §8.4's file-execution rules decide at run time.
    public var interpreter: String?
    /// Which value goes to standard input (`text` in every corpus use).
    public var stdin: String?
    /// Nil means the default, `login`.
    public var mode: Mode?

    public init(source: ScriptSource, interpreter: String? = nil, stdin: String? = nil, mode: Mode? = nil) {
        self.source = source
        self.interpreter = interpreter
        self.stdin = stdin
        self.mode = mode
    }
}

/// §8.4 JavaScript / TypeScript: an action's own script (§8.8), or one of a module's actions (JS-12).
public struct JavaScriptAction: Sendable, Equatable, Hashable, Codable {
    /// The script, or for a module's action the module (`ModuleSource.source`).
    public var source: ScriptSource
    /// TypeScript is transpiled without type checking (JS-14).
    public var isTypeScript: Bool
    /// JS-12: where the action's code is in what the module exported: `action`, or `actions.3`. Nil
    /// for a script. Set only by `ManifestBuilder` from what the helper described, never read from a
    /// config.
    public var export: String?

    public init(source: ScriptSource, isTypeScript: Bool = false, export: String? = nil) {
        self.source = source
        self.isTypeScript = isTypeScript
        self.export = export
    }
}

/// Where a manifest came from, which is the whole of what makes the reserved executor safe.
///
/// This is not the extension-identity model — that is `Provenance` in M2 (SEC-8), with digests and
/// publisher records. It is the one distinction the reserved executor turns on, and it is separate
/// so that the check cannot be written as "the identifier starts with ours": an identifier is a
/// string in a file somebody else can also write.
public enum ManifestOrigin: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Shipped inside the application, and therefore covered by the app's own signature.
    case appBundle
    /// Everything else: installed from a file, a snippet, the registry or a development folder.
    case installed
}

extension ActionExecutor: Codable {
    /// `{"builtin": "copy"}`, `{"url": {...}}`: one key naming the type, holding its payload.
    private enum CodingKeys: String, CodingKey {
        case builtin, url, keyPress, service, shortcut, appleScript, shellScript, javaScript
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "An executor names exactly one type.")
            )
        }
        switch key {
        case .builtin: self = .builtin(try container.decode(BuiltinAction.self, forKey: key))
        case .url: self = .url(try container.decode(URLAction.self, forKey: key))
        case .keyPress: self = .keyPress(try container.decode(KeyPressAction.self, forKey: key))
        case .service: self = .service(try container.decode(ServiceAction.self, forKey: key))
        case .shortcut: self = .shortcut(try container.decode(ShortcutAction.self, forKey: key))
        case .appleScript: self = .appleScript(try container.decode(AppleScriptAction.self, forKey: key))
        case .shellScript: self = .shellScript(try container.decode(ShellScriptAction.self, forKey: key))
        case .javaScript: self = .javaScript(try container.decode(JavaScriptAction.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let action): try container.encode(action, forKey: .builtin)
        case .url(let action): try container.encode(action, forKey: .url)
        case .keyPress(let action): try container.encode(action, forKey: .keyPress)
        case .service(let action): try container.encode(action, forKey: .service)
        case .shortcut(let action): try container.encode(action, forKey: .shortcut)
        case .appleScript(let action): try container.encode(action, forKey: .appleScript)
        case .shellScript(let action): try container.encode(action, forKey: .shellScript)
        case .javaScript(let action): try container.encode(action, forKey: .javaScript)
        }
    }
}
