import Foundation

/// One action an extension offers: one button on the bar (§8.3 "Action keys").
///
/// Everything §8.3 lists except three families, each absent for a reason rather than forgotten:
/// `submenu`, `separator` and `wantsInitialDisplay` are the bar's submenus, which are M4 (BAR-5a), and
/// `ManifestBuilder` refuses a manifest that depends on one rather than flattening it into something
/// its author did not write; `pappuAfter` is M3's rich result, refused the same way until then.
public struct ActionManifest: Sendable, Equatable, Codable {
    /// Defaults to the extension's name (§8.3). Held as written so that View Source shows what the
    /// author wrote, and resolved against the extension only when the action is built.
    public var title: LocalizedText?
    /// An icon specifier (§8.11). `nil` in the file means "no icon key"; an explicit JSON `null`
    /// means the author asked for no icon at all, which §8.3 distinguishes and `ActionIcon` keeps.
    public var icon: ActionIcon
    /// The action's own identifier, passed to scripts. Not unique by itself: uniqueness is the
    /// extension identifier plus this (see `ActionKey`).
    public var identifier: String?
    /// §8.5 step 2. Defaults to `[text]` when the key is absent; an explicit empty list means none.
    public var requirements: [ActionRequirement]
    /// §8.5 step 4: ICU syntax, applied to what step 3 left. Checked to compile at load.
    public var regex: String?
    /// Bundle identifiers. Empty means no restriction.
    public var requiredApps: [String]
    public var excludedApps: [String]
    /// §8.6. `before` is one of the four editing commands; `after` is any of them.
    public var before: StepCommand?
    public var after: StepCommand?
    /// BAR-4: the action asks to sit under the pointer. The placement that honours it is M4; the flag
    /// rides along from M1 so that a manifest never loses it.
    public var wantsPrimaryDisplay: Bool
    /// Keep the bar up after the action runs (§8.3).
    public var stayVisible: Bool
    /// Capture HTML and Markdown, or RTF, with the selection (FLT-4). The bar reads the selection's
    /// style through Accessibility only when an action on it asks; an app that gives no style gives the
    /// plain text in each form, which is FLT-4's last fallback.
    public var captureHTML: Bool
    public var captureRTF: Bool
    /// Applies to `paste-result` (§8.3).
    public var restorePasteboard: Bool
    /// How it runs. Whether this build *can* run it is `ActionResolver`'s question.
    public var executor: ActionExecutor

    public init(
        title: LocalizedText? = nil,
        icon: ActionIcon = .unset,
        identifier: String? = nil,
        requirements: [ActionRequirement] = [.text],
        regex: String? = nil,
        requiredApps: [String] = [],
        excludedApps: [String] = [],
        before: StepCommand? = nil,
        after: StepCommand? = nil,
        wantsPrimaryDisplay: Bool = false,
        stayVisible: Bool = false,
        captureHTML: Bool = false,
        captureRTF: Bool = false,
        restorePasteboard: Bool = false,
        executor: ActionExecutor
    ) {
        self.title = title
        self.icon = icon
        self.identifier = identifier
        self.requirements = requirements
        self.regex = regex
        self.requiredApps = requiredApps
        self.excludedApps = excludedApps
        self.before = before
        self.after = after
        self.wantsPrimaryDisplay = wantsPrimaryDisplay
        self.stayVisible = stayVisible
        self.captureHTML = captureHTML
        self.captureRTF = captureRTF
        self.restorePasteboard = restorePasteboard
        self.executor = executor
    }

