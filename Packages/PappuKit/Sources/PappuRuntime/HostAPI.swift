import Foundation
import PappuAnalysis
import PappuCore
import PappuJSBridge
import PappuSelection
import Synchronization

/// A host method: something a script asks the app for, by the name the helper sends (JS-4, JS-6, JS-7,
/// architecture §10.2).
///
/// Every `popclip` method that acts is here, and so are the synchronous reads the helper cannot answer
/// itself: the clipboard, the dictionary, the spell checker and rich text, which are the system's. A
/// name that is not here is refused.
public enum HostMethod: String, Sendable, Equatable, CaseIterable {
    case pasteText, pasteContent, copyText, copyContent, performCommand
    case showText, showSuccess, showFailure, showSettings, appear
    case pressKeys, performService, revealFile, openUrl, openTemplateUrl, share
    case pasteboardRead = "pasteboard.read"
    case pasteboardWrite = "pasteboard.write"
    case richTextConvert = "richText.convert"
    case dictionaryDefine = "dictionary.define"
    case spellingLanguages = "spelling.languages"
    case spellingPreferred = "spelling.preferred"
    case spellingCheck = "spelling.check"
    case spellingGuesses = "spelling.guesses"

    /// The gated capability a call needs granted, beyond the approval to run at all (SEC-7b, EXM-5d).
    ///
    /// Pressing keys, performing a Service and sharing reach past the text into the app and the system,
    /// which is what the synthetic-input grant is for. Everything else is what running the extension's
    /// code was already approved to do: read the selection, return, copy and paste it (§S4's
    /// `readsAndReplacesText`).
    public var gate: GatedCapability? {
        switch self {
        case .pressKeys, .performService, .share: .syntheticInput
        default: nil
        }
    }

    /// Whether it puts input into the destination, which needs a `MutationPermit` (RUN-2a).
    public var entersTheDestination: Bool {
        switch self {
        case .pasteText, .pasteContent, .performCommand, .pressKeys: true
        default: false
        }
    }
}

/// Where a host call is being made from (JS-13). A population function may call nothing at all; it has
/// no invocation to act for, and the bar is not yet on screen.
public enum HostPhase: String, Sendable, Equatable {
    case action
    case population
}

/// What a run's host calls asked of the bar, for when the run ends (JS-4). The last request wins, as it
/// does on PopClip's bar.
public struct HostRequests: Sendable, Equatable {
    public enum Display: Sendable, Equatable {
        /// `showSuccess`.
        case success
        /// `showFailure`.
        case failure
        /// `copyText` or `copyContent` with `notify`.
        case copied
        /// `showText`, already cut to §8.6's 160 characters.
        case text(String)
        /// `appear`.
        case appear
    }

    public var display: Display?
    /// `showSettings`.
    public var settings = false

    public init(display: Display? = nil, settings: Bool = false) {
        self.display = display
        self.settings = settings
    }
}

/// One item for `popclip.share`.
public enum HostShareItem: Sendable, Equatable {
    case text(String)
    case rich(source: String, format: RichTextFormat)
    case url(URL)
}

/// What a `RichString` is made from (JS-7).
public enum RichTextFormat: String, Sendable, Equatable, Decodable {
    case rtf, html, markdown
}

/// What the host API needs of the system beyond the clipboard, the destination and the browser. A seam,
/// so the dispatcher is tested without AppKit; `SystemHostServices` is the app's.
public protocol HostServices: Sendable {
    /// Shows the file or folder in the Finder. False when there is nothing there.
    func reveal(_ url: URL) async -> Bool
    /// Nil when it was shared or the user cancelled, else why not.
    func share(_ items: [HostShareItem], with service: String) async -> String?
    /// The dictionary's definition of the whole text, as plain text.
    func definition(of text: String) async -> String?
    /// The spell checker's languages, with names in the user's language.
    func spellingLanguages() async -> [SpellingLanguage]
    func preferredSpellingLanguages() async -> [String]
    /// Nil for a language the spell checker does not have.
    func checkSpelling(_ text: String, language: String) async -> Bool?
    /// Nil for a language the spell checker does not have.
    func spellingGuesses(for text: String, language: String, limit: Int?) async -> [String]?
    /// RTF and HTML for `source`. Nil when it could not be read as `format`.
    func convert(_ source: String, from format: RichTextFormat) async -> RichTextForms?
}

