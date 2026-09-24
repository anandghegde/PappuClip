import Foundation

/// A decoded config to an `ExtensionManifest` (architecture §9.1, "Build" and "Validate").
///
/// The one place that knows what PopClip's keys mean. Everything before it is syntax — three file
/// formats, a comment header, a decade of key spellings — and everything after it reads the manifest,
/// which has none of that. The rules, in the order the builder applies them:
///
/// - **Keys** are read through `KeyNormalizer` (FMT-5). A key nobody reads is a warning that names it;
///   PopClip ignores unknown keys, and so does a manifest here, but a developer should hear about a
///   typo. Keys PopClip removed (`alternateUrl`, `Long Running`) are warnings that say so.
/// - **Inheritance** (§8.3): action keys at the top level are defaults for every entry in `actions`.
///   With neither `action` nor `actions`, the top level is itself the one action. An action that
///   names its own action type drops the inherited one, so that a top-level `url` does not collide
///   with an entry's `shellScript`.
/// - **One action type per action** (§8.4). Two is an error, not a choice.
/// - **Refused rather than approximated:** `submenu` until the bar has submenus (M4) and `pappuAfter`
///   until it has a rich result (M3). Flattening a submenu into buttons, or showing a rich result as a
///   copied one, would run a manifest its author did not write.
/// - **Gates:** `popclipVersion` above `APILevel.emulatedPopClip` (§8.1), `dynamic` with `network` or
///   `script` (§8.3), a `before` that is not an editing command (§8.6), a `regex` that does not
///   compile, a script file that is not in the package. Each fails the load with a message; the
///   API-level gate has a debug override (DEV-1).
/// - **Snippets** (FMT-3) have no package, so anything that names a file is an error.
/// - **Modules** (JS-12): a module's actions are what it exported, which the JavaScript helper describes
///   as `ModuleExports` once the extension is approved. Given those, the builder reads them as it reads a
///   config — the module's top level over the config's — and every action it builds runs the module's
///   code. Without them, a module extension loads with its config's actions, usually none.
///
/// Booleans read `null` as false, because a property list's `<false/>` *is* null (FMT-5).
public struct ManifestBuilder {
    public struct Input: Sendable {
        public var config: ConfigValue
        /// The package the config came from, or nil for a snippet (FMT-3).
        public var package: PackageFiles?
        /// A code snippet's script (FMT-2): the whole text, which is the action unless it is a module.
        public var code: CodeBody?
        /// The package file `code` came from (`Config.ts`); nil for a snippet.
        public var codeFile: String?
        /// JS-12: what the module exported, when the helper has described it.
        public var moduleExports: ModuleExports?
        /// DEV-1's override for §8.1's API-level gate.
        public var ignoresAPILevel: Bool
        /// Where the manifest comes from, for `ExtensionManifest.validate(origin:)`.
        public var origin: ManifestOrigin

        public init(
            config: ConfigValue,
            package: PackageFiles? = nil,
            code: CodeBody? = nil,
            codeFile: String? = nil,
            moduleExports: ModuleExports? = nil,
            ignoresAPILevel: Bool = false,
            origin: ManifestOrigin = .installed
        ) {
            self.config = config
            self.package = package
            self.code = code
            self.codeFile = codeFile
            self.moduleExports = moduleExports
            self.ignoresAPILevel = ignoresAPILevel
            self.origin = origin
        }
    }

    public struct Built: Sendable, Equatable {
        public var manifest: ExtensionManifest
        public var warnings: [ManifestDiagnostic]
    }

    public static func build(_ input: Input) throws(ManifestLoadFailure) -> Built {
        var builder = ManifestBuilder(input: input)
        let manifest = builder.buildExtension()
        guard builder.errors.isEmpty, let manifest else {
            throw ManifestLoadFailure(errors: builder.errors, warnings: builder.warnings)
        }
        return Built(manifest: manifest, warnings: builder.warnings)
    }

    // MARK: Key sets

    /// §8.3 "Top-level keys" that are the extension's own.
    static let extensionKeys: Set<String> = [
        "name", "icon", "identifier", "description", "keywords", "macos version", "popclip version",
        "pappuclip version", "options", "entitlements", "action", "actions", "submenu", "show as",
        "auth service label", "auth keychain", "offers multiple instances", "shell script rationale",
        "module", "language", "app", "apps", "replaces", "network hosts",
    ]

    /// §8.3 "Action keys", less `icon` and `identifier`, which at the top level are the extension's.
    static let actionKeys: Set<String> = [
        "title", "requirements", "regex", "required apps", "excluded apps", "before", "after",
        "stay visible", "capture html", "capture rtf", "restore pasteboard", "wants primary display",
        "wants initial display", "separator", "pappu after",
    ]

    /// §8.4's keys, each with the action type it belongs to. The *primary* keys are the ones that
    /// choose the type; the others configure it.
    static let executorFamilies: [String: ActionExecutor.Kind] = [
        "url": .url, "clean query": .url, "spaces as plus": .url,
        "key combo": .keyPress, "key combos": .keyPress, "key combo target": .keyPress,
        "service name": .service,
        "shortcut name": .shortcut,
        "applescript": .appleScript, "applescript file": .appleScript, "applescript call": .appleScript,
        "shell script": .shellScript, "shell script file": .shellScript, "interpreter": .shellScript,
        "stdin": .shellScript, "shell mode": .shellScript,
        "javascript": .javaScript, "javascript file": .javaScript,
    ]
    static let primaryExecutorKeys: Set<String> = [
        "url", "key combo", "key combos", "service name", "shortcut name", "applescript",
        "applescript file", "applescript call", "shell script", "shell script file", "javascript", "javascript file",
    ]

    /// JS-12: keys only an extension's config may set. A module that sets one is told so and ignored, as
    /// PopClip ignores it. `icon` is not here: at a module's top level it is its actions' default.
    static let configOnlyKeys: Set<String> = [
        "name", "identifier", "description", "keywords", "macos version", "popclip version", "pappuclip version",
        "entitlements", "show as", "color", "auth service label", "auth keychain", "offers multiple instances",
        "shell script rationale", "module", "language", "app", "apps", "replaces", "network hosts",
    ]

    /// Appendix A's "removed in PopClip and ignored here".
    static let removedKeys: [String: String] = [
        "alternate url": "PopClip no longer reads alternateUrl",
        "long running": "PopClip no longer reads Long Running; every action can run long",
        "stoppable": "PopClip no longer reads Stoppable; every action can be cancelled",
    ]