    // The stored form: the app's own JSON, not PopClip's config format (that is `ManifestBuilder`).
    // Defaults are left out when encoding and filled in when decoding, so that the bundled built-ins
    // stay as short as they are.
    private enum CodingKeys: String, CodingKey {
        case title, icon, identifier, requirements, regex, requiredApps, excludedApps, before, after
        case wantsPrimaryDisplay, stayVisible, captureHTML, captureRTF, restorePasteboard, executor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(LocalizedText.self, forKey: .title)
        icon = try ActionIcon(from: container, forKey: .icon)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        requirements = try container.decodeIfPresent([ActionRequirement].self, forKey: .requirements) ?? [.text]
        regex = try container.decodeIfPresent(String.self, forKey: .regex)
        requiredApps = try container.decodeIfPresent([String].self, forKey: .requiredApps) ?? []
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        before = try container.decodeIfPresent(StepCommand.self, forKey: .before)
        after = try container.decodeIfPresent(StepCommand.self, forKey: .after)
        wantsPrimaryDisplay = try container.decodeIfPresent(Bool.self, forKey: .wantsPrimaryDisplay) ?? false
        stayVisible = try container.decodeIfPresent(Bool.self, forKey: .stayVisible) ?? false
        captureHTML = try container.decodeIfPresent(Bool.self, forKey: .captureHTML) ?? false
        captureRTF = try container.decodeIfPresent(Bool.self, forKey: .captureRTF) ?? false
        restorePasteboard = try container.decodeIfPresent(Bool.self, forKey: .restorePasteboard) ?? false
        executor = try container.decode(ActionExecutor.self, forKey: .executor)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try icon.encode(into: &container, forKey: .icon)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encode(requirements, forKey: .requirements)
        try container.encodeIfPresent(regex, forKey: .regex)
        if !requiredApps.isEmpty { try container.encode(requiredApps, forKey: .requiredApps) }
        if !excludedApps.isEmpty { try container.encode(excludedApps, forKey: .excludedApps) }
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        if wantsPrimaryDisplay { try container.encode(true, forKey: .wantsPrimaryDisplay) }
        if stayVisible { try container.encode(true, forKey: .stayVisible) }
        if captureHTML { try container.encode(true, forKey: .captureHTML) }
        if captureRTF { try container.encode(true, forKey: .captureRTF) }
        if restorePasteboard { try container.encode(true, forKey: .restorePasteboard) }
        try container.encode(executor, forKey: .executor)
    }
}

/// One extension: a name, an identity, and the actions it offers (§8.3 "Top-level keys").
///
/// Built from PopClip's config format by `ManifestBuilder` (FMT-1–6), and stored in the app's own JSON
/// by `Codable`. The two are different formats on purpose: the config format has a decade of
/// spellings and inheritance rules, and the stored form has none, so that what the store holds means
/// one thing.
///
/// Not here: `submenu` (M4, refused at load until then) and `shellScriptRationale` (for the directory,
/// ignored by the app). A module extension's own actions exist only once the helper has described its
/// module (JS-12): loaded from its files alone, its manifest has `moduleSource` set and may have no
/// actions; loaded again with its `ModuleExports`, it has them.
public struct ExtensionManifest: Sendable, Equatable, Codable {
    public var name: LocalizedText
    /// FMT-6. `app.pappuclip.` is reserved for extensions our directory signs, and the bundled
    /// built-ins are the one thing entitled to it (`validate` enforces the pairing with the origin).
    public var identifier: String
    /// FMT-3: whether `identifier` was written or stands in for a missing one.
    public var identifierOrigin: IdentifierOrigin
    public var description: LocalizedText?
    /// Falls back to the first action's icon (§8.3).
    public var icon: ActionIcon
    /// Default `icon`; the user overrides it per action in the list (ALM-2a, M4).
    public var showAs: ShowAs
    /// Space-separated, for directory search.
    public var keywords: String?
    /// Minimum macOS, as written (`"13.0"`).
    public var macosVersion: String?
    /// §8.1's API-level gate, checked by `ManifestBuilder` against `APILevel`.
    public var popclipVersion: Int?
    public var pappuclipVersion: Int?
    public var options: [OptionManifest]
    public var entitlements: [Entitlement]
    public var authServiceLabel: LocalizedText?
    public var authKeychain: KeychainScope?
    /// Nil means §8.3's default: true if the extension has options.
    public var offersMultipleInstances: Bool?
    public var module: ModuleReference?
    /// JS-12: the module the helper runs, when this is a module extension. Worked out by
    /// `ManifestBuilder` from `module` and a code config's own text.
    public var moduleSource: ModuleSource?
    public var language: ScriptLanguage?
    public var apps: [AppReference]
    /// Native-only. Never sufficient by itself to transfer ownership, grants or secrets (SEC-8).
    public var replaces: String?
    /// Native-only. The hosts network requests may reach (SEC-6).
    public var networkHosts: [String]
    public var actions: [ActionManifest]

