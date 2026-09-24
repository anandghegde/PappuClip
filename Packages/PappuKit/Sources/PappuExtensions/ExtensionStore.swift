import Foundation
import GRDB
import PappuCore

/// Installed extensions, their instances and the action list, in `Store/pappuclip.sqlite` (architecture §11).
///
/// **Rows only.** The store never touches an extension's files: `ExtensionLibrary` renames a staged
/// folder into place and then asks the store to commit, and removes folders only after the store has
/// said which ones no row points at any more. That order is what makes an install atomic across two
/// systems that share no transaction — see `ExtensionLibrary.recover()`.
///
/// **Sync-ready from the first row (SYN-1, SYN-2).** Instances and list items have stable UUIDs, a
/// revision, the device that last wrote them and a tombstone instead of a `DELETE`; the list's order
/// is `OrderKey`s. Nothing syncs until 1.x; the point is that nothing will need migrating when it does.
public actor ExtensionStore {
    let database: DatabaseQueue
    let now: @Sendable () -> Date
    /// This Mac, as the writer of a row (SYN-2). Minted with the database.
    public nonisolated let deviceID: String

    /// `url` nil is an in-memory store, for tests and for `pappu-dev`'s dry runs.
    public init(at url: URL?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            database = try DatabaseQueue(path: url.path, configuration: configuration)
        } else {
            database = try DatabaseQueue(configuration: configuration)
        }
        self.now = now
        try Self.migrator.migrate(database)
        deviceID = try database.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'device_id'") {
                return existing
            }
            let minted = UUID().uuidString.lowercased()
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('device_id', ?)", arguments: [minted])
            return minted
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1: extensions, instances, list") { db in
            try db.create(table: "meta") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            try db.create(table: "extension") { table in
                table.primaryKey("local_identity", .text)
                table.column("manifest_identifier", .text).notNull()
                table.column("identifier_origin", .text).notNull()
                table.column("name", .text).notNull()
                table.column("provenance", .text).notNull()
                table.column("active_version", .text)
                table.column("state", .text).notNull()
                table.column("updates_paused", .boolean).notNull()
                table.column("installed_at", .datetime).notNull()
            }
            try db.create(table: "extension_version") { table in
                table.column("local_identity", .text).notNull().references("extension", onDelete: .cascade)
                table.column("content_digest", .text).notNull()
                table.column("form", .text).notNull()
                table.column("signature_status", .text).notNull()
                table.column("retained", .boolean).notNull()
                table.column("created_at", .datetime).notNull()
                table.primaryKey(["local_identity", "content_digest"])
            }
            // No foreign key to `extension`: an uninstalled extension's row goes, and its instances
            // stay behind as tombstones (SYN-1).
            try db.create(table: "instance") { table in
                table.primaryKey("id", .text)
                table.column("local_identity", .text).notNull().indexed()
                table.column("name", .text)
                table.column("icon", .text)
                table.column("show_as", .text)
                table.column("color", .text)
                table.column("revision", .integer).notNull()
                table.column("device_id", .text).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(table: "list_item") { table in
                table.primaryKey("id", .text)
                table.column("parent_id", .text)
                table.column("kind", .text).notNull()
                table.column("order_key", .text).notNull()
                table.column("instance_id", .text).indexed()
                table.column("action_key", .text)
                table.column("enabled", .boolean).notNull()
                table.column("revision", .integer).notNull()
                table.column("device_id", .text).notNull()
                table.column("deleted_at", .datetime)
            }
            try db.create(index: "list_item_order", on: "list_item", columns: ["order_key", "id"])
            try db.create(table: "option_value") { table in
                table.column("instance_id", .text).notNull()
                table.column("option_id", .text).notNull()
                table.column("value", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("device_id", .text).notNull()
                table.primaryKey(["instance_id", "option_id"])
            }
            try db.create(table: "config_snapshot") { table in
                table.primaryKey("id", .text)
                table.column("local_identity", .text).notNull().indexed()
                table.column("version_digest", .text).notNull()
                table.column("options", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }
        }
        // M2 week 5 (EXM-5, SEC-4, SEC-8c): what the user approved, and for which bytes. One row per
        // capability key — `execution`, or a `GatedCapability` — at the digest it was given to. A
        // grant goes with its extension's row, which is how a trust transition leaves the old
        // identity's grants behind (SEC-8e).
        migrator.registerMigration("v2: grants") { db in
            try db.create(table: "grant") { table in
                table.column("local_identity", .text).notNull().references("extension", onDelete: .cascade)
                table.column("capability", .text).notNull()
                table.column("content_digest", .text).notNull()
                table.column("granted_at", .datetime).notNull()
                table.primaryKey(["local_identity", "capability"])
            }
            // Anything installed before consent existed was never approved: it waits for the user
            // rather than being grandfathered in (EXM-5a: before any of its code runs).
            for var record in try ExtensionRecord.fetchAll(db) where !record.isBuiltin && record.state == .enabled {
                record.state = .pendingApproval
                try record.update(db)
            }
        }
        return migrator
    }

    // MARK: Reading

    /// One action on the list, with everything needed to show it.
    public struct PlacedAction: Sendable, Equatable {
        public var item: ListItemRecord
        public var instance: InstanceRecord
        public var `extension`: ExtensionRecord
    }

    /// The live action list, in order (ALM-1): by order key, then by item ID, which is the tie-break
    /// two devices will agree on.
    public func placedActions() throws -> [PlacedAction] {
        try database.read { db in
            let extensions = try Dictionary(
                ExtensionRecord.fetchAll(db).map { ($0.localIdentity, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let instances = try Dictionary(
                InstanceRecord.filter(Column("deleted_at") == nil).fetchAll(db).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return try ListItemRecord
                .filter(Column("deleted_at") == nil && Column("kind") == ListItemKind.action.rawValue)
                .order(Column("order_key"), Column("id"))
                .fetchAll(db)
                .compactMap { item in
                    guard let instance = item.instanceID.flatMap({ instances[$0] }),
                          let owner = extensions[instance.localIdentity]
                    else { return nil }
                    return PlacedAction(item: item, instance: instance, extension: owner)
                }
        }
    }

    public func extensions() throws -> [ExtensionRecord] {
        try database.read { db in try ExtensionRecord.order(Column("installed_at"), Column("local_identity")).fetchAll(db) }
    }

    public func `extension`(_ identity: LocalIdentity) throws -> ExtensionRecord? {
        try database.read { db in try ExtensionRecord.fetchOne(db, key: identity) }
    }

    public func versions(of identity: LocalIdentity) throws -> [ExtensionVersionRecord] {
        try database.read { db in
            try ExtensionVersionRecord.filter(Column("local_identity") == identity).order(Column("created_at")).fetchAll(db)
        }
    }

    /// Every version folder a row points at: what `ExtensionLibrary.recover()` keeps.
    public func versionFolders() throws -> Set<VersionFolder> {
        try database.read { db in
            Set(try ExtensionVersionRecord.fetchAll(db).map { VersionFolder(identity: $0.localIdentity, digest: $0.contentDigest) })
        }
    }

    public func instances(of identity: LocalIdentity, includingDeleted: Bool = false) throws -> [InstanceRecord] {
        try database.read { db in
            var request = InstanceRecord.filter(Column("local_identity") == identity)
            if !includingDeleted { request = request.filter(Column("deleted_at") == nil) }
            return try request.order(Column("id")).fetchAll(db)
        }
    }

    /// What `IdentityResolver` compares an arriving package with.
    public func installedSummaries() throws -> [IdentityResolver.Installed] {
        try extensions().map { record in
            IdentityResolver.Installed(
                identity: record.localIdentity,
                identifier: record.manifestIdentifier,
                identifierOrigin: record.identifierOrigin,
                name: record.name,
                provenance: record.provenance,
                digest: record.activeVersion
            )
        }
    }

    public func optionValues(of instance: InstanceID) throws -> [String: String] {
        try database.read { db in
            Dictionary(
                try OptionValueRecord.filter(Column("instance_id") == instance).fetchAll(db).map { ($0.optionID, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    public func snapshots(of identity: LocalIdentity) throws -> [ConfigSnapshotRecord] {
        try database.read { db in
            try ConfigSnapshotRecord.filter(Column("local_identity") == identity).order(Column("created_at")).fetchAll(db)
        }
    }

    // MARK: Writing

    /// Non-secret option values only. A `secret` option is the Keychain's (SEC-3), and the caller
    /// that knows the schema is the one that routes it there (week 5).
    public func setOptionValue(_ value: String, for option: String, of instance: InstanceID) throws {
        try database.write { db in
            let existing = try OptionValueRecord.fetchOne(db, key: ["instance_id": instance.databaseValue, "option_id": option.databaseValue])
            try OptionValueRecord(
                instanceID: instance,
                optionID: option,
                value: value,
                revision: (existing?.revision ?? 0) + 1,
                deviceID: deviceID
            ).save(db)
        }
    }

    /// Add each built-in this store has never seen, with one instance and its actions at the end of
    /// the list. A built-in is seeded once: if the user later deletes its actions they stay deleted
    /// until `restoreBuiltins`, and a launch does not quietly put them back (EXM-9).
    @discardableResult
    public func seedBuiltins(_ manifests: [ExtensionManifest]) throws -> [LocalIdentity] {
        try database.write { db in
            let seeded = Set(try ExtensionRecord.fetchAll(db).filter(\.isBuiltin).map(\.manifestIdentifier))
            var added: [LocalIdentity] = []
            for manifest in manifests where !seeded.contains(manifest.identifier) {
                let record = ExtensionRecord(
                    localIdentity: LocalIdentity(),
                    manifestIdentifier: manifest.identifier,
                    identifierOrigin: manifest.identifierOrigin,
                    name: manifest.name.english,
                    provenance: .builtin,
                    activeVersion: nil,
                    state: .enabled,
                    updatesPaused: false,
                    installedAt: now()
                )
                try record.insert(db)
                let instance = try insertInstance(for: record.localIdentity, in: db)
                try appendItems(Self.actionKeys(of: manifest), for: instance, in: db)
                added.append(record.localIdentity)
            }
            return added
        }
    }

    /// EXM-9's other half: every built-in action that has no live item gets one again, at the end.
    /// Returns how many came back.
    @discardableResult
    public func restoreBuiltins(_ manifests: [ExtensionManifest]) throws -> Int {
        try database.write { db in
            let builtins = try ExtensionRecord.fetchAll(db).filter(\.isBuiltin)
            var restored = 0
            for manifest in manifests {
                guard let record = builtins.first(where: { $0.manifestIdentifier == manifest.identifier }) else { continue }
                let existing: InstanceID? = try InstanceRecord
                    .filter(Column("local_identity") == record.localIdentity && Column("deleted_at") == nil)
                    .order(Column("id"))
                    .fetchOne(db)?.id
                let instance = try existing ?? insertInstance(for: record.localIdentity, in: db)
                let live = Set(try liveItems(of: [instance], in: db).compactMap(\.actionKey))
                let missing = Self.actionKeys(of: manifest).filter { !live.contains($0) }
                try appendItems(missing, for: instance, in: db)
                restored += missing.count
            }
            return restored
        }
    }

    /// Everything one activation writes, decided before the store is asked (`ExtensionLibrary`).
    public struct Activation: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A new identity, at the end of the list.
            case fresh
            /// A new version of `identity` itself, which its provenance vouched for (EXM-2).
            case update
            /// A trust transition (SEC-8e): a new identity takes the old one's place in the list and
            /// its non-secret options; the old one is uninstalled, and its grants and secrets go with it.
            case transition(from: LocalIdentity)
        }

        public var kind: Kind
        public var identity: LocalIdentity
        public var manifest: ExtensionManifest
        public var provenance: Provenance
        public var digest: ContentDigest
        public var form: StagedForm
        /// The gated capabilities the user switched on in the review (EXM-5d). Execution itself is
        /// approved by the review's confirmation (EXM-5c), so an activation always grants it.
        public var granted: Set<GatedCapability>

        public init(
            kind: Kind,
            identity: LocalIdentity,
            manifest: ExtensionManifest,
            provenance: Provenance,
            digest: ContentDigest,
            form: StagedForm,
            granted: Set<GatedCapability> = []
        ) {
            self.kind = kind
            self.identity = identity
            self.manifest = manifest
            self.provenance = provenance
            self.digest = digest
            self.form = form
            self.granted = granted
        }

        public var folder: VersionFolder { VersionFolder(identity: identity, digest: digest) }
    }

    /// One transaction: the version row, the pointer, the grants, the list. Returns the folders no row
    /// points at any more, which the caller deletes *after* this has committed.
    ///
    /// The grants are in the same transaction as the pointer so that there is no moment at which the
    /// new bytes are active under the old bytes' approval (SEC-8c), or approved with nothing active.
    public func activate(_ activation: Activation) throws -> [VersionFolder] {
        let retired = try database.write { db in
            let manifest = activation.manifest
            let keys = Self.actionKeys(of: manifest)
            var retired: [VersionFolder] = []

            switch activation.kind {
            case .fresh, .transition:
                try ExtensionRecord(
                    localIdentity: activation.identity,
                    manifestIdentifier: manifest.identifier,
                    identifierOrigin: manifest.identifierOrigin,
                    name: manifest.name.english,
                    provenance: activation.provenance,
                    activeVersion: activation.digest,
                    state: .enabled,
                    updatesPaused: false,
                    installedAt: now()
                ).insert(db)
                try insertVersion(activation, in: db)
            case .update:
                guard var record = try ExtensionRecord.fetchOne(db, key: activation.identity) else {
                    throw StoreError.notInstalled(activation.identity)
                }
                try snapshotOptions(of: record, in: db)
                // One previous version is kept for rollback (EXM-13); anything older goes.
                for old in try ExtensionVersionRecord.filter(Column("local_identity") == record.localIdentity).fetchAll(db)
                where old.contentDigest != record.activeVersion && old.contentDigest != activation.digest {
                    try old.delete(db)
                    retired.append(VersionFolder(identity: old.localIdentity, digest: old.contentDigest))
                }
                if let previous = record.activeVersion {
                    try db.execute(
                        sql: "UPDATE extension_version SET retained = 1 WHERE local_identity = ? AND content_digest = ?",
                        arguments: [record.localIdentity, previous]
                    )
                }
                try insertVersion(activation, in: db)
                record.activeVersion = activation.digest
                record.manifestIdentifier = manifest.identifier
                record.identifierOrigin = manifest.identifierOrigin
                record.name = manifest.name.english
                record.provenance = activation.provenance
                // The user has just approved these bytes. A version the user had switched off stays
                // off; one that was waiting for approval has it now.
                if record.state == .pendingApproval { record.state = .enabled }
                try record.update(db)
                let instances = try InstanceRecord
                    .filter(Column("local_identity") == record.localIdentity && Column("deleted_at") == nil)
                    .fetchAll(db)
                for instance in instances {
                    try reconcile(instance.id, with: keys, in: db)
                }
                try replaceGrants(of: record.localIdentity, at: activation.digest, granting: activation.granted, in: db)
                return retired
            }

            if case .transition(let old) = activation.kind {
                guard let previous = try ExtensionRecord.fetchOne(db, key: old) else { throw StoreError.notInstalled(old) }
                guard !previous.isBuiltin else { throw StoreError.builtinCannotBeRemoved }
                try snapshotOptions(of: previous, in: db)
                let oldInstances = try InstanceRecord
                    .filter(Column("local_identity") == old && Column("deleted_at") == nil)
                    .order(Column("id"))
                    .fetchAll(db)
                for oldInstance in oldInstances {
                    var instance = oldInstance
                    instance.id = InstanceID()
                    instance.localIdentity = activation.identity
                    instance.revision = 1
                    instance.deviceID = deviceID
                    try instance.insert(db)
                    for var option in try OptionValueRecord.filter(Column("instance_id") == oldInstance.id).fetchAll(db) {
                        option.instanceID = instance.id
                        option.revision = 1
                        option.deviceID = deviceID
                        try option.insert(db)
                    }
                    // The list keeps its items and their places; only what they point at changes.
                    for var item in try liveItems(of: [oldInstance.id], in: db) {
                        item.instanceID = instance.id
                        try touch(&item)
                        try item.update(db)
                    }
                    try reconcile(instance.id, with: keys, in: db)
                }
                retired += try remove(previous, in: db)
            } else {
                let instance = try insertInstance(for: activation.identity, in: db)
                try appendItems(keys, for: instance, in: db)
            }
            try replaceGrants(of: activation.identity, at: activation.digest, granting: activation.granted, in: db)
            return retired
        }
        return retired
    }

    /// What deleting one list item did.
    public struct Deletion: Sendable, Equatable {
        /// Set when that was the extension's last action (EXM-9), with the folders to delete.
        public var uninstalled: LocalIdentity?
        public var retired: [VersionFolder]
    }

    /// Tombstone one action; if it was the last live action of an installed extension, uninstall the
    /// extension too (EXM-9). A built-in is never uninstalled — its actions can be restored.
    public func deleteListItem(_ id: ListItemID) throws -> Deletion {
        try database.write { db in
            guard var item = try ListItemRecord.fetchOne(db, key: id), item.deletedAt == nil else {
                return Deletion(uninstalled: nil, retired: [])
            }
            item.deletedAt = now()
            try touch(&item)
            try item.update(db)

            guard let instanceID = item.instanceID,
                  let instance = try InstanceRecord.fetchOne(db, key: instanceID),
                  let owner = try ExtensionRecord.fetchOne(db, key: instance.localIdentity),
                  !owner.isBuiltin
            else { return Deletion(uninstalled: nil, retired: []) }

            let instances = try InstanceRecord
                .filter(Column("local_identity") == owner.localIdentity && Column("deleted_at") == nil)
                .fetchAll(db)
                .map(\.id)
            guard try liveItems(of: instances, in: db).isEmpty else { return Deletion(uninstalled: nil, retired: []) }
            return Deletion(uninstalled: owner.localIdentity, retired: try remove(owner, in: db))
        }
    }

    /// Manage Extensions' Uninstall (EXM-6, M4), and the end of every path that removes an extension.
    public func uninstall(_ identity: LocalIdentity) throws -> [VersionFolder] {
        try database.write { db in
            guard let record = try ExtensionRecord.fetchOne(db, key: identity) else { throw StoreError.notInstalled(identity) }
            guard !record.isBuiltin else { throw StoreError.builtinCannotBeRemoved }
            return try remove(record, in: db)
        }
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case notInstalled(LocalIdentity)
        case builtinCannotBeRemoved

        public var description: String {
            switch self {
            case .notInstalled(let identity): "No extension is installed as \(identity)."
            case .builtinCannotBeRemoved: "A built-in extension cannot be uninstalled; its actions can be deleted and restored."
            }
        }
    }

    // MARK: Internals

    /// The key each of a manifest's actions is stored under: `ActionKey`'s spelling.
    static func actionKeys(of manifest: ExtensionManifest) -> [String] {
        manifest.actions.enumerated().map { ActionKey(extensionIdentifier: manifest.identifier, action: $1, at: $0).action }
    }

    private func insertVersion(_ activation: Activation, in db: Database) throws {
        try ExtensionVersionRecord(
            localIdentity: activation.identity,
            contentDigest: activation.digest,
            form: activation.form,
            signatureStatus: .unsigned,
            retained: false,
            createdAt: now()
        ).save(db)
    }

    private func insertInstance(for identity: LocalIdentity, in db: Database) throws -> InstanceID {
        let instance = InstanceRecord(
            id: InstanceID(),
            localIdentity: identity,
            name: nil,
            icon: nil,
            showAs: nil,
            color: nil,
            revision: 1,
            deviceID: deviceID,
            deletedAt: nil
        )
        try instance.insert(db)
        return instance.id
    }

    private func appendItems(_ keys: [String], for instance: InstanceID, in db: Database) throws {
        guard !keys.isEmpty else { return }
        // After the last key of *any* row, tombstones included: a key a deleted item held is not
        // reused, so that a device that has not heard of the deletion cannot see two items collide.
        let last = try OrderKey.fetchOne(db, sql: "SELECT order_key FROM list_item WHERE parent_id IS NULL ORDER BY order_key DESC LIMIT 1")
        for (key, orderKey) in zip(keys, OrderKey.sequence(keys.count, after: last)) {
            try ListItemRecord(
                id: ListItemID(),
                parentID: nil,
                kind: .action,
                orderKey: orderKey,
                instanceID: instance,
                actionKey: key,
                enabled: true,
                revision: 1,
                deviceID: deviceID,
                deletedAt: nil
            ).insert(db)
        }
    }

    private func liveItems(of instances: [InstanceID], in db: Database) throws -> [ListItemRecord] {
        guard !instances.isEmpty else { return [] }
        return try ListItemRecord
            .filter(instances.contains(Column("instance_id")) && Column("deleted_at") == nil)
            .order(Column("order_key"), Column("id"))
            .fetchAll(db)
    }

    /// After a new version: items for actions that are gone are tombstoned, and actions this instance
    /// has never had an item for are appended. An action the user deleted stays deleted.
    private func reconcile(_ instance: InstanceID, with keys: [String], in db: Database) throws {
        let all = try ListItemRecord.filter(Column("instance_id") == instance).fetchAll(db)
        let wanted = Set(keys)
        for var item in all where item.deletedAt == nil && !(item.actionKey.map(wanted.contains) ?? false) {
            item.deletedAt = now()
            try touch(&item)
            try item.update(db)
        }
        let seen = Set(all.compactMap(\.actionKey))
        try appendItems(keys.filter { !seen.contains($0) }, for: instance, in: db)
    }

    private func snapshotOptions(of record: ExtensionRecord, in db: Database) throws {
        guard let version = record.activeVersion else { return }
        var options: [String: [String: String]] = [:]
        for instance in try InstanceRecord.filter(Column("local_identity") == record.localIdentity && Column("deleted_at") == nil).fetchAll(db) {
            let values = try OptionValueRecord.filter(Column("instance_id") == instance.id).fetchAll(db)
            options[instance.id.description] = Dictionary(values.map { ($0.optionID, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        try ConfigSnapshotRecord(
            id: UUID().uuidString.lowercased(),
            localIdentity: record.localIdentity,
            versionDigest: version,
            options: options,
            createdAt: now()
        ).insert(db)
    }

    /// The extension's row and versions go; its instances and items stay as tombstones; its option
    /// values and snapshots go, because they belonged to an identity that no longer exists.
    private func remove(_ record: ExtensionRecord, in db: Database) throws -> [VersionFolder] {
        let versions = try ExtensionVersionRecord.filter(Column("local_identity") == record.localIdentity).fetchAll(db)
        let instances = try InstanceRecord.filter(Column("local_identity") == record.localIdentity && Column("deleted_at") == nil).fetchAll(db)
        for var item in try liveItems(of: instances.map(\.id), in: db) {
            item.deletedAt = now()
            try touch(&item)
            try item.update(db)
        }
        for var instance in instances {
            instance.deletedAt = now()
            instance.revision += 1
            instance.deviceID = deviceID
            try instance.update(db)
            try OptionValueRecord.filter(Column("instance_id") == instance.id).deleteAll(db)
        }
        try ConfigSnapshotRecord.filter(Column("local_identity") == record.localIdentity).deleteAll(db)
        try record.delete(db)
        return versions.map { VersionFolder(identity: $0.localIdentity, digest: $0.contentDigest) }
    }

    private func touch(_ item: inout ListItemRecord) throws {
        item.revision += 1
        item.deviceID = deviceID
    }
}

/// `Extensions/<LocalIdentity>/<digest>/`: one immutable version of one extension (architecture §9.4).
public struct VersionFolder: Sendable, Hashable, CustomStringConvertible {
    public var identity: LocalIdentity
    public var digest: ContentDigest

    public init(identity: LocalIdentity, digest: ContentDigest) {
        self.identity = identity
        self.digest = digest
    }

    public var description: String { "\(identity)/\(digest.hex)" }
}