    /// Metadata PopClip's older formats carried for its website, with no effect on behaviour. Read
    /// and dropped without a warning, because a hundred warnings about `Credits` bury the one about a
    /// typo.
    static let inertKeys: Set<String> = ["credits", "version", "note", "long name", "options title", "position", "flags", "mask"]

    /// §8.11's icon modifiers, as the separate keys older manifests used for them (`flipHorizontal`,
    /// `preserveImageColor`) and as `iconOptions`. Folded into the specifier, which is where current
    /// manifests write them. The value is the modifier's spelling in a specifier.
    static let iconModifierKeys: [String: String] = [
        "flip x": "flip-x", "flip y": "flip-y", "preserve color": "preserve-color",
        "preserve aspect": "preserve-aspect", "square": "square", "circle": "circle", "filled": "filled",
        "strike": "strike", "search": "search", "monospaced": "monospaced", "move x": "move-x",
        "move y": "move-y", "scale": "scale", "rotate": "rotate",
    ]

    /// PopClip's `/bin/sh` default for a shell file with no interpreter applies below this build (§8.1).
    static let shellDefaultCutoff = 4035

    // MARK: State

    private let input: Input
    private var errors: [ManifestDiagnostic] = []
    private var warnings: [ManifestDiagnostic] = []
    private var popclipVersion: Int?

    private init(input: Input) {
        self.input = input
    }

    private mutating func error(_ path: String, _ message: String) {
        errors.append(ManifestDiagnostic(.error, at: path, message))
    }

    private mutating func warn(_ path: String, _ message: String) {
        warnings.append(ManifestDiagnostic(.warning, at: path, message))
    }

    // MARK: Extension

    private mutating func buildExtension() -> ExtensionManifest? {
        guard case .dictionary(let entries) = input.config else {
            error("", "The config is \(input.config.kindName), not a dictionary of keys.")
            return nil
        }
        var top = Reader(entries, path: "")
        reportDuplicates(top)

        // The version first: it decides how shell files without an interpreter run.
        popclipVersion = top.take("popclip version").flatMap { integer($0, top.path($0)) }
        if let version = popclipVersion, version > APILevel.emulatedPopClip {
            let message = "Needs PopClip API level \(version); this build emulates \(APILevel.emulatedPopClip)."
            input.ignoresAPILevel ? warn(top.path(forKey: "popclip version"), message + " Loaded anyway (debug override).")
                : error(top.path(forKey: "popclip version"), message)
        }
        let pappuclipVersion = top.take("pappuclip version").flatMap { integer($0, top.path($0)) }
        if let version = pappuclipVersion, version > APILevel.native {
            let message = "Needs API level \(version); this build has \(APILevel.native)."
            input.ignoresAPILevel ? warn(top.path(forKey: "pappuclip version"), message + " Loaded anyway (debug override).")
                : error(top.path(forKey: "pappuclip version"), message)
        }

        guard let nameFound = top.take("name") else {
            error("", "The config has no name, which is the one key every extension needs.")
            return nil
        }
        guard let name = localized(nameFound, top.path(nameFound)) else { return nil }

        var identifier = name.english
        var identifierOrigin = IdentifierOrigin.name
        if let found = top.take("identifier"), let declared = string(found, top.path(found)) {
            identifier = declared
            identifierOrigin = .declared
        }

        let description = top.take("description").flatMap { localized($0, top.path($0)) }
        let icon = readIcon(from: &top)
        let keywords = top.take("keywords").flatMap { string($0, top.path($0)) }
        let macosVersion = top.take("macos version").flatMap { string($0, top.path($0)) }
        var options = top.take("options").map { readOptions($0, top.path($0)) } ?? []
        let entitlements = top.take("entitlements").map { readEntitlements($0, top.path($0)) } ?? []
        let authServiceLabel = top.take("auth service label").flatMap { localized($0, top.path($0)) }
        let authKeychain = top.take("auth keychain").flatMap { keychain($0, top.path($0)) }
        let offersMultipleInstances = top.take("offers multiple instances").flatMap { boolean($0, top.path($0)) }
        _ = top.take("shell script rationale")
        let language = top.take("language").flatMap { readLanguage($0, top.path($0)) }
        var module = top.take("module").flatMap { readModule($0, top.path($0)) }
        var apps: [AppReference] = []
        if let found = top.take("app") { apps += appReferences(.array([found.value]), top.path(found)) }
        if let found = top.take("apps") { apps += appReferences(found.value, top.path(found)) }
        let replaces = top.take("replaces").flatMap { string($0, top.path($0)) }
        let networkHosts = top.take("network hosts").flatMap { stringList($0, top.path($0)) } ?? []

        var showAs = ExtensionManifest.ShowAs.icon
        if let found = top.take("show as"), let text = string(found, top.path(found)) {
            if let parsed = ExtensionManifest.ShowAs(rawValue: text.lowercased()) {
                showAs = parsed
            } else {
                warn(top.path(found), "showAs is \"icon\" or \"text\", not \"\(text)\"; using icon.")
            }
        }

        if let found = top.take("submenu") {
            error(top.path(found), "Submenus arrive with the bar's submenu support (M4); until then this extension cannot load as its author wrote it.")
        }

        // FMT-2: a code config's script is the action, unless it is a module.
        var codeExecutor: ActionExecutor?
        if let code = input.code {
            codeExecutor = executor(forCode: code, language: language, module: &module, interpreter: top.peek("interpreter"))
        }

        // §8.3: action keys at the top level are defaults for every action.
        let explicitAction = top.take("action")
        let explicitActions = top.take("actions")
        let defaults = top.takeAll { Self.actionKeys.contains($0) || Self.executorFamilies[$0] != nil }
        for canonical in top.remaining { reportUnread(canonical, in: top) }

        var actions: [ActionManifest] = []
        if explicitAction != nil || explicitActions != nil {
            if let found = explicitAction {
                if case .dictionary(let entries) = found.value {
                    if let action = action(entries, defaults: defaults, codeExecutor: codeExecutor, path: top.path(found)) {
                        actions.append(action)
                    }
                } else {
                    error(top.path(found), "An action is a dictionary, not \(found.value.kindName).")
                }
            }
            if let found = explicitActions {
                if case .array(let values) = found.value {
                    for (index, value) in values.enumerated() {
                        let path = "\(top.path(found))[\(index)]"
                        guard case .dictionary(let entries) = value else {
                            error(path, "An action is a dictionary, not \(value.kindName).")
                            continue
                        }
                        if let action = action(entries, defaults: defaults, codeExecutor: codeExecutor, path: path) {
                            actions.append(action)
                        }
                    }
                } else if !found.value.isNull {
                    error(top.path(found), "actions is a list, not \(found.value.kindName).")
                }
            }
        } else if codeExecutor != nil || defaults.contains(where: { Self.primaryExecutorKeys.contains(KeyNormalizer.normalize($0.key)) }) {
            // No `action` or `actions`: the top level is the action.
            if let action = action([], defaults: defaults, codeExecutor: codeExecutor, path: "") {
                actions.append(action)
            }
        }

        // JS-12: a module's exports, read over the config.
        let moduleSource = sourceOfModule(module, language: language)
        if let moduleSource, let exports = input.moduleExports {
            readExports(exports, source: moduleSource, configDefaults: defaults, actions: &actions, options: &options)
        }

        let manifest = ExtensionManifest(
            name: name,
            identifier: identifier,
            identifierOrigin: identifierOrigin,
            description: description,
            icon: icon,
            showAs: showAs,
            keywords: keywords,
            macosVersion: macosVersion,
            popclipVersion: popclipVersion,
            pappuclipVersion: pappuclipVersion,
            options: options,
            entitlements: entitlements,
            authServiceLabel: authServiceLabel,
            authKeychain: authKeychain,
            offersMultipleInstances: offersMultipleInstances,
            module: module,
            moduleSource: moduleSource,
            language: language,
            apps: apps,
            replaces: replaces,
            networkHosts: networkHosts,
            actions: actions
        )
        guard errors.isEmpty else { return nil }
        do {
            try manifest.validate(origin: input.origin)
        } catch {
            self.error("", String(describing: error))
            return nil
        }
        return manifest
    }