public struct SpellingLanguage: Sendable, Equatable, Encodable {
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public struct RichTextForms: Sendable, Equatable, Encodable {
    public var rtf: String
    public var html: String

    public init(rtf: String, html: String) {
        self.rtf = rtf
        self.html = html
    }
}

/// For a runner assembled without the system's services: nothing is found, and nothing is shared.
public struct NoHostServices: HostServices {
    public init() {}

    public func reveal(_ url: URL) async -> Bool { false }
    public func share(_ items: [HostShareItem], with service: String) async -> String? { "Sharing is not available." }
    public func definition(of text: String) async -> String? { nil }
    public func spellingLanguages() async -> [SpellingLanguage] { [] }
    public func preferredSpellingLanguages() async -> [String] { [] }
    public func checkSpelling(_ text: String, language: String) async -> Bool? { nil }
    public func spellingGuesses(for text: String, language: String, limit: Int?) async -> [String]? { nil }
    public func convert(_ source: String, from format: RichTextFormat) async -> RichTextForms? { nil }
}

/// Every host call one JavaScript run makes, checked and then done (SEC-7b, architecture §10.4).
///
/// **In order, and each check before any effect.** The invocation is still running (RUN-3b) → the call
/// is allowed in this phase, which for a population function is never (JS-13) → the method is one there
/// is → the extension's grants cover it (SEC-7b) → its arguments are what it takes → for input into the
/// destination, a `MutationPermit` from a fresh verification (RUN-2a) → do it. A refusal is `refused`,
/// which rejects the script's promise; the client writes it to the Debug Console by method and reason,
/// and no refusal's words carry what the script passed.
///
/// **One per run.** It is made for one invocation, with the approval's grants as they were when the run
/// began, and it lives as long as the run's host calls can arrive. A cancelled run is one whose calls all
/// fail the first check (JS-15): a promise that resolves after the cancel finds nothing to act for.
///
/// **What it asks of the bar** — `showText`, `showSuccess`, `appear` and the rest — it keeps in
/// `requests`, and `ExtensionRunner` shows it when the run ends.
public final class HostAPIDispatcher: Sendable {
    /// What one run's calls act for.
    public struct Run: Sendable {
        public var invocation: InvocationID
        public var phase: HostPhase
        /// The gated capabilities the extension's approval carries.
        public var gates: Set<GatedCapability>
        public var context: SelectionContext
        public var target: TargetApp
        /// The whole selection, which `performCommand("copy")` copies.
        public var text: String

        public init(
            invocation: InvocationID,
            phase: HostPhase = .action,
            gates: Set<GatedCapability>,
            context: SelectionContext,
            target: TargetApp,
            text: String
        ) {
            self.invocation = invocation
            self.phase = phase
            self.gates = gates
            self.context = context
            self.target = target
            self.text = text
        }
    }

    /// What the calls are done with: the runner's own collaborators, and the system.
    public struct Effects: Sendable {
        public var manager: InvocationManager
        public var mutator: TextMutator
        public var editor: SelectionEditor
        public var presser: KeyPresser
        public var clipboard: any ClipboardKeeping
        public var urls: any URLOpening
        public var services: any ServiceRunning
        public var system: any HostServices

        public init(
            manager: InvocationManager,
            mutator: TextMutator,
            editor: SelectionEditor,
            presser: KeyPresser,
            clipboard: any ClipboardKeeping,
            urls: any URLOpening,
            services: any ServiceRunning,
            system: any HostServices
        ) {
            self.manager = manager
            self.mutator = mutator
            self.editor = editor
            self.presser = presser
            self.clipboard = clipboard
            self.urls = urls
            self.services = services
            self.system = system
        }
    }

    /// The three types a script reads and writes the clipboard as (JS-7).
    static let textTypes = [JSInput.plainTextType, JSInput.htmlType, JSInput.rtfType]

    public let run: Run
    private let effects: Effects
    private let asked = Mutex(HostRequests())

    public init(run: Run, effects: Effects) {
        self.run = run
        self.effects = effects
    }

