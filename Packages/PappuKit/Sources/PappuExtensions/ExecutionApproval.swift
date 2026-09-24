import Foundation
import GRDB
import PappuCore

/// The right to run one extension's code, as the store vouches for it at this moment (EXM-5, SEC-4).
///
/// **A token, not a flag.** Nothing outside this module can make one: the initialiser is internal, and
/// the two ways to get one are the store — which mints it only when there is an execution grant for
/// exactly the bytes that are active (SEC-8c) and the extension is enabled — and `bundled(_:)`, which
/// answers only for the app's own built-ins (EXM-5g). `ActionResolver` drops every action without one
/// and `ExtensionRunner.Request` cannot be built without one, so "no extension code path is reachable
/// without an `ExecutionApproval`" is a property of the types rather than of every caller remembering.
///
/// It says which gated capabilities were granted with it, and `permits` is the check the runtime makes
/// against an action's own gates (SEC-7d). Revocation is not something a token can notice by itself:
/// the store's `revoke` is followed by the app cancelling the extension's running invocations
/// (`InvocationManager.invalidate(ownedBy:)`, SEC-4b, RUN-3f), and the next resolution has no token.
public struct ExecutionApproval: Sendable, Hashable {
    /// Nil for a built-in, which has no row of its own to be approved by.
    public let identity: LocalIdentity?
    /// The bytes approved. Nil for a built-in, which is the app's.
    public let digest: ContentDigest?
    public let gates: Set<GatedCapability>

    init(identity: LocalIdentity?, digest: ContentDigest?, gates: Set<GatedCapability>) {
        self.identity = identity
        self.digest = digest
        self.gates = gates
    }

    /// EXM-5g: the built-ins are approved by installing the app. Only a manifest from the app's own
    /// bundle (`ManifestOrigin.appBundle`), running the reserved executor, is one.
    public static func bundled(_ action: CatalogAction) -> ExecutionApproval? {
        guard action.origin == .appBundle, action.builtin != nil else { return nil }
        return ExecutionApproval(identity: nil, digest: nil, gates: [])
    }

    /// Whether this approval covers every gate `action` needs (EXM-5d, SEC-7d).
    public func permits(_ action: CatalogAction) -> Bool {
        action.gates.isSubset(of: gates)
    }

    /// The identity as `CatalogAction.owner` and `InvocationRequest.owner` carry it.
    public var owner: String? { identity?.description }

    /// Whether this approval is the one `action` needs: the same install, and every gate granted.
    public func covers(_ action: CatalogAction) -> Bool {
        action.owner == owner && permits(action)
    }
}

extension ExtensionStore {
    public enum GrantError: Error, Equatable, CustomStringConvertible {
        case notInstalled(LocalIdentity)
        /// EXM-5g: a built-in is approved by the app; it can be disabled, not revoked.
        case builtinIsApprovedByTheApp
        case noActiveVersion(LocalIdentity)

        public var description: String {
            switch self {
            case .notInstalled(let identity): "No extension is installed as \(identity)."
            case .builtinIsApprovedByTheApp: "A built-in extension is approved by installing the app; it can be turned off instead."
            case .noActiveVersion(let identity): "\(identity) has no version to approve."
            }
        }
    }

    // MARK: Reading

    /// The approval `identity` has right now, or nil when it may not run.
    public func approval(for identity: LocalIdentity) throws -> ExecutionApproval? {
        try database.read { db in
            guard let record = try ExtensionRecord.fetchOne(db, key: identity) else { return nil }
            return try Self.approval(for: record, in: db)
        }
    }

    /// Every extension's approval at once, for building the catalog.
    public func approvals() throws -> [LocalIdentity: ExecutionApproval] {
        try database.read { db in
            var approvals: [LocalIdentity: ExecutionApproval] = [:]
            for record in try ExtensionRecord.fetchAll(db) {
                if let approval = try Self.approval(for: record, in: db) { approvals[record.localIdentity] = approval }
            }
            return approvals
        }
    }

    /// Extension Info's list (SEC-4a): every grant, including ones for bytes that are no longer active.
    public func grants(of identity: LocalIdentity) throws -> [GrantRecord] {
        try database.read { db in
            try GrantRecord.filter(Column("local_identity") == identity).order(Column("capability")).fetchAll(db)
        }
    }

    private static func approval(for record: ExtensionRecord, in db: Database) throws -> ExecutionApproval? {
        guard record.state == .enabled else { return nil }
        if record.isBuiltin {
            return ExecutionApproval(identity: record.localIdentity, digest: nil, gates: [])
        }
        guard let active = record.activeVersion else { return nil }
        let current = try GrantRecord
            .filter(Column("local_identity") == record.localIdentity && Column("content_digest") == active)
            .fetchAll(db)
            .compactMap(\.key)
        guard current.contains(.execution) else { return nil }
        let gates = Set(current.compactMap { key -> GatedCapability? in
            if case .gated(let gate) = key { return gate }
            return nil
        })
        return ExecutionApproval(identity: record.localIdentity, digest: active, gates: gates)
    }

    // MARK: Writing

    /// Extension Info's Approve (EXM-15d, SEC-8c): the active version may run, with `gates`.
    public func approve(_ identity: LocalIdentity, granting gates: Set<GatedCapability>) throws {
        try database.write { db in
            guard var record = try ExtensionRecord.fetchOne(db, key: identity) else { throw GrantError.notInstalled(identity) }
            guard !record.isBuiltin else { throw GrantError.builtinIsApprovedByTheApp }
            guard let active = record.activeVersion else { throw GrantError.noActiveVersion(identity) }
            try replaceGrants(of: identity, at: active, granting: gates, in: db)
            if record.state == .pendingApproval {
                record.state = .enabled
                try record.update(db)
            }
        }
    }

    /// SEC-4b: every grant goes and the extension waits for approval again. The caller cancels its
    /// running invocations; the store's part is that no new approval can be minted.
    public func revoke(_ identity: LocalIdentity) throws {
        try database.write { db in
            guard var record = try ExtensionRecord.fetchOne(db, key: identity) else { throw GrantError.notInstalled(identity) }
            guard !record.isBuiltin else { throw GrantError.builtinIsApprovedByTheApp }
            try GrantRecord.filter(Column("local_identity") == identity).deleteAll(db)
            if record.state == .enabled {
                record.state = .pendingApproval
                try record.update(db)
            }
        }
    }

    /// SEC-4a: one gated capability off, the rest of the approval kept.
    public func revoke(_ gate: GatedCapability, of identity: LocalIdentity) throws {
        try database.write { db in
            _ = try GrantRecord.deleteOne(db, key: ["local_identity": identity.databaseValue, "capability": GrantKey.gated(gate).rawValue])
        }
    }

    /// Replaces every grant `identity` holds with execution and `gates`, at `digest`.
    func replaceGrants(of identity: LocalIdentity, at digest: ContentDigest, granting gates: Set<GatedCapability>, in db: Database) throws {
        try GrantRecord.filter(Column("local_identity") == identity).deleteAll(db)
        let keys = [GrantKey.execution] + gates.sorted().map(GrantKey.gated)
        for key in keys {
            try GrantRecord(localIdentity: identity, capability: key.rawValue, contentDigest: digest, grantedAt: now()).insert(db)
        }
    }
}