    // MARK: Actions

    private mutating func action(
        _ entries: [ConfigValue.Entry],
        defaults: [ConfigValue.Entry],
        codeExecutor: ActionExecutor?,
        path: String
    ) -> ActionManifest? {
        let own = NormalizedDictionary(entries)
        let ownFamily = own.keys.lazy.filter { Self.primaryExecutorKeys.contains($0) }.compactMap { Self.executorFamilies[$0] }.first
        // Inherit what the action does not say. An action with its own type inherits nothing about
        // another type, so that a top-level `interpreter` does not follow a `url` entry around.
        let inherited = defaults.filter { entry in
            let canonical = KeyNormalizer.normalize(entry.key)
            if own.contains(canonical) { return false }
            if let family = Self.executorFamilies[canonical], let ownFamily, family != ownFamily { return false }
            return true
        }
        var reader = Reader(entries + inherited, path: path)
        reportDuplicates(Reader(entries, path: path))
        let errorCount = errors.count

        let title = reader.take("title").flatMap { localized($0, reader.path($0)) }
        let icon = readIcon(from: &reader)
        let identifier = reader.take("identifier").flatMap { string($0, reader.path($0)) }
        var requirements: [ActionRequirement] = [.text]
        if let found = reader.take("requirements"), !found.value.isNull {
            requirements = readRequirements(found, reader.path(found))
        }
        var regex: String?
        if let found = reader.take("regex"), let pattern = string(found, reader.path(found)) {
            do {
                _ = try NSRegularExpression(pattern: pattern)
                regex = pattern
            } catch {
                self.error(reader.path(found), "The regex does not compile: \(pattern)")
            }
        }
        let requiredApps = reader.take("required apps").flatMap { stringList($0, reader.path($0)) } ?? []
        let excludedApps = reader.take("excluded apps").flatMap { stringList($0, reader.path($0)) } ?? []
        let before = reader.take("before").flatMap { step($0, reader.path($0), before: true) }
        let after = reader.take("after").flatMap { step($0, reader.path($0), before: false) }
        let stayVisible = reader.take("stay visible").flatMap { boolean($0, reader.path($0)) } ?? false
        let captureHTML = reader.take("capture html").flatMap { boolean($0, reader.path($0)) } ?? false
        let captureRTF = reader.take("capture rtf").flatMap { boolean($0, reader.path($0)) } ?? false
        let restorePasteboard = reader.take("restore pasteboard").flatMap { boolean($0, reader.path($0)) } ?? false
        let wantsPrimaryDisplay = reader.take("wants primary display").flatMap { boolean($0, reader.path($0)) } ?? false

        if let found = reader.take("submenu") {
            error(reader.path(found), "Submenus arrive with the bar's submenu support (M4); until then this action cannot load as its author wrote it.")
        }
        if let found = reader.take("pappu after") {
            error(reader.path(found), "pappuAfter arrives with the rich result panel (M3).")
        }
        for key in ["wants initial display", "separator"] {
            if let found = reader.take(key) {
                warn(reader.path(found), "\(found.rawKey) is for submenus, which this build does not have yet; ignored.")
            }
        }

        let executor = self.executor(&reader, codeExecutor: codeExecutor)
        // An action's own `app` is the extension's metadata written in the wrong place; harmless.
        _ = reader.take("app")
        _ = reader.take("apps")
        for canonical in reader.remaining { reportUnread(canonical, in: reader) }
        guard let executor, errors.count == errorCount else {
            if executor == nil, errors.count == errorCount {
                error(path, "The action has no action type: none of url, keyCombo, serviceName, shortcutName, appleScript, shellScript or javaScript.")
            }
            return nil
        }

        return ActionManifest(
            title: title,
            icon: icon,
            identifier: identifier,
            requirements: requirements,
            regex: regex,
            requiredApps: requiredApps,
            excludedApps: excludedApps,
            before: before,
            after: after,
            wantsPrimaryDisplay: wantsPrimaryDisplay,
            stayVisible: stayVisible,
            captureHTML: captureHTML,
            captureRTF: captureRTF,
            restorePasteboard: restorePasteboard,
            executor: executor
        )
    }

    private mutating func readRequirements(_ found: NormalizedDictionary.Found, _ path: String) -> [ActionRequirement] {
        guard let spellings = stringList(found, path) else { return [.text] }
        var requirements: [ActionRequirement] = []
        for spelling in spellings {
            let requirement = ActionRequirement(parsing: spelling)
            if case .unrecognised(let body) = requirement.condition {
                if body.lowercased() == "html" {
                    warn(path, "The html requirement was removed from PopClip; ignored.")
                    continue
                }
                // Kept: `ActionMatching` never satisfies it, so the action is hidden rather than shown
                // in places its author ruled out.
                warn(path, "\"\(spelling)\" is not a requirement this build knows; the action will not show.")
            }
            requirements.append(requirement)
        }
        return requirements
    }

