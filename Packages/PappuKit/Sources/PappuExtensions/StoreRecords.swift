import Foundation
import GRDB
import PappuCore

// The rows of architecture §11's main tables, as M2 weeks 2 and 5 have them. `app_rule` and its
// neighbours are M4's; the tables arrive with the code that reads them, through a
// new migration, rather than sitting empty.

/// ALM-4 and SEC-5's states for an extension as a whole.
public enum ExtensionState: String, Sendable, Hashable, Codable, CaseIterable {
    case enabled
    /// Installed, and waiting for the user to approve what it may do (EXM-5, SEC-8c).
    case pendingApproval
    case disabled
    /// Stopped by the watchdog (M3).
    case suspended
    /// On the revocation list (M5).
    case revoked
}

/// Whether a version's files carry a signature the app checked (§8.13, M5). Local code never does.
public enum SignatureStatus: String, Sendable, Hashable, Codable {
    case unsigned
    case verified
}

public enum ListItemKind: String, Sendable, Hashable, Codable {
    case action
    // Folders, sections and page breaks are M4 (ALM-2a, BAR-4). The column is text so that adding
    // them is a new case and not a migration.
}

public struct ExtensionRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "extension"

    public var localIdentity: LocalIdentity
    /// An attribute, never a key (SEC-8a).
    public var manifestIdentifier: String
    public var identifierOrigin: IdentifierOrigin
    /// The English name at install, for collision checks and for a list that must be drawn without
    /// reading every package.
    public var name: String
    public var provenance: Provenance
    /// The folder name under the identity's folder; nil for a built-in, whose manifest is in the app.
    public var activeVersion: ContentDigest?
    public var state: ExtensionState
    public var updatesPaused: Bool
    public var installedAt: Date

    public var isBuiltin: Bool { provenance == .builtin }

    enum CodingKeys: String, CodingKey {
        case localIdentity = "local_identity"
        case manifestIdentifier = "manifest_identifier"
        case identifierOrigin = "identifier_origin"
        case name
        case provenance
        case activeVersion = "active_version"
        case state
        case updatesPaused = "updates_paused"
        case installedAt = "installed_at"
    }
}

public struct ExtensionVersionRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "extension_version"

    public var localIdentity: LocalIdentity
    /// Also the version's folder name, so a folder and its row cannot disagree about which is which.
    public var contentDigest: ContentDigest
    public var form: StagedForm
    public var signatureStatus: SignatureStatus
    /// Kept after a newer version became active, for rollback (EXM-13, M5). One is kept.
    public var retained: Bool
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case localIdentity = "local_identity"
        case contentDigest = "content_digest"
        case form
        case signatureStatus = "signature_status"
        case retained
        case createdAt = "created_at"
    }
}

public struct InstanceRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "instance"

    public var id: InstanceID
    public var localIdentity: LocalIdentity
    /// The user's overrides (ALM-2a, M4). Nil means "as the manifest says".
    public var name: String?
    public var icon: String?
    public var showAs: String?
    public var color: String?
    public var revision: Int
    public var deviceID: String
    /// A tombstone (SYN-1): the row stays so that a device that has not heard about the deletion
    /// cannot bring the instance back.
    public var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case localIdentity = "local_identity"
        case name
        case icon
        case showAs = "show_as"
        case color
        case revision
        case deviceID = "device_id"
        case deletedAt = "deleted_at"
    }
}

public struct ListItemRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "list_item"

    public var id: ListItemID
    public var parentID: ListItemID?
    public var kind: ListItemKind
    public var orderKey: OrderKey
    public var instanceID: InstanceID?
    /// Which of the instance's extension's actions: `ActionKey.action`'s spelling, the action's own
    /// identifier or its position.
    public var actionKey: String?
    public var enabled: Bool
    public var revision: Int
    public var deviceID: String
    public var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case kind
        case orderKey = "order_key"
        case instanceID = "instance_id"
        case actionKey = "action_key"
        case enabled
        case revision
        case deviceID = "device_id"
        case deletedAt = "deleted_at"
    }
}

public struct OptionValueRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "option_value"

    public var instanceID: InstanceID
    public var optionID: String
    /// Never a secret: those are the Keychain's (SEC-3), which is why a snapshot of this table can
    /// be taken, exported and restored without a filter.
    public var value: String
    public var revision: Int
    public var deviceID: String

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case optionID = "option_id"
        case value
        case revision
        case deviceID = "device_id"
    }
}

/// The non-secret options as they were when a version stopped being active (architecture §9.4).
public struct ConfigSnapshotRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "config_snapshot"

    public var id: String
    public var localIdentity: LocalIdentity
    public var versionDigest: ContentDigest
    /// Instance ID → option ID → value.
    public var options: [String: [String: String]]
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case localIdentity = "local_identity"
        case versionDigest = "version_digest"
        case options
        case createdAt = "created_at"
    }
}

// Columns are snake case, spelled out in each record's `CodingKeys`; every stable ID is text.
extension LocalIdentity: DatabaseValueConvertible {}
extension InstanceID: DatabaseValueConvertible {}
extension ListItemID: DatabaseValueConvertible {}

extension StableID where Self: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
        String.fromDatabaseValue(dbValue).flatMap(Self.init)
    }
}

extension ContentDigest: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { hex.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ContentDigest? {
        String.fromDatabaseValue(dbValue).map(ContentDigest.init(hex:))
    }
}

extension OrderKey: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> OrderKey? {
        String.fromDatabaseValue(dbValue).flatMap(OrderKey.init)
    }
}

/// One approval (EXM-5, SEC-4, SEC-8): a capability key, given to one identity for one version's bytes.
///
/// The digest is what makes an approval about *code* and not about a name (SEC-8a, SEC-8c): a grant
/// whose digest is not the active version's approves nothing, so a content change is pending approval
/// again without anything having to remember to revoke the old grant.
public struct GrantRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "grant"

    public var localIdentity: LocalIdentity
    /// `GrantKey`'s raw value.
    public var capability: String
    public var contentDigest: ContentDigest
    public var grantedAt: Date

    public var key: GrantKey? { GrantKey(rawValue: capability) }

    enum CodingKeys: String, CodingKey {
        case localIdentity = "local_identity"
        case capability
        case contentDigest = "content_digest"
        case grantedAt = "granted_at"
    }
}

/// What a grant row approves: running at all, or one gated capability.
public enum GrantKey: Sendable, Hashable, RawRepresentable {
    /// EXM-5c: the install confirmation, which approves every listed capability together.
    case execution
    /// EXM-5d: one switch, off unless the user turned it on.
    case gated(GatedCapability)

    public init?(rawValue: String) {
        if rawValue == "execution" {
            self = .execution
        } else if let gate = GatedCapability(rawValue: rawValue) {
            self = .gated(gate)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .execution: "execution"
        case .gated(let gate): gate.rawValue
        }
    }
}