    /// What the run's calls asked of the bar so far.
    public var requests: HostRequests { asked.withLock { $0 } }

    /// Checks one call and, if it passes, does it.
    public func perform(_ call: JSHostCall) async -> JSHostAnswer {
        let manager = effects.manager
        guard await manager.accepts(run.invocation) else { return .refused("The action is no longer running.") }
        guard run.phase == .action else { return .refused("Nothing may be asked of PappuClip while the bar is being built.") }
        guard let method = HostMethod(rawValue: call.method) else { return .refused("There is no host method \(call.method).") }
        if let gate = method.gate, !run.gates.contains(gate) {
            return .refused("\(method.rawValue) needs the \(gate.rawValue) permission, which this extension does not have.")
        }
        let arguments = Data(call.arguments.utf8)
        do {
            return try await perform(method, arguments)
        } catch is DecodingError {
            return .refused("\(method.rawValue) was not given what it takes.")
        } catch let refusal as Refusal {
            return .refused(refusal.message)
        } catch {
            return .failed("\(method.rawValue) did not work.")
        }
    }

    private struct Refusal: Error {
        var message: String
    }

    // MARK: The methods

    private func perform(_ method: HostMethod, _ arguments: Data) async throws -> JSHostAnswer {
        switch method {
        case .pasteText:
            let given = try decode(Paste<String>.self, arguments)
            return await paste([.text(given.value)], restore: given.restore)
        case .pasteContent:
            let given = try decode(Paste<[String: String]>.self, arguments)
            let content = try representations(given.value)
            return await paste(content, restore: given.restore)
        case .copyText:
            let given = try decode(Copy<String>.self, arguments)
            return await copy([.text(given.value)], notify: given.notify)
        case .copyContent:
            let given = try decode(Copy<[String: String]>.self, arguments)
            let content = try representations(given.value)
            return await copy(content, notify: given.notify)
        case .performCommand:
            let given = try decode(Command.self, arguments)
            return await command(given)
        case .showText:
            let given = try decode(ShowText.self, arguments)
            ask(.text(ExtensionRunner.preview(given.text)))
            return .done
        case .showSuccess:
            ask(.success)
            return .done
        case .showFailure:
            ask(.failure)
            return .done
        case .showSettings:
            asked.withLock { $0.settings = true }
            return .done
        case .appear:
            ask(.appear)
            return .done
        case .pressKeys:
            let given = try decode(PressKeys.self, arguments)
            return await press(given)
        case .performService:
            let given = try decode(Service.self, arguments)
            return await service(given)
        case .revealFile:
            let given = try decode(Reveal.self, arguments)
            return await reveal(given)
        case .openUrl:
            let given = try decode(OpenURL.self, arguments)
            guard let url = Self.openable(given.url) else { throw Refusal(message: "openUrl was not given an address it may open.") }
            return await open(url, app: given.app, activate: given.activate && !given.backgroundTab)
        case .openTemplateUrl:
            let given = try decode(OpenTemplate.self, arguments)
            return await openTemplate(given)
        case .share:
            let given = try decode(Share.self, arguments)
            return await share(given)
        case .pasteboardRead:
            guard let found = await effects.clipboard.content(types: Self.textTypes) else {
                return .failed("The clipboard cannot be read now.")
            }
            var content: [String: String] = [:]
            for (type, data) in found {
                if let text = String(data: data, encoding: .utf8) { content[type] = text }
            }
            return try value(content)
        case .pasteboardWrite:
            let given = try decode(PasteboardWrite.self, arguments)
            let content = try representations(given.content)
            let written = await effects.clipboard.write(content: content, for: run.invocation, into: run.target)
            return written.written ? .done : .failed("The clipboard would not take it.")
        case .richTextConvert:
            let given = try decode(RichText.self, arguments)
            guard let forms = await effects.system.convert(given.source, from: given.format) else {
                return .failed("The text could not be read as \(given.format.rawValue).")
            }
            return try value(forms)
        case .dictionaryDefine:
            let given = try decode(Lookup.self, arguments)
            let definition = await effects.system.definition(of: given.text)
            return try value(definition)
        case .spellingLanguages:
            let languages = await effects.system.spellingLanguages()
            return try value(languages)
        case .spellingPreferred:
            let languages = await effects.system.preferredSpellingLanguages()
            return try value(languages)
        case .spellingCheck:
            let given = try decode(Spelling.self, arguments)
            guard let correct = await effects.system.checkSpelling(given.text, language: given.language) else {
                throw Refusal(message: "The spell checker has no language \(given.language).")
            }
            return try value(correct)
        case .spellingGuesses:
            let given = try decode(Spelling.self, arguments)
            guard let guesses = await effects.system.spellingGuesses(for: given.text, language: given.language, limit: given.limit) else {
                throw Refusal(message: "The spell checker has no language \(given.language).")
            }
            return try value(guesses)
        }
    }