    private mutating func step(_ found: NormalizedDictionary.Found, _ path: String, before: Bool) -> StepCommand? {
        guard let text = string(found, path) else { return nil }
        guard let step = StepCommand(rawValue: text.lowercased()) else {
            error(path, "\"\(text)\" is not a step PopClip knows (§8.6).")
            return nil
        }
        if before, !step.isAllowedBefore {
            error(path, "\"\(text)\" can only come after an action; before is cut, copy, paste or paste-plain.")
            return nil
        }
        return step
    }

    // MARK: Executors

    private mutating func executor(_ reader: inout Reader, codeExecutor: ActionExecutor?) -> ActionExecutor? {
        let primaries = reader.remaining.filter { Self.primaryExecutorKeys.contains($0) }
        let families = Set(primaries.compactMap { Self.executorFamilies[$0] })
        if families.count > 1 {
            let keys = primaries.compactMap { reader.peek($0)?.rawKey }.joined(separator: ", ")
            error(reader.path, "An action has one action type; this one names several (\(keys)).")
            _ = reader.takeAll { Self.executorFamilies[$0] != nil }
            return nil
        }
        guard let family = families.first else {
            // A shell code snippet's text is the script, and the header configures it.
            if case .shellScript(var shell) = codeExecutor {
                shell.interpreter = reader.take("interpreter").flatMap { string($0, reader.path($0)) } ?? input.code?.shebang
                shell.stdin = reader.take("stdin").flatMap { string($0, reader.path($0)) }
                if let found = reader.take("shell mode"), let text = string(found, reader.path(found)) {
                    shell.mode = ShellScriptAction.Mode(rawValue: text.lowercased())
                    if shell.mode == nil { error(reader.path(found), "shellMode is login, nonlogin or none, not \"\(text)\".") }
                }
                return .shellScript(shell)
            }
            // Configuration for a type nobody chose is a mistake worth hearing about.
            for canonical in reader.remaining where Self.executorFamilies[canonical] != nil {
                if let found = reader.take(canonical) {
                    warn(reader.path(found), "\(found.rawKey) configures an action type this action does not have; ignored.")
                }
            }
            return codeExecutor
        }
        switch family {
        case .url: return urlExecutor(&reader)
        case .keyPress: return keyPressExecutor(&reader)
        case .service:
            return reader.take("service name").flatMap { string($0, reader.path($0)) }.map { .service(ServiceAction(name: $0)) }
        case .shortcut:
            return reader.take("shortcut name").flatMap { string($0, reader.path($0)) }.map { .shortcut(ShortcutAction(name: $0)) }
        case .appleScript: return appleScriptExecutor(&reader)
        case .shellScript: return shellScriptExecutor(&reader)
        case .javaScript: return javaScriptExecutor(&reader)
        case .builtin: return nil
        }
    }

    private mutating func urlExecutor(_ reader: inout Reader) -> ActionExecutor? {
        guard let found = reader.take("url"), let template = string(found, reader.path(found)) else { return nil }
        let cleanQuery = reader.take("clean query").flatMap { boolean($0, reader.path($0)) } ?? false
        let spacesAsPlus = reader.take("spaces as plus").flatMap { boolean($0, reader.path($0)) } ?? false
        return .url(URLAction(template: template, cleanQuery: cleanQuery, spacesAsPlus: spacesAsPlus))
    }

    private mutating func keyPressExecutor(_ reader: inout Reader) -> ActionExecutor? {
        let single = reader.take("key combo")
        let several = reader.take("key combos")
        if let single, let several {
            error(reader.path(several), "\(single.rawKey) and \(several.rawKey) are two ways to say the same thing; use one.")
            return nil
        }
        var steps: [KeyPressAction.Step] = []
        if let single {
            guard let step = keyStep(single.value, reader.path(single), allowsWait: false) else { return nil }
            steps = [step]
        } else if let several {
            guard case .array(let values) = several.value, !values.isEmpty else {
                error(reader.path(several), "keyCombos is a non-empty list.")
                return nil
            }
            for (index, value) in values.enumerated() {
                guard let step = keyStep(value, "\(reader.path(several))[\(index)]", allowsWait: true) else { return nil }
                steps.append(step)
            }
        }
        var target: KeyPressAction.Target?
        if let found = reader.take("key combo target"), let text = string(found, reader.path(found)) {
            target = KeyPressAction.Target(rawValue: text.lowercased())
            if target == nil { error(reader.path(found), "keyComboTarget is session, app or hid, not \"\(text)\".") }
        }
        return .keyPress(KeyPressAction(steps: steps, target: target))
    }

