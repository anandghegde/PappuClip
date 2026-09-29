import Foundation
import PappuCore

/// Installing, uninstalling and recovering extensions: architecture §9.4's pipeline, over the files
/// in `Extensions/` and the rows in `ExtensionStore`.
///
/// ```
/// stage → validate → resolve identity → review → activate → retire
/// ```
///
/// **Atomic without a shared transaction.** The files and the rows cannot commit together, so the
/// order does the work: a version's folder is renamed into `Extensions/<identity>/<digest>/` (one
/// `rename(2)`, on the same volume as `Staging/`), *then* the store commits the row that points at it,
/// *then* folders no row points at any more are deleted. A kill at any point leaves either a folder
/// with no row or a row whose superseded folder is still there, and `recover()` — which runs before
/// anything reads the store — removes whatever no row points at. So a killed install leaves no trace,
/// and a killed replacement leaves the old version intact.
public actor ExtensionLibrary {
    /// Where everything lives. The app uses `standard`; tests use a temporary folder.
    public struct Paths: Sendable, Equatable {
        public var root: URL

        public init(root: URL) {
            self.root = root
        }

        /// `~/Library/Application Support/PappuClip/`.
        public static var standard: Paths {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return Paths(root: support.appending(path: ProductIdentity.appName, directoryHint: .isDirectory))
        }

        public var extensions: URL { root.appending(path: "Extensions", directoryHint: .isDirectory) }
        /// On the same volume as `extensions`, so that activation is a rename and not a copy.
        public var staging: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }
        /// FMT-7: one SQLite file for everything the app remembers about extensions and the list.
        public var database: URL { root.appending(path: "Store/pappuclip.sqlite") }

        public func folder(_ version: VersionFolder) -> URL {
            extensions
                .appending(path: version.identity.description, directoryHint: .isDirectory)
                .appending(path: version.digest.hex, directoryHint: .isDirectory)
        }
    }

    /// Something to install.
    public enum Source: Sendable, Equatable {
        /// A `.pappuext` or `.popclipext` folder.
        case packageFolder(URL)
        /// A `.pappuextz` or `.popclipextz` archive, deleted after a successful install (EXM-1).
        case zippedPackage(URL)
        /// A `.pappucliptxt` or `.popcliptxt` file, or a `.js`, `.ts` or `.yaml` one (EXM-3). Each is read
        /// as snippet text, so a file with no marker is refused as one.
        case snippetFile(URL)
        /// Selected text, through the bar's Install Extension action (EXM-2).
        case selectedText(String)
        /// A package folder in PopClip's `Extensions/`, through Import from PopClip (EXM-11). Staged as
        /// a folder is; only its origin differs.
        case popClipPackage(URL)
        /// A package folder a developer approved for development (DEV-1), copied like `packageFolder`
        /// every time it is loaded. Never made by `file(_:)`: only the Developer settings name one.
        case developmentFolder(URL)

        /// Which source a file is, by its extension; nil for anything that is not an extension.
        public static func file(_ url: URL) -> Source? {
            let suffix = url.pathExtension.lowercased()
            if ProductIdentity.FileExtension.package.contains(suffix) { return .packageFolder(url) }
            if ProductIdentity.FileExtension.zippedPackage.contains(suffix) { return .zippedPackage(url) }
            if ProductIdentity.FileExtension.snippet.contains(suffix) { return .snippetFile(url) }
            if ProductIdentity.FileExtension.codeSnippet.contains(suffix) { return .snippetFile(url) }
            return nil
        }

        var origin: LocalOrigin {
            switch self {
            case .packageFolder, .zippedPackage: .packageFile
            case .popClipPackage: .popClipImport
            case .snippetFile: .snippetFile
            case .selectedText: .selectedText
            case .developmentFolder: .developmentFolder
            }
        }
    }

    /// What the review sheet is shown (EXM-5, SEC-8c).
    public struct Proposal: Sendable, Equatable {
        public var manifest: ExtensionManifest
        public var warnings: [ManifestDiagnostic]
        public var provenance: Provenance
        public var digest: ContentDigest
        public var decision: IdentityResolver.Decision
        /// EXM-5b: worked out from the staged files, never from what the manifest says about itself.
        public var capabilities: CapabilitySet
    }

    /// The user's answer to a `Proposal`.
    public enum Answer: Sendable, Equatable {
        /// Install it: as the next version of the offered identity if the decision was
        /// `replacementOffered`, and otherwise as a new, separate identity.
        case install
        /// Install it separately even though a replacement was offered.
        case installSeparately
        /// Replace this installed extension by a trust transition (SEC-8e). Only for a collision that
        /// allows one.
        case replaceByTrustTransition(LocalIdentity)
        case cancel
    }

    /// The answer, and which gated capabilities the user turned on with it (EXM-5c, EXM-5d).
    ///
    /// **Nothing gated unless named.** Every static member here grants nothing, so a reviewer that only
    /// says "install" — a test, a route that has no sheet, a sheet whose toggles were never touched —
    /// installs with every gate at "Don't Allow". Granting takes `install(granting:)`, and even then
    /// only gates the proposal actually listed are kept.
    public struct Consent: Sendable, Equatable {
        public var answer: Answer
        public var granted: Set<GatedCapability>

        public init(_ answer: Answer, granting granted: Set<GatedCapability> = []) {
            self.answer = answer
            self.granted = granted
        }

        public static let install = Consent(.install)
        public static let installSeparately = Consent(.installSeparately)
        public static let cancel = Consent(.cancel)

        public static func replaceByTrustTransition(_ identity: LocalIdentity) -> Consent {
            Consent(.replaceByTrustTransition(identity))
        }

        public static func install(granting gates: Set<GatedCapability>) -> Consent {
            Consent(.install, granting: gates)
        }
    }

    /// Asks the user. The app shows a sheet; tests answer directly.
    public typealias Reviewer = @Sendable (Proposal) async -> Consent

    public enum Outcome: Sendable, Equatable {
        case installed(LocalIdentity, replaced: LocalIdentity?)
        case updated(LocalIdentity)
        case alreadyInstalled(LocalIdentity)
        case cancelled
    }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case notAnExtension(String)
        case selectionTooLong(Int)
        case staging(PackageStaging.Failure)
        case invalid(ManifestLoadFailure)
        case answerNotOffered
        case busy

        public var description: String {
            switch self {
            case .unreadable(let reason), .notAnExtension(let reason): reason
            case .selectionTooLong(let count):
                "The selection is \(count) characters; an extension can be installed from at most \(SnippetDetector.maximumSelectionLength)."
            case .staging(let failure): failure.description
            case .invalid(let failure): failure.description
            case .answerNotOffered: "That choice was not one the review offered."
            case .busy: "Another install is in progress."
            }
        }
    }

    /// Points in an install at which a test takes a copy of everything on disk, to see what a kill
    /// there would have left.
    public enum Checkpoint: Sendable, Equatable, CaseIterable {
        case staged
        case moved
        case committed
    }

    public nonisolated let paths: Paths
    public nonisolated let store: ExtensionStore
    let checkpoint: @Sendable (Checkpoint) -> Void
    var installing = false
    /// JS-12: what approved module extensions' modules exported, by the bytes they were described from.
    /// Kept for the life of the app; a module is described again at the next launch.
    var moduleExports: [ModuleKey: ModuleExports] = [:]

    struct ModuleKey: Hashable {
        var identity: LocalIdentity
        var digest: ContentDigest
    }

    /// JS-12: remembers what the helper said a module exported. `installed()` reads it into the
    /// extension's manifest from then on, for these bytes only: an update is described again.
    public func remember(_ exports: ModuleExports, for identity: LocalIdentity, digest: ContentDigest) {
        moduleExports[ModuleKey(identity: identity, digest: digest)] = exports
    }

    /// EXM-5f: reads an extension's JavaScript for the host methods it can reach. Nil in tests that do
    /// not give one, and then every script is unbounded, as it was before there was a scan.
    private let scanner: (any CodeScanning)?
    /// What the scan found, by the bytes it read. Kept for the life of the app, like `moduleExports`: the
    /// same bytes always scan the same, and the next launch scans them again. A failed scan is not kept.
    var codeScans: [ModuleKey: CodeScan] = [:]

    /// What the scan finds in `manifest`'s JavaScript, from `key`'s bytes when they were scanned before.
    /// Nil for an extension with no JavaScript, and when there is no scanner or it could not scan.
    func codeScan(_ manifest: ExtensionManifest, in directory: URL, key: ModuleKey?) async -> CodeScan? {
        guard manifest.hasJavaScript || manifest.module != nil, let scanner else { return nil }
        if let key, let known = codeScans[key] { return known }
        let scan = await scanner.scan(manifest, in: directory)
        if let key, let scan { codeScans[key] = scan }
        return scan
    }

    public init(
        paths: Paths,
        scanner: (any CodeScanning)? = nil,
        checkpoint: @escaping @Sendable (Checkpoint) -> Void = { _ in }
    ) throws {
        self.paths = paths
        self.scanner = scanner
        self.checkpoint = checkpoint
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.extensions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        store = try ExtensionStore(at: paths.database)
    }

    // MARK: Recovery

    public struct Recovery: Sendable, Equatable {
        /// Staging folders removed: installs that never activated.
        public var staged: Int
        /// Version folders no row pointed at: installs killed between the rename and the commit, or
        /// retirements killed after the commit.
        public var orphaned: [String]
    }

    /// Put the files back in step with the store. Run once at launch, before anything else reads either.
    @discardableResult
    public func recover() async throws -> Recovery {
        let fileManager = FileManager.default
        var recovery = Recovery(staged: 0, orphaned: [])
        for entry in try fileManager.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: entry)
            recovery.staged += 1
        }
        let referenced = try await store.versionFolders()
        for identityFolder in try fileManager.contentsOfDirectory(at: paths.extensions, includingPropertiesForKeys: nil) {
            let identity = LocalIdentity(identityFolder.lastPathComponent)
            for versionFolder in (try? fileManager.contentsOfDirectory(at: identityFolder, includingPropertiesForKeys: nil)) ?? [] {
                let version = identity.map { VersionFolder(identity: $0, digest: ContentDigest(hex: versionFolder.lastPathComponent)) }
                if version.map(referenced.contains) != true {
                    try fileManager.removeItem(at: versionFolder)
                    recovery.orphaned.append("\(identityFolder.lastPathComponent)/\(versionFolder.lastPathComponent)")
                }
            }
            try removeIfEmpty(identityFolder)
        }
        return recovery
    }

    // MARK: Install

    /// The whole pipeline. Staging is removed on every path out except success, which moves it.
    public func install(_ source: Source, route: IdentityResolver.Route = .manual, review: Reviewer) async throws -> Outcome {
        // One at a time: the review awaits the user, and a second install resolved against the same
        // rows could otherwise decide something the first one's commit makes untrue.
        guard !installing else { throw InstallError.busy }
        installing = true
        defer { installing = false }

        let staging = newStaging()
        defer { try? FileManager.default.removeItem(at: staging) }

        let prepared = try await prepare(source, into: staging, route: route)
        if case .alreadyInstalled(let identity) = prepared.proposal.decision {
            try deleteArchive(source)
            return .alreadyInstalled(identity)
        }
        let consent = await review(prepared.proposal)
        return try await commit(prepared, consent: consent, approved: true)
    }

    // MARK: Several at once (EXM-15)

    /// What a batch review decided for one extension (EXM-15b–d).
    public enum BatchApproval: Sendable, Equatable {
        /// Installed and approved, with these gates. A listed-only extension is approved this way by the
        /// sheet's one confirmation; a gated one only when the user switched it on.
        case approve(granting: Set<GatedCapability>)
        /// Installed, but waiting: no grant, no code, until Extension Info's Approve (EXM-15d).
        case leaveUnapproved
        /// Not installed at all.
        case skip
    }

    /// Shown every proposal at once; answers one `BatchApproval` per proposal, in the same order, or nil
    /// to install nothing. An answer list of the wrong length installs nothing either.
    public typealias BatchReviewer = @Sendable ([Proposal]) async -> [BatchApproval]?

    /// What happened to one source of a batch. A source the review was shown and then skipped, or a
    /// batch the review cancelled, is `.cancelled`.
    public struct BatchEntry: Sendable {
        public var source: Source
        public var result: Result<Outcome, any Error>
        /// Whether the review approved it: false for one installed but left waiting (EXM-15d), nil
        /// for one the review never activated.
        public var approved: Bool?

        public init(source: Source, result: Result<Outcome, any Error>, approved: Bool? = nil) {
            self.source = source
            self.result = result
            self.approved = approved
        }
    }

    /// Several extensions arriving together — Import from PopClip, and later a configuration import or
    /// a sync (EXM-11, EXM-15a) — staged and analysed first, then reviewed on one sheet, then activated.
    ///
    /// A source that cannot be staged is reported and left out of the review; one that is already
    /// installed is reported and not shown. The rest are resolved on the batch route, so nothing offers
    /// to replace anything (EXM-2), and each is activated with the answer the sheet gave it.
    public func installBatch(_ sources: [Source], review: BatchReviewer) async throws -> [BatchEntry] {
        guard !installing else { throw InstallError.busy }
        installing = true
        defer { installing = false }

        var entries: [BatchEntry] = []
        var waiting: [(index: Int, prepared: Prepared)] = []
        var stagings: [URL] = []
        defer { for staging in stagings { try? FileManager.default.removeItem(at: staging) } }

        for source in sources {
            let staging = newStaging()
            stagings.append(staging)
            do {
                let prepared = try await prepare(source, into: staging, route: .batch)
                if case .alreadyInstalled(let identity) = prepared.proposal.decision {
                    entries.append(BatchEntry(source: source, result: .success(.alreadyInstalled(identity))))
                } else {
                    waiting.append((entries.count, prepared))
                    entries.append(BatchEntry(source: source, result: .success(.cancelled)))
                }
            } catch {
                entries.append(BatchEntry(source: source, result: .failure(error)))
            }
        }
        guard !waiting.isEmpty else { return entries }

        let answers = await review(waiting.map { $0.prepared.proposal })
        guard let answers, answers.count == waiting.count else { return entries }

        for ((index, prepared), answer) in zip(waiting, answers) {
            let consent: Consent
            let approved: Bool
            switch answer {
            case .skip: continue
            case .approve(let gates): (consent, approved) = (.install(granting: gates), true)
            case .leaveUnapproved: (consent, approved) = (.install, false)
            }
            do {
                entries[index].result = .success(try await commit(prepared, consent: consent, approved: approved))
                entries[index].approved = approved
            } catch {
                entries[index].result = .failure(error)
            }
        }
        return entries
    }

    // MARK: The pipeline's two halves

    /// A source staged, read, resolved and analysed: everything the review is shown, and what
    /// activating it needs afterwards.
    struct Prepared: Sendable {
        var source: Source
        var staging: URL
        var form: StagedForm
        var scan: CodeScan?
        var proposal: Proposal
    }

    private func newStaging() -> URL {
        paths.staging.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func prepare(_ source: Source, into staging: URL, route: IdentityResolver.Route) async throws -> Prepared {
        let (loaded, form) = try stage(source, into: staging)
        checkpoint(.staged)

        // A staged snippet is one file, `Snippet.pappucliptxt`, so this is also `of(snippet:)`.
        let digest = try ContentDigest.of(packageAt: staging)
        let provenance = Provenance.local(source.origin, digest)
        let candidate = IdentityResolver.Candidate(manifest: loaded.manifest, provenance: provenance, digest: digest)
        let decision = IdentityResolver.resolve(candidate, against: try await store.installedSummaries(), route: route)
        var scan: CodeScan?
        if case .alreadyInstalled = decision {} else {
            scan = await codeScan(loaded.manifest, in: staging, key: nil)
        }
        return Prepared(
            source: source,
            staging: staging,
            form: form,
            scan: scan,
            proposal: Proposal(
                manifest: loaded.manifest,
                warnings: loaded.warnings,
                provenance: provenance,
                digest: digest,
                decision: decision,
                capabilities: CapabilityAnalyzer.effective(loaded.manifest, directory: staging, scan: scan)
            )
        )
    }

    /// Activate a prepared source with the user's answer. `approved` false installs it waiting for
    /// approval, with no grant (EXM-15d).
    private func commit(_ prepared: Prepared, consent: Consent, approved: Bool) async throws -> Outcome {
        let proposal = prepared.proposal
        let decision = proposal.decision
        // A grant for something the analysis did not find would approve nothing today and something
        // tomorrow, when a later version needs it without having been reviewed for it.
        let granted = consent.granted.intersection(proposal.capabilities.gated)
        let kind: ExtensionStore.Activation.Kind
        let identity: LocalIdentity
        switch (consent.answer, decision) {
        case (.cancel, _):
            return .cancelled
        case (.install, .replacementOffered(let existing)):
            kind = .update
            identity = existing
        case (.install, _), (.installSeparately, .replacementOffered):
            kind = .fresh
            identity = LocalIdentity()
        case (.replaceByTrustTransition(let existing), .separate(let collisions))
            where collisions.contains(where: { $0.existing == existing && $0.allowsTrustTransition }):
            kind = .transition(from: existing)
            identity = LocalIdentity()
        default:
            throw InstallError.answerNotOffered
        }

        let activation = ExtensionStore.Activation(
            kind: kind,
            identity: identity,
            manifest: proposal.manifest,
            provenance: proposal.provenance,
            digest: proposal.digest,
            form: prepared.form,
            granted: approved ? granted : [],
            approved: approved
        )
        let destination = paths.folder(activation.folder)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destination.path) {
            // A folder named by its digest holds those bytes; one that is already there is this version.
            try fileManager.moveItem(at: prepared.staging, to: destination)
        }
        checkpoint(.moved)

        let retired: [VersionFolder]
        do {
            retired = try await store.activate(activation)
        } catch {
            if kind != .update { try? fileManager.removeItem(at: destination) }
            try? removeIfEmpty(destination.deletingLastPathComponent())
            throw error
        }
        checkpoint(.committed)
        if let scan = prepared.scan { codeScans[ModuleKey(identity: identity, digest: proposal.digest)] = scan }

        try retire(retired)
        try deleteArchive(prepared.source)
        switch kind {
        case .update: return .updated(identity)
        case .fresh: return .installed(identity, replaced: nil)
        case .transition(let old): return .installed(identity, replaced: old)
        }
    }

    /// Copy, unpack or write the source into `staging` and load its manifest from there — never from
    /// the original, which may change after this.
    func stage(_ source: Source, into staging: URL) throws -> (ExtensionLoader.Loaded, StagedForm) {
        let settings = ExtensionLoader.Settings(origin: .installed)
        do {
            switch source {
            case .packageFolder(let url), .popClipPackage(let url), .developmentFolder(let url):
                try PackageStaging.copyFolder(url, to: staging)
                return (try ExtensionLoader.loadPackage(at: staging, settings: settings), .package)
            case .zippedPackage(let url):
                let unpacked = staging.appendingPathExtension("unzip")
                defer { try? FileManager.default.removeItem(at: unpacked) }
                let package = try PackageStaging.unzip(url, into: unpacked)
                try PackageStaging.copyFolder(package, to: staging)
                return (try ExtensionLoader.loadPackage(at: staging, settings: settings), .package)
            case .snippetFile(let url):
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw InstallError.unreadable("\(url.lastPathComponent) could not be read.")
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw InstallError.unreadable("\(url.lastPathComponent) is not UTF-8 text.")
                }
                return (try stageSnippet(text, into: staging, settings: settings), .snippet)
            case .selectedText(let text):
                guard text.count <= SnippetDetector.maximumSelectionLength else {
                    throw InstallError.selectionTooLong(text.count)
                }
                return (try stageSnippet(text, into: staging, settings: settings), .snippet)
            }
        } catch let failure as PackageStaging.Failure {
            throw InstallError.staging(failure)
        } catch let failure as ManifestLoadFailure {
            throw InstallError.invalid(failure)
        }
    }

    private func stageSnippet(_ text: String, into staging: URL, settings: ExtensionLoader.Settings) throws -> ExtensionLoader.Loaded {
        let loaded = try ExtensionLoader.loadSnippet(text, settings: settings)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data(text.utf8).write(to: staging.appending(path: StagedForm.snippetFileName))
        return loaded
    }

    private func deleteArchive(_ source: Source) throws {
        if case .zippedPackage(let url) = source {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Removing

    /// Delete one action from the list; uninstalls its extension if it was the last (EXM-9).
    @discardableResult
    public func deleteListItem(_ id: ListItemID) async throws -> ExtensionStore.Deletion {
        let deletion = try await store.deleteListItem(id)
        try retire(deletion.retired)
        return deletion
    }

    public func uninstall(_ identity: LocalIdentity) async throws {
        try retire(try await store.uninstall(identity))
    }

    /// Where a version's files are, for the loader and the runtime.
    public nonisolated func folder(for record: ExtensionRecord) -> URL? {
        record.activeVersion.map { paths.folder(VersionFolder(identity: record.localIdentity, digest: $0)) }
    }

    /// Delete folders the store no longer points at. A failure here is left for `recover()`.
    func retire(_ folders: [VersionFolder]) throws {
        for folder in folders {
            let url = paths.folder(folder)
            try? FileManager.default.removeItem(at: url)
            try? removeIfEmpty(url.deletingLastPathComponent())
        }
    }

    func removeIfEmpty(_ folder: URL) throws {
        let fileManager = FileManager.default
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try fileManager.removeItem(at: folder)
        }
    }
}
