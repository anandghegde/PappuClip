import Foundation
import PappuCore

/// DEV-1: a package folder on this Mac, installed from where it is and reloaded from there.
///
/// **Approval is explicit, and so is every reload.** A folder is installed only through the same review
/// as any other install, with a sentence saying it is development code. After that, nothing watches the
/// folder: the developer presses Reload, and the folder is copied and checked again exactly as an
/// install would be. A reload that needs nothing more than the developer approved last time — the same
/// listed capabilities or fewer, no new gate, no new app or host method — is activated without a sheet,
/// keeping only the gates already granted. Anything more is reviewed again, and Cancel leaves the old
/// version running. An extension that is not approved today (revoked, suspended, pending) is reviewed
/// on every reload.
///
/// **Nothing else is relaxed.** The code runs through the same consent, secure-input, privacy and
/// destination checks as any installed extension; this file only decides when a review is shown.
extension ExtensionLibrary {
    /// One approved development folder.
    public struct DevelopmentFolder: Codable, Sendable, Equatable, Identifiable {
        public var identity: LocalIdentity
        /// The folder's path, as the developer chose it.
        public var path: String
        /// What the developer last approved: a reload within this needs no review.
        public var approved: CapabilitySet
        public var approvedAt: Date

        public var id: LocalIdentity { identity }
        public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
    }

    /// What a reload did.
    public enum DevelopmentReload: Sendable, Equatable {
        /// The folder holds the bytes already active.
        case unchanged
        /// New bytes, within what was approved: activated without a review.
        case reloaded
        /// New bytes that needed a review, and the developer approved them.
        case approved
        /// The developer cancelled the review; the previous version is still the active one.
        case cancelled
    }

    public enum DevelopmentError: Error, Equatable, CustomStringConvertible {
        case notAFolder(String)
        case alreadyApproved(String)
        case unknown(LocalIdentity)

        public var description: String {
            switch self {
            case .notAFolder(let name): "\(name) is not a folder."
            case .alreadyApproved(let name): "\(name) is already a development folder."
            case .unknown: "That development folder is no longer installed."
            }
        }
    }

    nonisolated var developmentFoldersFile: URL {
        paths.root.appending(path: "Store/development-folders.json")
    }

    /// The approved folders whose extension is still installed.
    public func developmentFolders() async throws -> [DevelopmentFolder] {
        let installed = Set(try await store.extensions().map(\.localIdentity))
        return readDevelopmentFolders().filter { installed.contains($0.identity) }
    }

    public func developmentFolder(_ identity: LocalIdentity) async throws -> DevelopmentFolder? {
        try await developmentFolders().first { $0.identity == identity }
    }