    public enum ShowAs: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case icon, text
    }

    public init(
        name: LocalizedText,
        identifier: String,
        identifierOrigin: IdentifierOrigin = .declared,
        description: LocalizedText? = nil,
        icon: ActionIcon = .unset,
        showAs: ShowAs = .icon,
        keywords: String? = nil,
        macosVersion: String? = nil,
        popclipVersion: Int? = nil,
        pappuclipVersion: Int? = nil,
        options: [OptionManifest] = [],
        entitlements: [Entitlement] = [],
        authServiceLabel: LocalizedText? = nil,
        authKeychain: KeychainScope? = nil,
        offersMultipleInstances: Bool? = nil,
        module: ModuleReference? = nil,
        moduleSource: ModuleSource? = nil,
        language: ScriptLanguage? = nil,
        apps: [AppReference] = [],
        replaces: String? = nil,
        networkHosts: [String] = [],
        actions: [ActionManifest]
    ) {
        self.name = name
        self.identifier = identifier
        self.identifierOrigin = identifierOrigin
        self.description = description
        self.icon = icon
        self.showAs = showAs
        self.keywords = keywords
        self.macosVersion = macosVersion
        self.popclipVersion = popclipVersion
        self.pappuclipVersion = pappuclipVersion
        self.options = options
        self.entitlements = entitlements
        self.authServiceLabel = authServiceLabel
        self.authKeychain = authKeychain
        self.offersMultipleInstances = offersMultipleInstances
        self.module = module
        self.moduleSource = moduleSource
        self.language = language
        self.apps = apps
        self.replaces = replaces
        self.networkHosts = networkHosts
        self.actions = actions
    }

    /// §8.3's default for `offersMultipleInstances`.
    public var effectiveOffersMultipleInstances: Bool {
        offersMultipleInstances ?? !options.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case name, identifier, identifierOrigin, description, icon, showAs, keywords, macosVersion
        case popclipVersion, pappuclipVersion, options, entitlements, authServiceLabel, authKeychain
        case offersMultipleInstances, module, moduleSource, language, apps, replaces, networkHosts, action, actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One action is `action` and several are `actions`. Both are read; a manifest with neither
        // has no buttons and is refused by `validate`, not here, so that the message names the
        // extension.
        var actions = try container.decodeIfPresent([ActionManifest].self, forKey: .actions) ?? []
        if let single = try container.decodeIfPresent(ActionManifest.self, forKey: .action) {
            actions.insert(single, at: 0)
        }
        self.actions = actions
        name = try container.decode(LocalizedText.self, forKey: .name)
        identifier = try container.decode(String.self, forKey: .identifier)
        identifierOrigin = try container.decodeIfPresent(IdentifierOrigin.self, forKey: .identifierOrigin) ?? .declared
        description = try container.decodeIfPresent(LocalizedText.self, forKey: .description)
        icon = try ActionIcon(from: container, forKey: .icon)
        showAs = try container.decodeIfPresent(ShowAs.self, forKey: .showAs) ?? .icon
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords)
        macosVersion = try container.decodeIfPresent(String.self, forKey: .macosVersion)
        popclipVersion = try container.decodeIfPresent(Int.self, forKey: .popclipVersion)
        pappuclipVersion = try container.decodeIfPresent(Int.self, forKey: .pappuclipVersion)
        options = try container.decodeIfPresent([OptionManifest].self, forKey: .options) ?? []
        entitlements = try container.decodeIfPresent([Entitlement].self, forKey: .entitlements) ?? []
        authServiceLabel = try container.decodeIfPresent(LocalizedText.self, forKey: .authServiceLabel)
        authKeychain = try container.decodeIfPresent(KeychainScope.self, forKey: .authKeychain)
        offersMultipleInstances = try container.decodeIfPresent(Bool.self, forKey: .offersMultipleInstances)
        module = try container.decodeIfPresent(ModuleReference.self, forKey: .module)
        moduleSource = try container.decodeIfPresent(ModuleSource.self, forKey: .moduleSource)
        language = try container.decodeIfPresent(ScriptLanguage.self, forKey: .language)
        apps = try container.decodeIfPresent([AppReference].self, forKey: .apps) ?? []
        replaces = try container.decodeIfPresent(String.self, forKey: .replaces)
        networkHosts = try container.decodeIfPresent([String].self, forKey: .networkHosts) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(identifier, forKey: .identifier)
        if identifierOrigin != .declared { try container.encode(identifierOrigin, forKey: .identifierOrigin) }
        try container.encodeIfPresent(description, forKey: .description)
        try icon.encode(into: &container, forKey: .icon)
        if showAs != .icon { try container.encode(showAs, forKey: .showAs) }
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encodeIfPresent(macosVersion, forKey: .macosVersion)
        try container.encodeIfPresent(popclipVersion, forKey: .popclipVersion)
        try container.encodeIfPresent(pappuclipVersion, forKey: .pappuclipVersion)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        if !entitlements.isEmpty { try container.encode(entitlements, forKey: .entitlements) }
        try container.encodeIfPresent(authServiceLabel, forKey: .authServiceLabel)
        try container.encodeIfPresent(authKeychain, forKey: .authKeychain)
        try container.encodeIfPresent(offersMultipleInstances, forKey: .offersMultipleInstances)
        try container.encodeIfPresent(module, forKey: .module)
        try container.encodeIfPresent(moduleSource, forKey: .moduleSource)
        try container.encodeIfPresent(language, forKey: .language)
        if !apps.isEmpty { try container.encode(apps, forKey: .apps) }
        try container.encodeIfPresent(replaces, forKey: .replaces)
        if !networkHosts.isEmpty { try container.encode(networkHosts, forKey: .networkHosts) }
        try container.encode(actions, forKey: .actions)
    }

    // MARK: Validation

    public struct Invalid: Error, CustomStringConvertible, Equatable {
        public enum Reason: Sendable, Equatable {
            case noActions
            /// A manifest that is not the app's own named the reserved executor (architecture §19
            /// item 2). The one rule that makes the executor safe to have.
            case reservedExecutor(BuiltinAction)
            /// FMT-6: `app.pappuclip.` belongs to extensions our directory signs.
            case reservedIdentifierPrefix
            case emptyIdentifier
            case emptyName
            /// FMT-6's character rules.
            case malformedIdentifier(ExtensionIdentifier.Problem)
        }

        public var identifier: String
        public var reason: Reason

        public var description: String {
            switch reason {
            case .noActions:
                "\(identifier) has no actions."
            case .reservedExecutor(let builtin):
                "\(identifier) asks for the reserved `builtin` executor (\(builtin.rawValue)), which only the app's own bundle may name."
            case .reservedIdentifierPrefix:
                "\(identifier) uses the reserved identifier prefix \(ProductIdentity.reservedExtensionIdentifierPrefix)."
            case .emptyIdentifier:
                "An extension manifest has an empty identifier."
            case .emptyName:
                "\(identifier) has an empty name."
            case .malformedIdentifier(let problem):
                "The identifier \"\(identifier)\" \(problem)."
            }
        }
    }

    /// The checks that cannot be expressed in the type, run once per manifest at load.
    ///
    /// The reserved-executor rule is the one worth naming: `builtin` is a native implementation
    /// chosen by a string in a file, so anything but the app's own bundle naming it would be an
    /// arbitrary-code-selection bug with a friendly face. The check is on the **origin**, which the
    /// loader knows and the file cannot say, and never on the identifier, which the file can.
    public func validate(origin: ManifestOrigin) throws {
        guard !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Invalid(identifier: identifier, reason: .emptyIdentifier)
        }
        guard !name.english.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Invalid(identifier: identifier, reason: .emptyName)
        }
        // A module's actions come from running it (JS-12), so a module may declare none of its own.
        guard !actions.isEmpty || module != nil else {
            throw Invalid(identifier: identifier, reason: .noActions)
        }
        if identifierOrigin == .declared, let problem = ExtensionIdentifier.problem(with: identifier) {
            throw Invalid(identifier: identifier, reason: .malformedIdentifier(problem))
        }
        if origin != .appBundle {
            if identifier.hasPrefix(ProductIdentity.reservedExtensionIdentifierPrefix) {
                throw Invalid(identifier: identifier, reason: .reservedIdentifierPrefix)
            }
            for action in actions {
                if case .builtin(let builtin) = action.executor {
                    throw Invalid(identifier: identifier, reason: .reservedExecutor(builtin))
                }
            }
        }
    }
}