    /// A combo string (`command b`), `wait <ms>` in a list, or the legacy dictionary
    /// (`{keyCode: 51, modifiers: 0}`, `{keyChar: "B", modifiers: 1048576}`) that older plists use.
    private mutating func keyStep(_ value: ConfigValue, _ path: String, allowsWait: Bool) -> KeyPressAction.Step? {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let words = trimmed.lowercased().split(separator: " ")
            if words.first == "wait" {
                guard allowsWait, words.count == 2, let milliseconds = Int(words[1]), milliseconds >= 0 else {
                    error(path, allowsWait ? "A wait is \"wait <milliseconds>\"." : "A wait belongs in keyCombos, not keyCombo.")
                    return nil
                }
                return .wait(milliseconds: milliseconds)
            }
            guard !trimmed.isEmpty else {
                error(path, "The key combo is empty.")
                return nil
            }
            // Read now so that a combo that cannot be pressed refuses the extension at load rather
            // than failing on a click. The step keeps the text; the runner parses it again.
            do throws(KeyCombo.Problem) {
                _ = try KeyCombo.parse(trimmed)
            } catch {
                self.error(path, "The key combo \"\(trimmed)\" cannot be read: \(error).")
                return nil
            }
            return .combo(trimmed)
        case .dictionary(let entries):
            let dictionary = NormalizedDictionary(entries)
            let keyCode = dictionary["key code"].flatMap { integer($0, path) }
            let keyCharacter = dictionary["key char"]?.value.scalarText
            let modifiers = dictionary["modifiers"].flatMap { integer($0, path) } ?? 0
            guard keyCode != nil || keyCharacter != nil else {
                error(path, "A key combo dictionary needs keyCode or keyChar.")
                return nil
            }
            do throws(KeyCombo.Problem) {
                _ = try KeyCombo.legacy(keyCode: keyCode, keyCharacter: keyCharacter, modifiers: modifiers)
            } catch {
                self.error(path, "The key combo cannot be read: \(error).")
                return nil
            }
            return .legacyCombo(keyCode: keyCode, keyCharacter: keyCharacter, modifiers: modifiers)
        default:
            error(path, "A key combo is a string such as \"command b\", not \(value.kindName).")
            return nil
        }
    }

    /// Three sources — `appleScript`, `appleScriptFile`, or a `file` inside `appleScriptCall` — of which
    /// an action names one. `appleScriptCall` alone is enough when it names its file, and an inline
    /// script may define the handler it calls.
    private mutating func appleScriptExecutor(_ reader: inout Reader) -> ActionExecutor? {
        let inline = reader.take("applescript")
        let file = reader.take("applescript file")
        let callFound = reader.take("applescript call")
        var call: AppleScriptAction.Call?
        var callFile: NormalizedDictionary.Found?
        if let callFound {
            guard case .dictionary(let entries) = callFound.value else {
                error(reader.path(callFound), "appleScriptCall is a dictionary with handler and parameters.")
                return nil
            }
            var callReader = Reader(entries, path: reader.path(callFound))
            guard let handler = callReader.take("handler").flatMap({ string($0, callReader.path($0)) }) else {
                error(reader.path(callFound), "appleScriptCall needs a handler.")
                return nil
            }
            let parameters = callReader.take("parameters").flatMap { stringList($0, callReader.path($0)) } ?? []
            call = AppleScriptAction.Call(handler: handler, parameters: parameters)
            callFile = callReader.take("file")
            for canonical in callReader.remaining { reportUnread(canonical, in: callReader) }
        }
        let sources = [inline, file, callFile].compactMap { $0 }
        guard sources.count == 1 else {
            error(reader.path, sources.isEmpty
                ? "appleScriptCall calls a handler in a script, and there is none: add appleScriptFile or a file in the call."
                : "An AppleScript action has one script; this one names \(sources.map(\.rawKey).joined(separator: ", ")).")
            return nil
        }
        if let inline, let text = string(inline, reader.path(inline)) {
            return .appleScript(AppleScriptAction(source: .inline(text), call: call))
        }
        if let found = file ?? callFile {
            let path = found == callFile ? "\(reader.path(callFound!)).\(found.rawKey)" : reader.path(found)
            if let file = packageFile(found, path) {
                return .appleScript(AppleScriptAction(source: .file(file), call: call))
            }
        }
        return nil
    }

    private mutating func shellScriptExecutor(_ reader: inout Reader) -> ActionExecutor? {
        let inline = reader.take("shell script")
        let file = reader.take("shell script file")
        if inline != nil, let file {
            error(reader.path(file), "shellScript and shellScriptFile are two sources; use one.")
            return nil
        }
        var interpreter = reader.take("interpreter").flatMap { string($0, reader.path($0)) }
        let stdin = reader.take("stdin").flatMap { string($0, reader.path($0)) }
        var mode: ShellScriptAction.Mode?
        if let found = reader.take("shell mode"), let text = string(found, reader.path(found)) {
            mode = ShellScriptAction.Mode(rawValue: text.lowercased())
            if mode == nil { error(reader.path(found), "shellMode is login, nonlogin or none, not \"\(text)\".") }
        }
        let source: ScriptSource
        if let inline, let text = string(inline, reader.path(inline)) {
            source = .inline(text)
        } else if let file, let path = packageFile(file, reader.path(file)) {
            source = .file(path)
            // §8.4's file rules, in PopClip's order: an interpreter; else an executable with `#!`;
            // else `/bin/sh` for `.sh` or old API levels; else nothing can run it.
            if interpreter == nil, input.package?.isExecutableScript(path) != true {
                if path.lowercased().hasSuffix(".sh") || (popclipVersion ?? 0) < Self.shellDefaultCutoff {
                    interpreter = "/bin/sh"
                } else {
                    error(reader.path(file), "\(path) has no interpreter, is not an executable with a #! line, and is not a .sh file.")
                    return nil
                }
            }
        } else {
            return nil
        }
        return .shellScript(ShellScriptAction(source: source, interpreter: interpreter, stdin: stdin, mode: mode))
    }

    private mutating func javaScriptExecutor(_ reader: inout Reader) -> ActionExecutor? {
        let inline = reader.take("javascript")
        let file = reader.take("javascript file")
        if inline != nil, let file {
            error(reader.path(file), "javaScript and javaScriptFile are two sources; use one.")
            return nil
        }
        if let inline, let text = string(inline, reader.path(inline)) {
            return .javaScript(JavaScriptAction(source: .inline(text)))
        }
        if let file, let path = packageFile(file, reader.path(file)) {
            return .javaScript(JavaScriptAction(source: .file(path), isTypeScript: path.lowercased().hasSuffix(".ts")))
        }
        return nil
    }

    /// FMT-2: what a code config's text does. A JavaScript module has no single action — its actions
    /// come from running it (M3) — so it sets `module` instead.
    private mutating func executor(
        forCode code: CodeBody,
        language: ScriptLanguage?,
        module: inout ModuleReference?,
        interpreter: NormalizedDictionary.Found?
    ) -> ActionExecutor? {
        switch code.style {
        case .slashes:
            let isTypeScript = switch language {
            case .javascript: false
            case .typescript: true
            case .applescript, nil: code.impliedLanguage != .javascript
            }
            let isModule: Bool
            if case .detection(let override) = module {
                isModule = override
            } else {
                isModule = code.looksLikeModule
            }
            if isModule {
                module = .detection(true)
                return nil
            }
            return .javaScript(JavaScriptAction(source: .inline(code.text), isTypeScript: isTypeScript))
        case .dashes:
            return .appleScript(AppleScriptAction(source: .inline(code.text)))
        case .hash:
            // The interpreter key is read again, and consumed, by the action that inherits this.
            if interpreter == nil, code.shebang == nil {
                error("", "A shell snippet needs an interpreter key or a #! line before the marker (FMT-2).")
                return nil
            }
            return .shellScript(ShellScriptAction(source: .inline(code.text)))
        }
    }

    // MARK: Modules (JS-12)

    /// What the helper runs for a module extension: the file `module` names, or a code config that is a
    /// module — its file in a package, its own text in a snippet. The language rule is FMT-2's.
    private func sourceOfModule(_ module: ModuleReference?, language: ScriptLanguage?) -> ModuleSource? {
        switch module {
        case .file(let path):
            return ModuleSource(source: .file(path), isTypeScript: path.lowercased().hasSuffix(".ts"))
        case .detection(true):
            guard let code = input.code, code.style == .slashes else { return nil }
            let isTypeScript = switch language {
            case .javascript: false
            case .typescript: true
            case .applescript, nil: code.impliedLanguage != .javascript
            }
            if let file = input.codeFile { return ModuleSource(source: .file(file), isTypeScript: isTypeScript) }
            return ModuleSource(source: .inline(code.text), isTypeScript: isTypeScript)
        case .detection(false), nil:
            return nil
        }
    }

    /// The module's exports over the config (JS-12). Its `options` replace the config's; its `action`
    /// and `actions`, when it has them, replace the config's actions; its other action keys are
    /// defaults over the config's. What only a config may set is ignored with a warning.
    private mutating func readExports(
        _ exports: ModuleExports,
        source: ModuleSource,
        configDefaults: [ConfigValue.Entry],
        actions: inout [ActionManifest],
        options: inout [OptionManifest]
    ) {
        let path = "module"
        guard case .dictionary(let entries) = exports.object else {
            error(path, "The module exports \(exports.object.kindName), not an extension object.")
            return
        }
        var top = Reader(entries, path: path)
        reportDuplicates(top)
        for key in top.remaining where Self.configOnlyKeys.contains(key) {
            if let found = top.take(key) {
                warn(top.path(found), "\(found.rawKey) can only be set in the extension's config, not by its module; ignored.")
            }
        }
        if let found = top.take("options") {
            options = readOptions(found, top.path(found))
        }
        for name in exports.functions {
            switch KeyNormalizer.normalize(name) {
            case "actions", "submenu":
                warn(top.join(name), "A population function needs the dynamic runtime (M3 week 5); until then the module offers no actions from it.")
            case "auth":
                warn(top.join(name), "Sign-in arrives in M3 week 5; until then the auth function is not called.")
            default:
                // `test`, and functions a module exports for itself.
                break
            }
        }
        if let found = top.take("submenu") {
            error(top.path(found), "Submenus arrive with the bar's submenu support (M4); until then this extension cannot load as its author wrote it.")
        }
        let explicitAction = top.take("action")
        let explicitActions = top.take("actions")
        let moduleDefaults = top.takeAll {
            Self.actionKeys.contains($0) || $0 == "icon" || $0 == "icon options" || Self.iconModifierKeys[$0] != nil
        }
        for canonical in top.remaining {
            if Self.executorFamilies[canonical] != nil, let found = top.take(canonical) {
                warn(top.path(found), "\(found.rawKey) is for an extension's config; a module's actions run its code. Ignored.")
            } else {
                reportUnread(canonical, in: top)
            }
        }
        guard explicitAction != nil || explicitActions != nil else { return }

        // The module's defaults win over the config's, and nothing about another action type is
        // inherited: a module's actions run code.
        let overridden = Set(moduleDefaults.map { KeyNormalizer.normalize($0.key) })
        let defaults = configDefaults.filter {
            let canonical = KeyNormalizer.normalize($0.key)
            return !overridden.contains(canonical) && Self.executorFamilies[canonical] == nil
        } + moduleDefaults

        var built: [ActionManifest] = []
        if let found = explicitAction,
           let action = moduleAction(found.value, export: "action", defaults: defaults, source: source, path: top.path(found)) {
            built.append(action)
        }
        if let found = explicitActions {
            if case .array(let values) = found.value {
                for (index, value) in values.enumerated() {
                    let entryPath = "\(top.path(found))[\(index)]"
                    if let action = moduleAction(value, export: "actions.\(index)", defaults: defaults, source: source, path: entryPath) {
                        built.append(action)
                    }
                }
            } else {
                error(top.path(found), "actions is a list, not \(found.value.kindName).")
            }
        }
        actions = built
    }

    /// One of a module's actions, which runs the code at `export`. An action with no code has nothing
    /// to do: PopClip shows it disabled, and this build leaves it out until the bar can show one (M4).
    private mutating func moduleAction(
        _ value: ConfigValue,
        export: String,
        defaults: [ConfigValue.Entry],
        source: ModuleSource,
        path: String
    ) -> ActionManifest? {
        guard case .dictionary(let entries) = value else {
            error(path, "An action is a dictionary or a function, not \(value.kindName).")
            return nil
        }
        let own = NormalizedDictionary(entries)
        guard own["code"]?.value == .bool(true) else {
            if own.contains("separator") {
                warn(path, "Separators are for submenus, which this build does not have yet; ignored.")
            } else {
                warn(path, "The action has no code function, so there is nothing for it to do; left out.")
            }
            return nil
        }
        var kept: [ConfigValue.Entry] = []
        for entry in entries {
            let canonical = KeyNormalizer.normalize(entry.key)
            if canonical == "code" { continue }
            if Self.executorFamilies[canonical] != nil {
                warn("\(path).\(entry.key)", "\(entry.key) is for an extension's config; a module's action runs its code. Ignored.")
                continue
            }
            kept.append(entry)
        }
        let executor = ActionExecutor.javaScript(JavaScriptAction(source: source.source, isTypeScript: source.isTypeScript, export: export))
        return action(kept, defaults: defaults, codeExecutor: executor, path: path)
    }

    // MARK: Extension parts

    private mutating func readOptions(_ found: NormalizedDictionary.Found, _ path: String) -> [OptionManifest] {
        guard case .array(let values) = found.value else {
            if !found.value.isNull { error(path, "options is a list, not \(found.value.kindName).") }
            return []
        }
        var options: [OptionManifest] = []
        var seen: Set<String> = []
        for (index, value) in values.enumerated() {
            let optionPath = "\(path)[\(index)]"
            guard case .dictionary(let entries) = value else {
                error(optionPath, "An option is a dictionary, not \(value.kindName).")
                continue
            }
            var reader = Reader(entries, path: optionPath)
            guard let typeFound = reader.take("type"), let typeText = string(typeFound, reader.path(typeFound)) else {
                error(optionPath, "An option needs a type.")
                continue
            }
            guard let kind = OptionManifest.Kind(rawValue: typeText.lowercased()) else {
                error(reader.path(typeFound), "\"\(typeText)\" is not an option type (§8.9).")
                continue
            }
            let identifier = reader.take("identifier").flatMap { string($0, reader.path($0)) }
            if kind != .heading {
                guard let identifier, !identifier.isEmpty else {
                    error(optionPath, "A \(kind.rawValue) option needs an identifier; it is where the value is stored.")
                    continue
                }
                if !seen.insert(identifier).inserted {
                    error(optionPath, "Two options have the identifier \"\(identifier)\".")
                    continue
                }
            }
            var option = OptionManifest(identifier: identifier, kind: kind)
            option.label = reader.take("label").flatMap { localized($0, reader.path($0)) }
            option.description = reader.take("description").flatMap { localized($0, reader.path($0)) }
            if let found = reader.take("default value"), !found.value.isNull || kind == .boolean {
                if kind == .boolean {
                    option.defaultValue = boolean(found, reader.path(found)).map { .boolean($0) }
                } else if let text = string(found, reader.path(found)) {
                    option.defaultValue = .string(text)
                }
            }
            option.values = reader.take("values").flatMap { stringList($0, reader.path($0)) } ?? []
            if let found = reader.take("value labels") {
                if case .array(let labels) = found.value {
                    option.valueLabels = labels.compactMap { localized(.init(rawKey: found.rawKey, value: $0), reader.path(found)) }
                } else {
                    error(reader.path(found), "valueLabels is a list.")
                }
            }
            if kind == .multiple, option.values.isEmpty {
                error(optionPath, "A multiple option needs values.")
            }
            option.multiline = reader.take("multiline").flatMap { boolean($0, reader.path($0)) } ?? false
            option.allowOther = reader.take("allow other").flatMap { boolean($0, reader.path($0)) } ?? false
            option.allowNone = reader.take("allow none").flatMap { boolean($0, reader.path($0)) } ?? false
            option.icon = reader.take("icon").flatMap { string($0, reader.path($0)) }
            option.inset = reader.take("inset").flatMap { boolean($0, reader.path($0)) } ?? false
            option.keychain = reader.take("keychain").flatMap { keychain($0, reader.path($0)) }
            option.hidden = reader.take("hidden").flatMap { boolean($0, reader.path($0)) } ?? false
            _ = reader.take("migrate from")
            for canonical in reader.remaining { reportUnread(canonical, in: reader) }
            options.append(option)
        }
        return options
    }

    private mutating func readEntitlements(_ found: NormalizedDictionary.Found, _ path: String) -> [Entitlement] {
        guard let names = stringList(found, path) else { return [] }
        var entitlements: [Entitlement] = []
        for name in names {
            guard let entitlement = Entitlement(rawValue: name.lowercased()) else {
                error(path, "\"\(name)\" is not an entitlement; they are network, dynamic and script.")
                continue
            }
            if !entitlements.contains(entitlement) { entitlements.append(entitlement) }
        }
        if entitlements.contains(.dynamic), entitlements.contains(.network) || entitlements.contains(.script) {
            error(path, "dynamic cannot be combined with network or script (§8.3).")
        }
        return entitlements
    }

    private mutating func appReferences(_ value: ConfigValue, _ path: String) -> [AppReference] {
        guard case .array(let values) = value else {
            error(path, "apps is a list, not \(value.kindName).")
            return []
        }
        var apps: [AppReference] = []
        for (index, value) in values.enumerated() {
            let appPath = "\(path)[\(index)]"
            guard case .dictionary(let entries) = value else {
                warn(appPath, "An app is a dictionary with a name; ignored.")
                continue
            }
            var reader = Reader(entries, path: appPath)
            guard let name = reader.take("name").flatMap({ string($0, appPath) }) else {
                warn(appPath, "An app needs a name; ignored.")
                continue
            }
            let link = reader.take("link").flatMap { string($0, reader.path($0)) }
            let checkInstalled = reader.take("check installed").flatMap { boolean($0, reader.path($0)) } ?? false
            let bundleIdentifiers = reader.take("bundle identifiers").flatMap { stringList($0, reader.path($0)) }
                ?? reader.take("bundle identifier").flatMap { stringList($0, reader.path($0)) } ?? []
            for canonical in reader.remaining { reportUnread(canonical, in: reader) }
            apps.append(AppReference(name: name, link: link, checkInstalled: checkInstalled, bundleIdentifiers: bundleIdentifiers))
        }
        return apps
    }

    private mutating func readModule(_ found: NormalizedDictionary.Found, _ path: String) -> ModuleReference? {
        switch found.value {
        case .bool(let flag): return .detection(flag)
        case .null: return .detection(false)
        default:
            guard let file = packageFile(found, path) else { return nil }
            return .file(file)
        }
    }

    private mutating func readLanguage(_ found: NormalizedDictionary.Found, _ path: String) -> ScriptLanguage? {
        guard let text = string(found, path) else { return nil }
        guard let language = ScriptLanguage(rawValue: text.lowercased()) else {
            error(path, "language is javascript, typescript or applescript, not \"\(text)\".")
            return nil
        }
        return language
    }

    private mutating func keychain(_ found: NormalizedDictionary.Found, _ path: String) -> KeychainScope? {
        guard let text = string(found, path) else { return nil }
        guard let scope = KeychainScope(rawValue: text.lowercased()) else {
            error(path, "The keychain is sync or local, not \"\(text)\".")
            return nil
        }
        return scope
    }

    /// `icon`, with any modifier keys folded in front of it.
    private mutating func readIcon(from reader: inout Reader) -> ActionIcon {
        var modifiers: [String] = []
        var modifierPaths: [String] = []
        var modifierEntries: [(NormalizedDictionary.Found, String)] = []
        if let found = reader.take("icon options") {
            if case .dictionary(let entries) = found.value {
                let options = NormalizedDictionary(entries)
                for key in options.keys {
                    guard let option = options[key] else { continue }
                    let path = "\(reader.path(found)).\(option.rawKey)"
                    if Self.iconModifierKeys[key] != nil {
                        modifierEntries.append((option, key))
                        modifierPaths.append(path)
                    } else {
                        warn(path, "\(option.rawKey) is not an icon modifier; ignored.")
                    }
                }
            } else {
                error(reader.path(found), "iconOptions is a dictionary of modifiers.")
            }
        }
        for key in Self.iconModifierKeys.keys.sorted() {
            if let found = reader.take(key) {
                modifierEntries.append((found, key))
                modifierPaths.append(reader.path(found))
            }
        }
        for ((found, key), path) in zip(modifierEntries, modifierPaths) {
            let spelling = Self.iconModifierKeys[key]!
            switch found.value {
            case .int, .double:
                modifiers.append("\(spelling)=\(found.value.scalarText!)")
            default:
                if let flag = boolean(found, path), flag { modifiers.append(spelling) }
            }
        }
        guard let found = reader.take("icon") else {
            if let path = modifierPaths.first { warn(path, "An icon modifier with no icon; ignored.") }
            return .unset
        }
        let icon = readIcon(found, reader.path(found))
        guard case .specifier(let specifier) = icon, !modifiers.isEmpty else { return icon }
        // `text:` and the inline forms hold their own spaces; modifiers go before the prefix either way.
        return .specifier((modifiers + [specifier]).joined(separator: " "))
    }

    private mutating func readIcon(_ found: NormalizedDictionary.Found, _ path: String) -> ActionIcon {
        if found.value.isNull { return .none }
        guard let specifier = string(found, path) else { return .unset }
        if let file = Self.iconFile(in: specifier) {
            guard let package = input.package else {
                error(path, "A snippet cannot use an icon file (\(file)); use text, symbol:, iconify:, svg: or data: (FMT-3).")
                return .unset
            }
            if !package.contains(file) {
                warn(path, "The icon file \(file) is not in the package; the action shows its title instead.")
            }
        }
        return .specifier(specifier)
    }

    /// The file an icon specifier names, if it names one (§8.11): the base form is last, after any
    /// modifiers, and is a file when it ends in `.png` or `.svg` or says `file:`. `svg:` and `data:`
    /// carry their image inline, spaces and all, so they are never files.
    static func iconFile(in specifier: String) -> String? {
        let lowered = specifier.lowercased()
        if lowered.contains("svg:") || lowered.contains("data:") { return nil }
        guard var base = specifier.split(separator: " ").last.map(String.init) else { return nil }
        if base.lowercased().hasPrefix("file:") {
            base.removeFirst("file:".count)
            return base
        }
        let extensionLowered = (base as NSString).pathExtension.lowercased()
        return ["png", "svg"].contains(extensionLowered) ? base : nil
    }

    /// A path the config names inside its package: relative, inside the root, and there.
    private mutating func packageFile(_ found: NormalizedDictionary.Found, _ path: String) -> String? {
        guard let file = string(found, path) else { return nil }
        guard let package = input.package else {
            error(path, "A snippet cannot refer to other files (FMT-3).")
            return nil
        }
        guard PackageFiles.isContained(file) else {
            error(path, "\(file) is outside the package.")
            return nil
        }
        guard package.contains(file) else {
            error(path, "\(file) is not in the package.")
            return nil
        }
        return file
    }

    // MARK: Values

    private mutating func string(_ found: NormalizedDictionary.Found, _ path: String) -> String? {
        switch found.value {
        case .string(let text): return text
        case .int, .double: return found.value.scalarText
        default:
            error(path, "Expected a string, found \(found.value.kindName).")
            return nil
        }
    }

    /// FMT-5: `null` is false, because a plist's `<false/>` is null.
    private mutating func boolean(_ found: NormalizedDictionary.Found, _ path: String) -> Bool? {
        switch found.value {
        case .bool(let flag): return flag
        case .null: return false
        case .int(let value) where value == 0 || value == 1: return value == 1
        case .string(let text):
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        default: break
        }
        error(path, "Expected true or false, found \(found.value.kindName).")
        return nil
    }

    private mutating func integer(_ found: NormalizedDictionary.Found, _ path: String) -> Int? {
        switch found.value {
        case .int(let value): return value
        case .string(let text):
            if let value = Int(text.trimmingCharacters(in: .whitespaces)) { return value }
        default: break
        }
        error(path, "Expected a whole number, found \(found.value.kindName).")
        return nil
    }

    private mutating func stringList(_ found: NormalizedDictionary.Found, _ path: String) -> [String]? {
        switch found.value {
        case .null: return []
        case .array(let values):
            var strings: [String] = []
            for value in values {
                guard let text = value.scalarText, !(value.isBool) else {
                    error(path, "Expected a list of strings, found \(value.kindName) in it.")
                    return nil
                }
                strings.append(text)
            }
            return strings
        default:
            // A single string where a list is expected is a list of one.
            return string(found, path).map { [$0] }
        }
    }

    /// A localizable string (§8.3): plain, or keyed by language code with `en` required.
    private mutating func localized(_ found: NormalizedDictionary.Found, _ path: String) -> LocalizedText? {
        switch found.value {
        case .dictionary(let entries):
            var table: [String: String] = [:]
            for entry in entries {
                guard let text = entry.value.scalarText else {
                    error(path, "A localized string's \(entry.key) is \(entry.value.kindName), not text.")
                    return nil
                }
                table[entry.key] = text
            }
            guard table["en"] != nil else {
                error(path, "A localized string needs an en entry; it has \(table.keys.sorted().joined(separator: ", ")).")
                return nil
            }
            return .localized(table)
        default:
            return string(found, path).map(LocalizedText.plain)
        }
    }

    // MARK: Reporting

    private mutating func reportUnread(_ canonical: String, in reader: Reader) {
        guard let found = reader.peek(canonical), !Self.inertKeys.contains(canonical) else { return }
        if Self.executorFamilies[canonical] != nil {
            warn(reader.path(found), "\(found.rawKey) configures an action type this action does not have; ignored.")
        } else if let reason = Self.removedKeys[canonical] {
            warn(reader.path(found), "\(reason); ignored.")
        } else {
            warn(reader.path(found), "\(found.rawKey) is not a key this build reads; ignored.")
        }
    }

    private mutating func reportDuplicates(_ reader: Reader) {
        for duplicate in reader.dictionary.duplicates {
            let first = reader.dictionary[duplicate.canonical]?.rawKey ?? duplicate.canonical
            warn(reader.join(duplicate.rawKey), "The same key as \(first), which comes first and is the one used.")
        }
    }
}