    /// Install `url` as a development folder, through the install review. Always a separate identity:
    /// a development copy never replaces an extension installed some other way.
    @discardableResult
    public func approveDevelopmentFolder(_ url: URL, review: Reviewer) async throws -> Outcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DevelopmentError.notAFolder(url.lastPathComponent)
        }
        let path = url.standardizedFileURL.path
        guard try await !developmentFolders().contains(where: { $0.path == path }) else {
            throw DevelopmentError.alreadyApproved(url.lastPathComponent)
        }
        let result = try await loadDevelopmentFolder(at: url, into: nil, review: review)
        switch result.outcome {
        case .installed(let identity, _):
            try await remember(DevelopmentFolder(
                identity: identity, path: path, approved: result.capabilities, approvedAt: .now
            ))
        default:
            break
        }
        return result.outcome
    }

    /// Copy the folder again and activate it if it changed, reviewing it when it needs more than was
    /// approved (see the type's comment).
    @discardableResult
    public func reloadDevelopmentFolder(_ identity: LocalIdentity, review: Reviewer) async throws -> DevelopmentReload {
        guard var folder = try await developmentFolder(identity) else { throw DevelopmentError.unknown(identity) }
        let result = try await loadDevelopmentFolder(at: folder.url, into: folder, review: review)
        switch result.reload {
        case .approved:
            folder.approved = result.capabilities
            folder.approvedAt = .now
            try await remember(folder)
        case .reloaded, .unchanged, .cancelled:
            break
        }
        return result.reload
    }

    /// Uninstall a development folder's extension and forget the folder. The folder itself is the
    /// developer's and is never touched.
    public func removeDevelopmentFolder(_ identity: LocalIdentity) async throws {
        if try await store.extension(identity) != nil {
            try await uninstall(identity)
        }
        try writeDevelopmentFolders(readDevelopmentFolders().filter { $0.identity != identity })
    }

    // MARK: The pipeline

    private struct DevelopmentLoad {
        var outcome: Outcome
        var reload: DevelopmentReload
        var capabilities: CapabilitySet
    }

    /// `install`'s pipeline for a development folder: stage, digest, analyse, review when needed,
    /// activate. `existing` is nil for the first approval.
    private func loadDevelopmentFolder(
        at url: URL,
        into existing: DevelopmentFolder?,
        review: Reviewer
    ) async throws -> DevelopmentLoad {
        guard !installing else { throw InstallError.busy }
        installing = true
        defer { installing = false }

        let source = Source.developmentFolder(url)
        let staging = paths.staging.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let (loaded, form) = try stage(source, into: staging)
        checkpoint(.staged)

        let digest = try ContentDigest.of(packageAt: staging)
        let provenance = Provenance.local(source.origin, digest)
        let scan = await codeScan(loaded.manifest, in: staging, key: nil)
        let capabilities = CapabilityAnalyzer.effective(loaded.manifest, directory: staging, scan: scan)

        var decision = IdentityResolver.Decision.fresh
        var silentGates: Set<GatedCapability>?
        if let existing {
            guard let record = try await store.extension(existing.identity) else {
                throw DevelopmentError.unknown(existing.identity)
            }
            let approval = try await store.approval(for: existing.identity)
            if record.activeVersion == digest, approval != nil {
                return DevelopmentLoad(outcome: .alreadyInstalled(existing.identity), reload: .unchanged, capabilities: capabilities)
            }
            decision = .replacementOffered(existing.identity)
            if let approval, !capabilities.exceeds(existing.approved) {
                silentGates = approval.gates.intersection(capabilities.gated)
            }
        } else {
            // Only to say which installed extensions it will sit beside; it is always installed apart.
            let candidate = IdentityResolver.Candidate(manifest: loaded.manifest, provenance: provenance, digest: digest)
            if case .separate(let found) = IdentityResolver.resolve(candidate, against: try await store.installedSummaries(), route: .manual) {
                decision = .separate(found)
            }
        }

        let granted: Set<GatedCapability>
        let reviewed: Bool
        if let silentGates {
            granted = silentGates
            reviewed = false
        } else {
            let consent = await review(Proposal(
                manifest: loaded.manifest,
                warnings: loaded.warnings,
                provenance: provenance,
                digest: digest,
                decision: decision,
                capabilities: capabilities
            ))
            switch consent.answer {
            case .cancel:
                return DevelopmentLoad(outcome: .cancelled, reload: .cancelled, capabilities: capabilities)
            case .install:
                granted = consent.granted.intersection(capabilities.gated)
                reviewed = true
            case .installSeparately, .replaceByTrustTransition:
                throw InstallError.answerNotOffered
            }
        }

        let identity = existing?.identity ?? LocalIdentity()
        let activation = ExtensionStore.Activation(
            kind: existing == nil ? .fresh : .update,
            identity: identity,
            manifest: loaded.manifest,
            provenance: provenance,
            digest: digest,
            form: form,
            granted: granted
        )
        try await activateStaged(activation, from: staging)
        if let scan { codeScans[ModuleKey(identity: identity, digest: digest)] = scan }
        if existing == nil {
            return DevelopmentLoad(outcome: .installed(identity, replaced: nil), reload: .approved, capabilities: capabilities)
        }
        return DevelopmentLoad(
            outcome: .updated(identity),
            reload: reviewed ? .approved : .reloaded,
            capabilities: capabilities
        )
    }

    /// `install`'s last three steps: move the staged folder into place, commit, retire what it replaced.
    private func activateStaged(_ activation: ExtensionStore.Activation, from staging: URL) async throws {
        let destination = paths.folder(activation.folder)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: staging, to: destination)
        }
        checkpoint(.moved)
        let retired: [VersionFolder]
        do {
            retired = try await store.activate(activation)
        } catch {
            if activation.kind != .update { try? fileManager.removeItem(at: destination) }
            try? removeIfEmpty(destination.deletingLastPathComponent())
            throw error
        }
        checkpoint(.committed)
        try retire(retired)
    }

    // MARK: The list

    private func remember(_ folder: DevelopmentFolder) async throws {
        let installed = Set(try await store.extensions().map(\.localIdentity))
        var folders = readDevelopmentFolders().filter { $0.identity != folder.identity && installed.contains($0.identity) }
        folders.append(folder)
        try writeDevelopmentFolders(folders)
    }

    private func readDevelopmentFolders() -> [DevelopmentFolder] {
        guard let data = try? Data(contentsOf: developmentFoldersFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DevelopmentFolder].self, from: data)) ?? []
    }

    private func writeDevelopmentFolders(_ folders: [DevelopmentFolder]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = developmentFoldersFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(folders).write(to: file, options: .atomic)
    }
}

extension CapabilitySet {
    /// DEV-1: whether this needs anything `approved` did not: a listed capability, a gate, an app it
    /// controls or a sensitive method it reaches.
    public func exceeds(_ approved: CapabilitySet) -> Bool {
        !Set(listed).isSubset(of: approved.listed)
            || !Set(gated).isSubset(of: approved.gated)
            || !Set(controlledApps).isSubset(of: approved.controlledApps)
            || !Set(reachableMethods).isSubset(of: approved.reachableMethods)
    }
}
