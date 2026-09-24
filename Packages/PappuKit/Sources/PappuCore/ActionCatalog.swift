import Foundation

/// What names one action, everywhere: in the user's order, in a diagnostic, in a bar item's identity.
///
/// An action's own `identifier` is not unique — two extensions may both call one `copy` — so the key
/// is the extension's identifier and the action's together. An action with no `identifier` of its own
/// is keyed by its position in the manifest, which is stable for as long as the file is.
public struct ActionKey: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var extensionIdentifier: String
    public var action: String

    public init(extensionIdentifier: String, action: String) {
        self.extensionIdentifier = extensionIdentifier
        self.action = action
    }

    public init(extensionIdentifier: String, action: ActionManifest, at index: Int) {
        self.init(
            extensionIdentifier: extensionIdentifier,
            action: action.identifier.flatMap { $0.isEmpty ? nil : $0 } ?? String(index)
        )
    }

    public var description: String { "\(extensionIdentifier)#\(action)" }
}

/// One action as the bar and the action list see it: the manifest, plus everything §8.3's inheritance
/// rules already settled.
///
/// `title` and `icon` are resolved here rather than at each use so that the answer is arrived at once.
/// The manifest keeps what the author wrote (View Source, ALM-6), and this keeps what it means.
public struct CatalogAction: Sendable, Equatable {
    public var key: ActionKey
    public var manifest: ActionManifest
    public var origin: ManifestOrigin
    /// The extension's name, which is also an action's title when it has none of its own.
    public var extensionName: LocalizedText
    /// §8.3: the action's title, else the extension's name.
    public var title: LocalizedText
    /// §8.3's two-way inheritance, already walked: the action's icon, else the extension's, else — for
    /// the extension itself — its first action's.
    public var icon: ActionIcon
    public var showAs: ExtensionManifest.ShowAs
    /// ALM-4. Disabled actions stay in the list and keep their place; they are simply not offered.
    public var isEnabled: Bool
    /// Where the extension's files are: a script file is resolved inside it, and a shell script runs
    /// in it (§8.4). Nil for a built-in.
    public var directory: URL? = nil
    /// The installed extension this action belongs to, as its local identity's text: what the store's
    /// approval is looked up by, and what a revocation cancels running work by (SEC-4b). Nil for a
    /// built-in. Text rather than the store's type because the store is a layer above this one.
    public var owner: String? = nil
    /// The gated capabilities this action needs granted before it may run (EXM-5d, SEC-7d), worked
    /// out once, here, by `CapabilityAnalyzer.gates` — never read from what the manifest claims.
    public var gates: Set<GatedCapability> = []

    public var executor: ActionExecutor { manifest.executor }

    /// The built-in behind this action, when there is one. The one question the M1 runner asks.
    public var builtin: BuiltinAction? {
        if case .builtin(let builtin) = manifest.executor { return builtin }
        return nil
    }
}

/// Every action the app knows about, in the user's order (ALM-1).
///
/// **Uncapped, and the type is the promise.** ALM-1 is a requirement that is only ever broken by
/// accident — by a fixed-size bar, a truncating query, a `prefix(n)` somebody added to make a screen
/// look right. Keeping the catalog a plain ordered array with no capacity anywhere near it means the
/// limit would have to be introduced deliberately, and the test that closes ALM-1 builds a catalog far
/// past any bar's width and expects every last action back.
///
/// The bar's own row limit is a *layout* question (BAR-6's overflow), decided after this, over a list
/// that still holds everything.
public struct ActionCatalog: Sendable, Equatable {
    /// One extension as it was loaded.
    public struct Entry: Sendable, Equatable {
        public var manifest: ExtensionManifest
        public var origin: ManifestOrigin
        /// ALM-4, per extension in M1; per action in M4.
        public var isEnabled: Bool
        /// The installed package's folder. Nil for a built-in, which has none.
        public var directory: URL?
        /// The store's local identity for this install, as text. Nil for a built-in.
        public var owner: String?

        public init(
            manifest: ExtensionManifest,
            origin: ManifestOrigin,
            isEnabled: Bool = true,
            directory: URL? = nil,
            owner: String? = nil
        ) {
            self.manifest = manifest
            self.origin = origin
            self.isEnabled = isEnabled
            self.directory = directory
            self.owner = owner
        }
    }

    public private(set) var actions: [CatalogAction]
    private var index: [ActionKey: Int]

    public init(entries: [Entry] = []) {
        var actions: [CatalogAction] = []
        for entry in entries {
            let manifest = entry.manifest
            // §8.3: an extension with no icon of its own shows its first action's.
            let extensionIcon = manifest.icon.resolved(orInheriting: manifest.actions.first?.icon ?? .unset)
            for (offset, action) in manifest.actions.enumerated() {
                actions.append(
                    CatalogAction(
                        key: ActionKey(extensionIdentifier: manifest.identifier, action: action, at: offset),
                        manifest: action,
                        origin: entry.origin,
                        extensionName: manifest.name,
                        title: action.title ?? manifest.name,
                        icon: action.icon.resolved(orInheriting: extensionIcon),
                        showAs: manifest.showAs,
                        isEnabled: entry.isEnabled,
                        directory: entry.directory,
                        owner: entry.owner,
                        gates: CapabilityAnalyzer.gates(of: action, in: manifest)
                    )
                )
            }
        }
        self.actions = actions
        index = Dictionary(
            actions.enumerated().map { ($0.element.key, $0.offset) },
            // A duplicate key means two extensions claim one identifier, which the loader refuses
            // before it gets here. If one ever does, the first wins and the second is unreachable
            // rather than shadowing something the user already ordered.
            uniquingKeysWith: { first, _ in first }
        )
    }

    public var isEmpty: Bool { actions.isEmpty }
    public var count: Int { actions.count }

    /// ALM-4: what the resolver considers at all.
    public var enabled: [CatalogAction] {
        actions.filter(\.isEnabled)
    }

    public subscript(key: ActionKey) -> CatalogAction? {
        index[key].map { actions[$0] }
    }
}
