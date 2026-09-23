import Foundation

/// One action an extension offers: one button on the bar (§8.3 "Action keys").
///
/// **Minimal on purpose.** This is the M1 subset — what the five bundled built-ins need and what
/// `ActionResolver` reads (FLT-1). The rest of §8.3's action keys arrive with the parser in M2
/// (`before`/`after`, `regex`, `captureHtml`, `captureRtf`, `restorePasteboard`, `submenu`,
/// `wantsInitialDisplay`, `separator`) and M3 (`pappuAfter`). They are absent rather than present and
/// ignored, because a key the model carries but nothing reads is indistinguishable, from a manifest
/// author's side, from one that works.
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
    /// Bundle identifiers. Empty means no restriction.
    public var requiredApps: [String]
    public var excludedApps: [String]
    /// BAR-4: the action asks to sit under the pointer. The placement that honours it is M4; the flag
    /// rides along from M1 so that a manifest never loses it.
    public var wantsPrimaryDisplay: Bool
    /// Keep the bar up after the action runs (§8.3).
    public var stayVisible: Bool
    /// How it runs. M1: `builtin` only, and only from the app bundle.
    public var executor: ActionExecutor

    public init(
        title: LocalizedText? = nil,
        icon: ActionIcon = .unset,
        identifier: String? = nil,
        requirements: [ActionRequirement] = [.text],
        requiredApps: [String] = [],
        excludedApps: [String] = [],
        wantsPrimaryDisplay: Bool = false,
        stayVisible: Bool = false,
        executor: ActionExecutor
    ) {
        self.title = title
        self.icon = icon
        self.identifier = identifier
        self.requirements = requirements
        self.requiredApps = requiredApps
        self.excludedApps = excludedApps
        self.wantsPrimaryDisplay = wantsPrimaryDisplay
        self.stayVisible = stayVisible
        self.executor = executor
    }

    private enum CodingKeys: String, CodingKey {
        case title, icon, identifier, requirements, requiredApps, excludedApps
        case wantsPrimaryDisplay, stayVisible, executor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(LocalizedText.self, forKey: .title)
        icon = try ActionIcon(from: container, forKey: .icon)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        requirements = try container.decodeIfPresent([ActionRequirement].self, forKey: .requirements) ?? [.text]
        requiredApps = try container.decodeIfPresent([String].self, forKey: .requiredApps) ?? []
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        wantsPrimaryDisplay = try container.decodeIfPresent(Bool.self, forKey: .wantsPrimaryDisplay) ?? false
        stayVisible = try container.decodeIfPresent(Bool.self, forKey: .stayVisible) ?? false
        executor = try container.decode(ActionExecutor.self, forKey: .executor)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try icon.encode(into: &container, forKey: .icon)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encode(requirements, forKey: .requirements)
        if !requiredApps.isEmpty { try container.encode(requiredApps, forKey: .requiredApps) }
        if !excludedApps.isEmpty { try container.encode(excludedApps, forKey: .excludedApps) }
        if wantsPrimaryDisplay { try container.encode(true, forKey: .wantsPrimaryDisplay) }
        if stayVisible { try container.encode(true, forKey: .stayVisible) }
        try container.encode(executor, forKey: .executor)
    }
}

/// One extension: a name, an identity, and the actions it offers (§8.3 "Top-level keys").
///
/// The M1 subset again. `options`, `entitlements`, `submenu`, `module`, `language`, the app keys,
/// `replaces`, `networkHosts` and the version gates are M2 and M3, and the parser that reads YAML,
/// plist and the legacy key spellings into this value is M2's `ManifestBuilder` (§9.1). What exists
/// now is the model itself and a JSON decoder for it, which is all the bundled built-ins need and all
/// `ActionResolver` reads.
public struct ExtensionManifest: Sendable, Equatable, Codable {
    public var name: LocalizedText
    /// FMT-6. `app.pappuclip.` is reserved for extensions our directory signs, and the bundled
    /// built-ins are the one thing entitled to it (`validate` enforces the pairing with the origin).
    public var identifier: String
    public var description: LocalizedText?
    /// Falls back to the first action's icon (§8.3).
    public var icon: ActionIcon
    /// Default `icon`; the user overrides it per action in the list (ALM-2a, M4).
    public var showAs: ShowAs
    public var actions: [ActionManifest]

    public enum ShowAs: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case icon, text
    }

    public init(
        name: LocalizedText,
        identifier: String,
        description: LocalizedText? = nil,
        icon: ActionIcon = .unset,
        showAs: ShowAs = .icon,
        actions: [ActionManifest]
    ) {
        self.name = name
        self.identifier = identifier
        self.description = description
        self.icon = icon
        self.showAs = showAs
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case name, identifier, description, icon, showAs, action, actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // §8.3 spells one action `action` and several `actions`. Both are read; a manifest with
        // neither has no buttons and is refused by `validate`, not here, so that the message names
        // the extension.
        var actions = try container.decodeIfPresent([ActionManifest].self, forKey: .actions) ?? []
        if let single = try container.decodeIfPresent(ActionManifest.self, forKey: .action) {
            actions.insert(single, at: 0)
        }
        self.actions = actions
        name = try container.decode(LocalizedText.self, forKey: .name)
        identifier = try container.decode(String.self, forKey: .identifier)
        description = try container.decodeIfPresent(LocalizedText.self, forKey: .description)
        icon = try ActionIcon(from: container, forKey: .icon)
        showAs = try container.decodeIfPresent(ShowAs.self, forKey: .showAs) ?? .icon
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(identifier, forKey: .identifier)
        try container.encodeIfPresent(description, forKey: .description)
        try icon.encode(into: &container, forKey: .icon)
        if showAs != .icon { try container.encode(showAs, forKey: .showAs) }
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
        guard !actions.isEmpty else {
            throw Invalid(identifier: identifier, reason: .noActions)
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
