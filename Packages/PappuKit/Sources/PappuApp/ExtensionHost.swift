import Foundation
import PappuCore
import PappuExtensions
import PappuSettings
import Synchronization

/// The installed extensions as the bar sees them: one catalog, one table of approvals and one table of
/// option values, replaced together (EXM-5, SEC-4b, §8.9).
///
/// **Why one snapshot.** The bridge asks three questions per appearance — what is there, what may run,
/// and what the options say — inside the auto-appear budget, where a trip to the store is not allowed
/// (§4.7). Each answer is read from memory, and all three come from the same reload: a catalog built
/// after a revocation beside an approvals table from before it would draw a button the resolver then
/// approves.
///
/// **Why a reload is the only writer.** Everything that changes an extension goes through the store
/// first — an install, a grant, a revocation, an option — and then calls `reload`. The snapshot is a
/// cache of the store, never a second place a decision is made; a snapshot that failed to load keeps
/// the built-ins and nothing else, because an extension whose approval could not be read has none.
///
/// **What a revocation reaches.** `handle(_:)` reloads before it cancels, so the bar cannot draw the
/// revoked extension's buttons again in the gap between the two, and then invalidates its running
/// invocations on the cancellation path (SEC-4b). Their next checkpoint finds them cancelled.
///
/// Two installs of one manifest identifier share an `ActionKey` and an options key. The catalog keeps
/// the first, as it does for any duplicate key; the second is listed in Settings and does not reach
/// the bar until the first is uninstalled. Per-install keys are ALM-2a's, in M4.
public final class ExtensionHost: Sendable {
    public struct Snapshot: Sendable {
        public var catalog: ActionCatalog
        public var approvals: [LocalIdentity: ExecutionApproval]
        /// Keyed by manifest identifier, then option id, as `ActionResolver.resolve` takes it. No
        /// secrets: the matcher never sees them.
        public var options: [String: [String: String]]
        /// Keyed by `LocalIdentity.description`, which is how a catalog action names its owner.
        public var installed: [String: InstalledExtension]
    }

    public let library: ExtensionLibrary
    public let secrets: any SecretStore
    private let builtins: [ActionCatalog.Entry]
    private let invalidate: @Sendable (String) async -> Void
    private let state: Mutex<Snapshot>

    /// - Parameter invalidate: cancels whatever the named owner is running (`InvocationManager`).
    public init(
        library: ExtensionLibrary,
        secrets: any SecretStore,
        builtins: [ActionCatalog.Entry],
        invalidate: @escaping @Sendable (String) async -> Void
    ) {
        self.library = library
        self.secrets = secrets
        self.builtins = builtins
        self.invalidate = invalidate
        state = Mutex(Snapshot(catalog: ActionCatalog(entries: builtins), approvals: [:], options: [:], installed: [:]))
    }

    // MARK: Reading, for the bridge

    public var snapshot: Snapshot { state.withLock { $0 } }
    public var catalog: ActionCatalog { state.withLock(\.catalog) }
    public var options: [String: [String: String]] { state.withLock(\.options) }

    /// The resolver's question (EXM-5g for built-ins, the store's answer for the rest).
    public func approval(for action: CatalogAction) -> ExecutionApproval? {
        if let bundled = ExecutionApproval.bundled(action) { return bundled }
        guard let owner = action.owner, let identity = LocalIdentity(owner) else { return nil }
        return state.withLock { $0.approvals[identity] }
    }

    /// What a run is handed: every option's value, the Keychain's included (§8.9, SEC-3). Read at the
    /// click, not at the appearance, so a secret is fetched only for something that is about to run.
    public func runtimeOptions(for action: CatalogAction) -> [String: String] {
        guard let owner = action.owner, let installed = state.withLock({ $0.installed[owner] }) else { return [:] }
        let secrets = installed.instance.map {
            self.secrets.secrets(for: installed.manifest.options, of: $0, owner: installed.identity)
        } ?? [:]
        return OptionValues.effective(installed.manifest.options, stored: installed.storedOptions, secrets: secrets)
    }

    // MARK: Changing

    /// Launch: finish or undo whatever an interrupted install left behind, list the built-ins, and read
    /// everything back.
    public func start() async {
        _ = try? await library.recover()
        _ = try? await library.store.seedBuiltins(builtins.map(\.manifest))
        await reload()
    }

    /// Reads the store again and replaces the snapshot in one step.
    public func reload() async {
        guard let installed = try? await library.installed() else {
            state.withLock { $0 = Self.snapshot(builtins: builtins, installed: []) }
            return
        }
        let next = Self.snapshot(builtins: builtins, installed: installed.extensions)
        state.withLock { $0 = next }
    }

    /// Settings changed something: rebuild, and for anything taken away, stop what it is running.
    public func handle(_ change: ExtensionsModel.Change) async {
        await reload()
        switch change {
        case .updated: break
        case .revoked(let identity), .removed(let identity): await invalidate(identity.description)
        }
    }

    /// Every file the app was asked to open, one review at a time (EXM-1, EXM-5). A file that is not an
    /// extension is skipped rather than reported; the Finder only sends the types the app declares.
    public func install(
        _ urls: [URL],
        review: @escaping ExtensionLibrary.Reviewer
    ) async -> [Result<ExtensionLibrary.Outcome, any Error>] {
        await install(sources: urls.compactMap(ExtensionLibrary.Source.file), review: review)
    }

    /// Files, or text selected in another app (EXM-2), each through the same review.
    public func install(
        sources: [ExtensionLibrary.Source],
        review: @escaping ExtensionLibrary.Reviewer
    ) async -> [Result<ExtensionLibrary.Outcome, any Error>] {
        var results: [Result<ExtensionLibrary.Outcome, any Error>] = []
        for source in sources {
            do {
                results.append(.success(try await library.install(source, route: .manual, review: review)))
            } catch {
                results.append(.failure(error))
            }
            // After each one, so that a second file's review can name the first as a collision.
            await reload()
        }
        return results
    }

    static func snapshot(builtins: [ActionCatalog.Entry], installed: [InstalledExtension]) -> Snapshot {
        var entries = builtins
        var approvals: [LocalIdentity: ExecutionApproval] = [:]
        var options: [String: [String: String]] = [:]
        var byOwner: [String: InstalledExtension] = [:]
        for installed in installed {
            entries.append(ActionCatalog.Entry(
                manifest: installed.manifest,
                origin: .installed,
                // Pending approval is still "on": the resolver refuses it as `.notApproved`, which is
                // the reason the inspector should give, rather than as `.disabled`.
                isEnabled: installed.record.state != .disabled,
                directory: installed.directory,
                owner: installed.identity.description
            ))
            if let approval = installed.approval { approvals[installed.identity] = approval }
            // The first install of an identifier keeps it, as in the catalog.
            if options[installed.manifest.identifier] == nil {
                options[installed.manifest.identifier] = OptionValues.effective(
                    installed.manifest.options,
                    stored: installed.storedOptions
                )
            }
            byOwner[installed.identity.description] = installed
        }
        return Snapshot(catalog: ActionCatalog(entries: entries), approvals: approvals, options: options, installed: byOwner)
    }
}
