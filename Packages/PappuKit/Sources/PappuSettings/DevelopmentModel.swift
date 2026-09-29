import Foundation
import Observation
import PappuCore
import PappuExtensions

/// DEV-1: the two developer switches. Both are off until the developer turns them on, and both only
/// ever reach an approved development folder's extension: the app reads them together with the list of
/// folders, never alone.
public final class DeveloperPreferences: Sendable {
    public static let verboseLoggingKey = "developer.verboseLogging"
    public static let webInspectorKey = "developer.webInspector"

    private let verbose: SettingsValue<Bool>
    private let inspector: SettingsValue<Bool>

    public init(storage: any SettingsStorage) {
        verbose = SettingsValue(key: Self.verboseLoggingKey, default: false, storage: storage)
        inspector = SettingsValue(key: Self.webInspectorKey, default: false, storage: storage)
    }

    public var verboseLogging: Bool { verbose.value }
    public var webInspector: Bool { inspector.value }

    public func setVerboseLogging(_ on: Bool) { verbose.set(on) }
    public func setWebInspector(_ on: Bool) { inspector.set(on) }

    /// Called after either changes, on whichever thread changed it.
    public func onChange(_ body: @escaping @Sendable () -> Void) {
        verbose.onChange { _ in body() }
        inspector.onChange { _ in body() }
    }
}

/// Settings → Developer (DEV-1), decided where a test can read it.
///
/// Every folder goes through `ExtensionLibrary`'s review; this model only says what happened. After
/// each change it calls `changed`, which is how the app rebuilds the catalog and tells the helper
/// which worlds are development worlds.
@MainActor @Observable
public final class DevelopmentModel {
    public enum Change: Sendable, Equatable {
        /// A folder was approved or reloaded: rebuild, and reload its world.
        case updated(LocalIdentity)
        case removed(LocalIdentity)
        /// A switch changed: only the helper needs telling.
        case preferences
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var identity: LocalIdentity
        public var name: String
        public var path: String
        /// What the last Reload did, until the next one.
        public var status: String?

        public var id: LocalIdentity { identity }
    }

    private let library: ExtensionLibrary
    private let preferences: DeveloperPreferences
    private let review: ExtensionLibrary.Reviewer
    private let changed: @MainActor (Change) async -> Void
    private let locale: Locale

    public private(set) var rows: [Row] = []
    public private(set) var verboseLogging: Bool
    public private(set) var webInspector: Bool
    /// The last failure, said once under whatever the developer was doing.
    public private(set) var failure: String?
    private var statuses: [LocalIdentity: String] = [:]

    public init(
        library: ExtensionLibrary,
        preferences: DeveloperPreferences,
        locale: Locale = .current,
        review: @escaping ExtensionLibrary.Reviewer,
        changed: @escaping @MainActor (Change) async -> Void = { _ in }
    ) {
        self.library = library
        self.preferences = preferences
        self.locale = locale
        self.review = review
        self.changed = changed
        verboseLogging = preferences.verboseLogging
        webInspector = preferences.webInspector
    }

    /// Whether development mode is on: at least one folder is approved. The banner and the menu's
    /// status line are drawn for exactly as long as this is true.
    public var isActive: Bool { !rows.isEmpty }

    public func refresh() async {
        do {
            var rows: [Row] = []
            for folder in try await library.developmentFolders() {
                let name = try await library.installed(folder.identity)?.manifest.name.text(for: locale)
                rows.append(Row(
                    identity: folder.identity,
                    name: name ?? folder.url.lastPathComponent,
                    path: folder.path,
                    status: statuses[folder.identity]
                ))
            }
            self.rows = rows
        } catch {
            failure = ExtensionStrings.failed(String(describing: error))
        }
    }

    /// Reviews and loads the folder at `url`.
    public func add(_ url: URL) async {
        await perform {
            guard case .installed(let identity, _) = try await self.library.approveDevelopmentFolder(url, review: self.review) else {
                return nil
            }
            return .updated(identity)
        }
    }

    public func reload(_ identity: LocalIdentity) async {
        await perform {
            let result = try await self.library.reloadDevelopmentFolder(identity, review: self.review)
            self.statuses[identity] = Self.status(for: result)
            switch result {
            case .reloaded, .approved: return .updated(identity)
            case .unchanged, .cancelled: return nil
            }
        }
    }

    public func remove(_ identity: LocalIdentity) async {
        statuses[identity] = nil
        await perform {
            try await self.library.removeDevelopmentFolder(identity)
            return .removed(identity)
        }
    }

    public func setVerboseLogging(_ on: Bool) async {
        preferences.setVerboseLogging(on)
        verboseLogging = preferences.verboseLogging
        await changed(.preferences)
    }

    public func setWebInspector(_ on: Bool) async {
        preferences.setWebInspector(on)
        webInspector = preferences.webInspector
        await changed(.preferences)
    }

    public static func status(for result: ExtensionLibrary.DevelopmentReload) -> String {
        switch result {
        case .unchanged: DeveloperStrings.unchanged
        case .reloaded: DeveloperStrings.reloaded
        case .approved: DeveloperStrings.approved
        case .cancelled: DeveloperStrings.cancelled
        }
    }

    private func perform(_ work: @escaping () async throws -> Change?) async {
        var change: Change?
        do {
            change = try await work()
            failure = nil
        } catch {
            failure = ExtensionStrings.failed(String(describing: error))
        }
        await refresh()
        if let change { await changed(change) }
    }
}
