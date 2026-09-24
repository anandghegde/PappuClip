import Foundation
import PappuCore

/// One installed extension as the app needs it after launch: its row, its manifest read back from the
/// active version's folder, and everything Extension Info shows about it (SEC-4a).
public struct InstalledExtension: Sendable, Equatable {
    public var record: ExtensionRecord
    public var manifest: ExtensionManifest
    /// The active version's folder, which is also the directory its actions run in (§8.4).
    public var directory: URL
    /// Worked out again from the files on disk, never remembered from the review (EXM-5b).
    public var capabilities: CapabilitySet
    /// The first live instance. Several instances of one extension are M4's (ALM-2a); until then every
    /// option is read from and written to this one.
    public var instance: InstanceID?
    /// The user's non-secret option values for `instance`.
    public var storedOptions: [String: String]
    /// Nil when the extension may not run: pending approval, disabled, or a grant for other bytes.
    public var approval: ExecutionApproval?
    public var grants: [GrantRecord]
    /// JS-12: what its module exported, when it is a module extension the helper has described. Its
    /// manifest's actions and options are then the module's.
    public var moduleExports: ModuleExports? = nil
    /// JS-12: why what the module exported did not make a manifest, which leaves the config's.
    public var moduleProblem: String? = nil

    /// JS-12: a module extension whose module has not been described for these bytes.
    public var awaitsModuleDescription: Bool {
        manifest.moduleSource != nil && moduleExports == nil && moduleProblem == nil
    }

    public var identity: LocalIdentity { record.localIdentity }

    /// A gate the analysis found and the user has granted on the active bytes.
    public func isGranted(_ gate: GatedCapability) -> Bool {
        approval?.gates.contains(gate) == true
    }
}

extension ExtensionLibrary {
    /// Every installed extension that is not a built-in, and every one whose files could not be read.
    public struct Installed: Sendable, Equatable {
        public var extensions: [InstalledExtension]
        /// A row whose folder is missing or no longer loads. It is kept rather than removed — the
        /// user's options and list position are in the store — and it offers nothing until reinstalled.
        public var unreadable: [Unreadable]

        public struct Unreadable: Sendable, Equatable {
            public var record: ExtensionRecord
            public var reason: String
        }
    }

    /// Reads every installed extension back from its active version's folder, in install order.
    public func installed() async throws -> Installed {
        var result = Installed(extensions: [], unreadable: [])
        let approvals = try await store.approvals()
        for record in try await store.extensions() where !record.isBuiltin {
            do {
                result.extensions.append(try await load(record, approval: approvals[record.localIdentity]))
            } catch {
                result.unreadable.append(.init(record: record, reason: String(describing: error)))
            }
        }
        return result
    }

    /// One extension, read again: after its options, grants or state changed.
    public func installed(_ identity: LocalIdentity) async throws -> InstalledExtension? {
        guard let record = try await store.extension(identity), !record.isBuiltin else { return nil }
        return try await load(record, approval: try await store.approval(for: identity))
    }

    private func load(_ record: ExtensionRecord, approval: ExecutionApproval?) async throws -> InstalledExtension {
        guard let digest = record.activeVersion, let directory = folder(for: record) else {
            throw ExtensionStore.GrantError.noActiveVersion(record.localIdentity)
        }
        let form = try await store.versions(of: record.localIdentity).first { $0.contentDigest == digest }?.form ?? .package
        var manifest = try Self.manifest(form, in: directory, settings: ExtensionLoader.Settings(origin: .installed))
        // JS-12: a described module's actions and options, over its config's. Exports that do not
        // build leave the config's manifest, and the reason, rather than an extension that will not load.
        var exports: ModuleExports?
        var moduleProblem: String?
        if manifest.moduleSource != nil, let described = moduleExports[ModuleKey(identity: record.localIdentity, digest: digest)] {
            do {
                manifest = try Self.manifest(form, in: directory, settings: ExtensionLoader.Settings(origin: .installed, moduleExports: described))
                exports = described
            } catch {
                moduleProblem = String(describing: error)
            }
        }
        let instance = try await store.instances(of: record.localIdentity).first?.id
        var stored: [String: String] = [:]
        if let instance { stored = try await store.optionValues(of: instance) }
        return InstalledExtension(
            record: record,
            manifest: manifest,
            directory: directory,
            capabilities: CapabilityAnalyzer.effective(manifest, directory: directory),
            instance: instance,
            storedOptions: stored,
            approval: approval,
            grants: try await store.grants(of: record.localIdentity),
            moduleExports: exports,
            moduleProblem: moduleProblem
        )
    }

    private static func manifest(_ form: StagedForm, in directory: URL, settings: ExtensionLoader.Settings) throws -> ExtensionManifest {
        switch form {
        case .package:
            return try ExtensionLoader.loadPackage(at: directory, settings: settings).manifest
        case .snippet:
            let text = try String(contentsOf: directory.appending(path: StagedForm.snippetFileName), encoding: .utf8)
            return try ExtensionLoader.loadSnippet(text, settings: settings).manifest
        }
    }
}