    private func ask(_ display: HostRequests.Display) {
        asked.withLock { $0.display = display }
    }

    /// `pasteText` and `pasteContent`: paste over the verified selection, as `paste-result` does. Where
    /// Paste was not available when the action was clicked, a copy instead, as PopClip does. Unless
    /// `restore`, the value stays on the clipboard afterwards, as PopClip leaves it.
    private func paste(_ content: [PasteboardRepresentation], restore: Bool) async -> JSHostAnswer {
        guard run.context.canPaste else { return await copy(content, notify: true) }
        let verification = await effects.manager.verifyDestination(of: run.invocation)
        switch consume verification {
        case .blocked:
            return .failed("The app the text came from could not be checked, so nothing was pasted.")
        case .verified(let permit):
            let report = await effects.mutator.replaceSelection(content: content, using: permit)
            switch report.outcome {
            case .mutated, .clipboardContested:
                if !restore { _ = await effects.clipboard.write(content: content, for: run.invocation, into: run.target) }
                return .done
            case .notRunning:
                return .refused("The action is no longer running.")
            case .clipboardRefused:
                return .failed("The clipboard could not be used to paste.")
            }
        }
    }

    private func copy(_ content: [PasteboardRepresentation], notify: Bool) async -> JSHostAnswer {
        let written = await effects.clipboard.write(content: content, for: run.invocation, into: run.target)
        guard written.written else { return .failed("The clipboard would not take it.") }
        if notify { ask(.copied) }
        return .done
    }

    /// `performCommand`. Cut and paste are the app's own ⌘X and ⌘V, as the `before` and `after` steps
    /// post them. Copy is the selection PappuClip already read, kept, as the `copy` step does. Paste with
    /// the `plain` transform is ⇧ Paste: the clipboard's plain text through `TextMutator`.
    private func command(_ given: Command) async -> JSHostAnswer {
        if given.command == "copy" {
            return await copy([.text(run.text)], notify: false)
        }
        if given.command == "paste", given.plain {
            guard let text = await effects.clipboard.plainText(), !text.isEmpty else { return .failed("There is no text on the clipboard.") }
            let verification = await effects.manager.verifyDestination(of: run.invocation)
            switch consume verification {
            case .blocked:
                return .failed("The app the text came from could not be checked, so nothing was pasted.")
            case .verified(let permit):
                return switch await effects.mutator.replaceSelection(with: text, using: permit).outcome {
                case .mutated, .clipboardContested: .done
                case .notRunning: .refused("The action is no longer running.")
                case .clipboardRefused: .failed("The clipboard could not be used to paste.")
                }
            }
        }
        let edit: EditCommand
        switch given.command {
        case "cut": edit = .cut
        case "paste": edit = .paste
        default: return .refused("performCommand takes cut, copy or paste.")
        }
        let verification = await effects.manager.verifyDestination(of: run.invocation)
        switch consume verification {
        case .blocked:
            return .failed("The app the text came from could not be checked, so nothing was done.")
        case .verified(let permit):
            return switch await effects.editor.post(edit, using: permit).outcome {
            case .posted: .done
            case .notRunning: .refused("The action is no longer running.")
            case .notPosted: .failed("The command could not be sent.")
            }
        }
    }

