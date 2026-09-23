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
        /// A `.pappucliptxt` or `.popcliptxt` file.
        case snippetFile(URL)
        /// Selected text, through the bar's Install Extension action (EXM-2).
        case selectedText(String)

        /// Which source a file is, by its extension; nil for anything that is not an extension.
        public static func file(_ url: URL) -> Source? {
            let suffix = url.pathExtension.lowercased()
            if ProductIdentity.FileExtension.package.contains(suffix) { return .packageFolder(url) }
            if ProductIdentity.FileExtension.zippedPackage.contains(suffix) { return .zippedPackage(url) }
            if ProductIdentity.FileExtension.snippet.contains(suffix) { return .snippetFile(url) }
            return nil
        }

        var origin: LocalOrigin {
            switch self {
            case .packageFolder, .zippedPackage: .packageFile
            case .snippetFile: .snippetFile
            case .selectedText: .selectedText
            }
        }
    }

    /// What the review sheet is shown (EXM-5, SEC-8c). Week 5 adds the permission summary.
    public struct Proposal: Sendable, Equatable {
        public var manifest: ExtensionManifest
        public var warnings: [ManifestDiagnostic]
        public var provenance: Provenance
        public var digest: ContentDigest
        public var decision: IdentityResolver.Decision
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

    /// Asks the user. The app shows a sheet; tests answer directly.
    public typealias Reviewer = @Sendable (Proposal) async -> Answer

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
    private let checkpoint: @Sendable (Checkpoint) -> Void
    private var installing = false

    public init(paths: Paths, checkpoint: @escaping @Sendable (Checkpoint) -> Void = { _ in }) throws {
        self.paths = paths
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

        let staging = paths.staging.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        let (loaded, form) = try stage(source, into: staging)
        checkpoint(.staged)

        // A staged snippet is one file, `Snippet.pappucliptxt`, so this is also `of(snippet:)`.
        let digest = try ContentDigest.of(packageAt: staging)
        let provenance = Provenance.local(source.origin, digest)
        let candidate = IdentityResolver.Candidate(manifest: loaded.manifest, provenance: provenance, digest: digest)
        let decision = IdentityResolver.resolve(candidate, against: try await store.installedSummaries(), route: route)
        if case .alreadyInstalled(let identity) = decision {
            try deleteArchive(source)
            return .alreadyInstalled(identity)
        }

        let answer = await review(Proposal(manifest: loaded.manifest, warnings: loaded.warnings, provenance: provenance, digest: digest, decision: decision))
        let kind: ExtensionStore.Activation.Kind
        let identity: LocalIdentity
        switch (answer, decision) {
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

        let activation = ExtensionStore.Activation(kind: kind, identity: identity, manifest: loaded.manifest, provenance: provenance, digest: digest, form: form)
        let destination = paths.folder(activation.folder)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destination.path) {
            // A folder named by its digest holds those bytes; one that is already there is this version.
            try fileManager.moveItem(at: staging, to: destination)
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

        try retire(retired)
        try deleteArchive(source)
        switch kind {
        case .update: return .updated(identity)
        case .fresh: return .installed(identity, replaced: nil)
        case .transition(let old): return .installed(identity, replaced: old)
        }
    }

    /// Copy, unpack or write the source into `staging` and load its manifest from there — never from
    /// the original, which may change after this.
    private func stage(_ source: Source, into staging: URL) throws -> (ExtensionLoader.Loaded, StagedForm) {
        let settings = ExtensionLoader.Settings(origin: .installed)
        do {
            switch source {
            case .packageFolder(let url):
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
    private func retire(_ folders: [VersionFolder]) throws {
        for folder in folders {
            let url = paths.folder(folder)
            try? FileManager.default.removeItem(at: url)
            try? removeIfEmpty(url.deletingLastPathComponent())
        }
    }

    private func removeIfEmpty(_ folder: URL) throws {
        let fileManager = FileManager.default
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try fileManager.removeItem(at: folder)
        }
    }
}
