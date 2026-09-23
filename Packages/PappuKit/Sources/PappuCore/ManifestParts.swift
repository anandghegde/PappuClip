import Foundation

/// A `before` or `after` value (§8.6).
///
/// Closed, like `ActionRequirement`, because it is PopClip's API: an extension names one of these and
/// expects the same effect. The step pipeline that performs them is M2 week 3; until then an action
/// carrying one is read faithfully and its executor is what decides whether it runs.
public enum StepCommand: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case cut
    case copy
    case paste
    case pastePlain = "paste-plain"
    case copyResult = "copy-result"
    case pasteResult = "paste-result"
    case previewResult = "preview-result"
    case showResult = "show-result"
    case showStatus = "show-status"
    case popclipAppear = "popclip-appear"
    case copySelection = "copy-selection"

    /// §8.6's "Step" column: only the four editing commands may come before the action.
    public var isAllowedBefore: Bool {
        switch self {
        case .cut, .copy, .paste, .pastePlain: true
        default: false
        }
    }
}

/// `entitlements` (§8.3).
public enum Entitlement: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case network
    case dynamic
    case script
}

/// `authKeychain` and an option's `keychain` (§8.3, §8.9).
public enum KeychainScope: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case sync, local
}

/// `language` (§8.3), for snippets and code configs.
public enum ScriptLanguage: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case javascript, typescript, applescript
}

/// `module` (§8.3): a module file, or an override of module detection.
public enum ModuleReference: Sendable, Equatable, Hashable, Codable {
    /// A file in the package that is the extension's module.
    case file(String)
    /// `module: true` or `false`: whether a code config's own body is a module, overriding detection.
    case detection(Bool)
}

/// Where an extension's manifest identifier came from (FMT-3).
public enum IdentifierOrigin: String, Sendable, Equatable, Hashable, Codable {
    /// The manifest has an `identifier`.
    case declared
    /// It has none, so its `name` stands in. Never proof of trust, never permission to replace an
    /// installed extension with the same name (EXM-2); the store keys on `LocalIdentity` (SEC-8).
    case name
}

/// One entry in `app` or `apps` (§8.3): an application the extension works with. Metadata only — it
/// is shown in the directory and Extension Info, and filters nothing (that is `requiredApps`).
public struct AppReference: Sendable, Equatable, Hashable, Codable {
    public var name: String
    public var link: String?
    public var checkInstalled: Bool
    public var bundleIdentifiers: [String]

    public init(name: String, link: String? = nil, checkInstalled: Bool = false, bundleIdentifiers: [String] = []) {
        self.name = name
        self.link = link
        self.checkInstalled = checkInstalled
        self.bundleIdentifiers = bundleIdentifiers
    }
}

/// One entry in `options` (§8.9).
///
/// The schema, as the manifest states it. Resolving values — the user's choice over `defaultValue`
/// over the type's default — is the option model's job in M2 week 5, with the stored values it reads.
public struct OptionManifest: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case string, boolean, multiple, secret, password, heading
    }

    public enum Value: Sendable, Equatable, Hashable, Codable {
        case string(String)
        case boolean(Bool)
    }

    /// Required for every type but `heading`, which stores nothing. The storage key: renaming it
    /// loses the saved value.
    public var identifier: String?
    public var kind: Kind
    public var label: LocalizedText?
    public var description: LocalizedText?
    public var defaultValue: Value?
    /// For `multiple`.
    public var values: [String]
    public var valueLabels: [LocalizedText]
    public var multiline: Bool
    public var allowOther: Bool
    public var allowNone: Bool
    /// For `boolean`.
    public var icon: String?
    public var inset: Bool
    /// For `secret`.
    public var keychain: KeychainScope?
    public var hidden: Bool

    public init(
        identifier: String?,
        kind: Kind,
        label: LocalizedText? = nil,
        description: LocalizedText? = nil,
        defaultValue: Value? = nil,
        values: [String] = [],
        valueLabels: [LocalizedText] = [],
        multiline: Bool = false,
        allowOther: Bool = false,
        allowNone: Bool = false,
        icon: String? = nil,
        inset: Bool = false,
        keychain: KeychainScope? = nil,
        hidden: Bool = false
    ) {
        self.identifier = identifier
        self.kind = kind
        self.label = label
        self.description = description
        self.defaultValue = defaultValue
        self.values = values
        self.valueLabels = valueLabels
        self.multiline = multiline
        self.allowOther = allowOther
        self.allowNone = allowNone
        self.icon = icon
        self.inset = inset
        self.keychain = keychain
        self.hidden = hidden
    }
}