    /// `pressKey` and `pressKeys`: `KeyPresser`, as a Key Press action, once every combo has been read.
    /// One that does not parse refuses the whole sequence before anything is pressed.
    private func press(_ given: PressKeys) async -> JSHostAnswer {
        var steps: [KeyPressAction.Step] = []
        for step in given.steps {
            let made: KeyPressAction.Step
            if let wait = step.wait {
                made = .wait(milliseconds: min(max(wait, 0), 5_000))
            } else if let code = step.keyCode {
                made = .legacyCombo(keyCode: code, keyCharacter: nil, modifiers: step.modifiers ?? 0)
            } else if let combo = step.combo {
                made = .combo((Self.modifierWords(step.modifiers ?? 0) + [combo]).joined(separator: " "))
            } else {
                return .refused("pressKeys was given a step that is not a key or a wait.")
            }
            if case .wait = made {} else {
                guard (try? KeyCombo.parse(made)) != nil else { return .refused("pressKeys was given a key it cannot read.") }
            }
            steps.append(made)
        }
        let target = given.target.flatMap(KeyPressAction.Target.init(rawValue:))
        let verification = await effects.manager.verifyDestination(of: run.invocation)
        switch consume verification {
        case .blocked:
            return .failed("The app the text came from could not be checked, so no keys were pressed.")
        case .verified(let permit):
            return switch await effects.presser.press(KeyPressAction(steps: steps, target: target), using: permit).outcome {
            case .posted: .done
            case .notRunning: .refused("The action is no longer running.")
            case .notPosted: .failed("The keys could not be pressed.")
            }
        }
    }

    /// A modifier mask (`util.constant.MODIFIER_*`) as the words a combo is written with.
    static func modifierWords(_ mask: Int) -> [String] {
        let modifiers = KeyCombo.Modifiers(legacyMask: mask)
        var words: [String] = []
        if modifiers.contains(.control) { words.append("control") }
        if modifiers.contains(.option) { words.append("option") }
        if modifiers.contains(.shift) { words.append("shift") }
        if modifiers.contains(.command) { words.append("command") }
        return words
    }

    /// `performService`: the Runner performs it with the plain text, as a Service action does. It is
    /// somebody else's work, so it is attached to the invocation for cancellation and not waited past it.
    private func service(_ given: Service) async -> JSHostAnswer {
        guard let text = given.content[JSInput.plainTextType] else {
            return .failed("This version of PappuClip gives a Service plain text only.")
        }
        guard let started = await effects.services.start(service: given.name, text: text) else {
            return .failed("The Service could not be started.")
        }
        guard await effects.manager.attach(started, to: run.invocation) else {
            _ = await started.cancel()
            return .refused("The action is no longer running.")
        }
        return switch await started.result() {
        case .returned: .done
        case .stopped: .refused("The action is no longer running.")
        case .failed, .needsSettings, .automationDenied: .failed("The Service did not work.")
        }
    }

    private func reveal(_ given: Reveal) async -> JSHostAnswer {
        let path = (given.path as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            return .failed("There is nothing at that path.")
        }
        return await effects.system.reveal(URL(filePath: path)) ? .done : .failed("The Finder could not show it.")
    }

    /// An address a script may open: one with a scheme, and not a file on disk. Opening a file is running
    /// it, for an app or a script, which is not something reading and replacing text was approved for;
    /// `revealFile` shows one instead.
    static func openable(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), !scheme.isEmpty, scheme != "file" else { return nil }
        return url
    }

    /// PRD §7.4's rule, as a URL action has it: a web address opens in the app the text came from when
    /// that is a browser, unless the script named an app.
    private func open(_ url: URL, app: String?, activate: Bool) async -> JSHostAnswer {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        let browser = isWeb && run.context.browser != nil ? run.context.app.bundleID : nil
        let opened = await effects.urls.open([URLOpenRequest(url: url, activates: activate, browserBundleID: app ?? browser)])
        return opened == 1 ? .done : .failed("The address could not be opened.")
    }