// MARK: - Reader

extension ManifestBuilder {
    /// A dictionary being read: lookups by canonical key, and a record of which keys were read, so
    /// that the rest can be reported.
    struct Reader {
        let dictionary: NormalizedDictionary
        let path: String
        private var unread: [String]

        init(_ entries: [ConfigValue.Entry], path: String) {
            dictionary = NormalizedDictionary(entries)
            self.path = path
            unread = dictionary.keys
        }

        /// Read a key, marking it read.
        mutating func take(_ canonical: String) -> NormalizedDictionary.Found? {
            guard let found = dictionary[canonical] else { return nil }
            unread.removeAll { $0 == canonical }
            return found
        }

        /// Look at a key without reading it.
        func peek(_ canonical: String) -> NormalizedDictionary.Found? {
            dictionary[canonical]
        }

        /// Read every unread key the predicate accepts, as raw entries in the author's order.
        mutating func takeAll(where predicate: (String) -> Bool) -> [ConfigValue.Entry] {
            let taken = unread.filter(predicate)
            unread.removeAll(where: predicate)
            return taken.compactMap { canonical in
                dictionary[canonical].map { ConfigValue.Entry($0.rawKey, $0.value) }
            }
        }

        var remaining: [String] { unread }

        func path(_ found: NormalizedDictionary.Found) -> String { join(found.rawKey) }

        func path(forKey canonical: String) -> String { join(dictionary[canonical]?.rawKey ?? canonical) }

        func join(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
    }
}

extension ConfigValue {
    var isBool: Bool {
        if case .bool = self { return true }
        return false
    }
}
