import CryptoKit
import Foundation

/// A stable UUID that is stored, logged and used as a folder name as lower-case text.
///
/// Lower case because a folder name should not depend on the file system's case sensitivity to be
/// unique, and text rather than GRDB's default 16-byte blob so that the database can be read with
/// `sqlite3` when something has gone wrong.
public protocol StableID: Sendable, Hashable, Codable, CustomStringConvertible {
    var uuid: UUID { get }
    init(_ uuid: UUID)
}

extension StableID {
    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(uuid)
    }

    public var description: String { uuid.uuidString.lowercased() }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(string) is not a UUID.")
        }
        self.init(uuid)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The key an installed extension is stored, granted and keyed in the Keychain under (architecture §9.2).
///
/// **The manifest's `identifier` is an attribute, never this.** An identifier is a string in a file
/// that anybody can also write, so two unrelated packages may both say `com.example.translate`; each
/// is given its own `LocalIdentity` and neither can inherit the other's grants or secrets (SEC-8a,
/// SEC-8d). A `LocalIdentity` is minted once, at first install, and survives only replacements whose
/// provenance vouches for them (`Provenance.vouchesForReplacement`).
public struct LocalIdentity: StableID {
    public var uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

/// One instance of an extension: its own name, icon and option values (§8.9, ALM-2a). An extension
/// with options may have several; every extension has at least one while it is installed.
public struct InstanceID: StableID {
    public var uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

/// One row of the action list (ALM-1): an action, and in M4 a folder, a section or a page break.
public struct ListItemID: StableID {
    public var uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }
}

/// SHA-256 over what a package contains (architecture §9.2): for local code this *is* its identity
/// (SEC-8b), so any change to any file is a different extension until the user approves it (SEC-8c).
///
/// The canonical form is one line per regular file, sorted by relative path in byte order:
/// `<path>\0<sha256 hex>\n`. The path is part of it, so renaming a file is a change; the order is
/// fixed, so the same files hash the same whatever order the file system lists them in. A snippet is
/// hashed as its text alone, with the same prefix a one-file package would have, so the two forms
/// cannot collide by accident.
public struct ContentDigest: Sendable, Hashable, Codable, CustomStringConvertible {
    public var hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public init(from decoder: any Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var description: String { hex }

    /// The first 16 hex digits: enough to tell versions apart in a folder name or a log line.
    public var short: String { String(hex.prefix(16)) }

    public static func of(files: [(path: String, contents: Data)]) -> ContentDigest {
        var canonical = Data()
        for file in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            canonical.append(contentsOf: Array(file.path.utf8))
            canonical.append(0)
            canonical.append(contentsOf: Array(Self.hex(SHA256.hash(data: file.contents)).utf8))
            canonical.append(0x0A)
        }
        return ContentDigest(hex: Self.hex(SHA256.hash(data: canonical)))
    }

    public static func of(snippet text: String) -> ContentDigest {
        of(files: [(path: StagedForm.snippetFileName, contents: Data(text.utf8))])
    }

    /// Every regular file under `root`. A package that holds anything else — a symbolic link, a
    /// device, a socket — is refused before it gets this far (`PackageStaging`), so this does not
    /// have to decide what one would mean.
    public static func of(packageAt root: URL) throws -> ContentDigest {
        let files = try PackageStaging.regularFiles(under: root).map { path in
            (path: path, contents: try Data(contentsOf: root.appending(path: path)))
        }
        return of(files: files)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// How the code reached this Mac (EXM-7's "origin", and the half of SEC-8b that is not the digest).
public enum LocalOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    /// A `.popclipext` or `.pappuext` folder, zipped or not (EXM-1).
    case packageFile
    /// A `.popcliptxt` or `.pappucliptxt` file (EXM-1).
    case snippetFile
    /// Text selected in another app, through the bar's Install Extension action (EXM-2).
    case selectedText
}

/// Who vouches for an extension's code (SEC-8b).
///
/// **Local code is vouched for by nobody.** Its identity is where it came from and exactly what it
/// contains, which is why `IdentityResolver` never treats two local packages as "the same trusted
/// provenance" unless their content is identical: there is no key and no publisher that could say a
/// changed file is still the same author's. Registry code has one (M5), and the case is here so that
/// the store's shape does not change when it arrives.
public enum Provenance: Sendable, Hashable, Codable {
    /// Shipped inside the app and covered by its signature.
    case builtin
    case local(LocalOrigin, ContentDigest)
    /// The directory's signed namespace and publisher ownership record (M5).
    case registry(namespace: String, publisherRecord: String, keyID: String)

    /// Whether a *different* package from the same source may replace this one without a trust
    /// transition: only a publisher can say two versions are theirs (EXM-2, SEC-8d).
    public func vouchesForReplacement(by other: Provenance) -> Bool {
        switch (self, other) {
        case let (.registry(namespace, publisher, _), .registry(otherNamespace, otherPublisher, _)):
            namespace == otherNamespace && publisher == otherPublisher
        default:
            false
        }
    }

    public var digest: ContentDigest? {
        if case .local(_, let digest) = self { return digest }
        return nil
    }
}

/// Which form a version folder holds. A package is its files as they were; a snippet is its text in
/// one file, because a snippet's config and its code are the same text and splitting them would
/// store something the author never wrote.
public enum StagedForm: String, Sendable, Hashable, Codable {
    case package
    case snippet

    public static let snippetFileName = "Snippet.pappucliptxt"
}