    /// `openTemplateUrl`: a URL action's expansion. PopClip encodes the options it is given, which a URL
    /// action does not, so they are encoded here.
    private func openTemplate(_ given: OpenTemplate) async -> JSHostAnswer {
        let options = given.options.mapValues { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?/"))) ?? "" }
        let action = URLAction(template: given.template, cleanQuery: given.clean, spacesAsPlus: given.plus)
        guard let url = URLTemplate.expand(action, text: given.query, quoted: given.verbatim, options: options),
              let openable = Self.openable(url.absoluteString)
        else { return .failed("The template did not make an address.") }
        if given.copy == true {
            _ = await effects.clipboard.write(given.query.trimmingCharacters(in: .whitespacesAndNewlines), for: run.invocation, into: run.target)
        }
        return await open(openable, app: given.app, activate: given.activate && !given.backgroundTab)
    }

    private func share(_ given: Share) async -> JSHostAnswer {
        var items: [HostShareItem] = []
        for item in given.items {
            if let text = item.text {
                items.append(.text(text))
            } else if let rich = item.rich {
                items.append(.rich(source: rich.source, format: rich.format))
            } else if let text = item.url, let url = URL(string: text) {
                items.append(.url(url))
            } else {
                return .refused("share was given an item it cannot share.")
            }
        }
        if let problem = await effects.system.share(items, with: given.service) { return .failed(problem) }
        return .done
    }

    // MARK: Arguments

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// An answer as JSON, with its keys in order so that the same answer is always the same text.
    private func value(_ encodable: some Encodable) throws -> JSHostAnswer {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .value(String(decoding: try encoder.encode(encodable), as: UTF8.self))
    }

    /// Content as a script gives it, pasteboard type to text, as the pasteboard takes it. Only the three
    /// text types: anything else a script names is not something it can have made from text.
    private func representations(_ content: [String: String]) throws -> [PasteboardRepresentation] {
        let kept = Self.textTypes.compactMap { type in content[type].map { PasteboardRepresentation(type: type, data: Data($0.utf8)) } }
        guard !kept.isEmpty else { throw Refusal(message: "The content has no plain text, HTML or RTF in it.") }
        return kept
    }

    /// `pasteText` sends `text` and `pasteContent` sends `content`; either is the value pasted.
    private struct Paste<Value: Decodable>: Decodable {
        var value: Value
        var restore: Bool

        enum CodingKeys: String, CodingKey { case text, content, restore }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decodeIfPresent(Value.self, forKey: .text) ?? container.decode(Value.self, forKey: .content)
            restore = try container.decodeIfPresent(Bool.self, forKey: .restore) ?? false
        }
    }

    /// `copyText` sends `text` and `copyContent` sends `content`.
    private struct Copy<Value: Decodable>: Decodable {
        var value: Value
        var notify: Bool

        enum CodingKeys: String, CodingKey { case text, content, notify }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decodeIfPresent(Value.self, forKey: .text) ?? container.decode(Value.self, forKey: .content)
            notify = try container.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        }
    }

    private struct Command: Decodable {
        var command: String
        var plain: Bool
    }

    private struct ShowText: Decodable {
        var text: String
    }

    private struct PressKeys: Decodable {
        struct Step: Decodable {
            var combo: String?
            var keyCode: Int?
            var modifiers: Int?
            var wait: Int?
        }

        var steps: [Step]
        var target: String?
    }

    private struct Service: Decodable {
        var name: String
        var content: [String: String]
    }

    private struct Reveal: Decodable {
        var path: String
    }

    private struct OpenURL: Decodable {
        var url: String
        var app: String?
        var activate: Bool
        var backgroundTab: Bool
    }

    private struct OpenTemplate: Decodable {
        var template: String
        var query: String
        var clean: Bool
        var plus: Bool
        var verbatim: Bool
        var copy: Bool?
        var options: [String: String]
        var app: String?
        var activate: Bool
        var backgroundTab: Bool
    }

    private struct Share: Decodable {
        struct Item: Decodable {
            struct Rich: Decodable {
                var source: String
                var format: RichTextFormat
            }

            var text: String?
            var rich: Rich?
            var url: String?
        }

        var service: String
        var items: [Item]
    }

    private struct PasteboardWrite: Decodable {
        var content: [String: String]
    }

    private struct RichText: Decodable {
        var source: String
        var format: RichTextFormat
    }

    private struct Lookup: Decodable {
        var text: String
    }

    private struct Spelling: Decodable {
        var text: String
        var language: String
        var limit: Int?
    }
}
