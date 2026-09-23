import Foundation

/// The bundled `DetectionPolicies.json` document (architecture §4.6, ACT-11a), and from M5 the
/// signed remote one that replaces it (ACT-11b).
///
/// The schema has no field that can express a privacy rule — no hard block, no pause, no exclusion —
/// which is half of why a remote update cannot loosen anything. The other half is
/// `DetectionPolicyStore`, which restricts whatever it is given by the user's ceilings (SEC-9).
public struct DetectionPolicies: Sendable, Equatable, Codable {
    /// Bumped when a field changes meaning. A document from the future is refused rather than read
    /// with the fields we happen to recognise.
    public static let supportedSchema = 1

    public struct UnsupportedSchema: Error, CustomStringConvertible, Equatable {
        public var found: Int
        public var description: String {
            "Detection policy schema \(found); this build reads \(DetectionPolicies.supportedSchema)."
        }
    }

    public var schema: Int
    /// Monotonic. A remote document whose sequence is at or below the one in hand is a replay (SEC-9).
    public var sequence: Int
    /// Where the values came from, since JSON cannot carry a comment and these are mostly provisional.
    public var note: String?
    /// The policy for an app with no entry: strategies 1–4, no synthetic copy on the automatic path.
    public var `default`: DetectionPolicy
    public var apps: [String: DetectionPolicyRecord]
    /// Matched by longest bundle-identifier prefix when `apps` has no exact entry.
    ///
    /// A vendor's editors share a quirk and ship under one identifier family. Enumerating them means
    /// the next one released is unflagged, and for `copiesLineWhenEmpty` an unflagged app is a paste
    /// of the wrong line rather than a missing feature — so the family, not the member, is what the
    /// file names (ACT-11a).
    public var prefixes: [String: DetectionPolicyRecord]

    public init(
        schema: Int = DetectionPolicies.supportedSchema,
        sequence: Int = 1,
        note: String? = nil,
        default: DetectionPolicy,
        apps: [String: DetectionPolicyRecord] = [:],
        prefixes: [String: DetectionPolicyRecord] = [:]
    ) {
        self.schema = schema
        self.sequence = sequence
        self.note = note
        self.default = `default`
        self.apps = apps
        self.prefixes = prefixes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schema: try container.decode(Int.self, forKey: .schema),
            sequence: try container.decode(Int.self, forKey: .sequence),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            default: try container.decode(DetectionPolicy.self, forKey: .default),
            apps: try container.decodeIfPresent([String: DetectionPolicyRecord].self, forKey: .apps) ?? [:],
            prefixes: try container.decodeIfPresent([String: DetectionPolicyRecord].self, forKey: .prefixes) ?? [:]
        )
    }

    /// The entry that speaks for this app: the exact one, else the longest matching prefix, else none.
    ///
    /// A process with no bundle identifier — a helper tool, something started from a shell — cannot be
    /// named in a policy, so it takes the default. The same rule as `PrivacyRules.mode(for:)`.
    public func record(for bundleID: String?) -> DetectionPolicyRecord? {
        guard let bundleID else { return nil }
        if let exact = apps[bundleID] { return exact }
        return prefixes
            .filter { bundleID.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// The bundled policy for an app, before the user's ceilings. `DetectionPolicyStore` is what
    /// callers want; this is the half of it that the file answers.
    public func policy(for bundleID: String?) -> DetectionPolicy {
        record(for: bundleID)?.applied(to: `default`) ?? `default`
    }

    /// The document's file name, wherever it sits: `Resources/DetectionPolicies/` in the repository,
    /// and the same name in the app bundle once there is one to copy it into.
    public static let fileName = "detection-policies.json"

    /// The copy built into an app bundle. The remote document (M5) arrives as `Data` instead and goes
    /// through `decode` once its signature has been checked (SEC-9).
    public static func bundled(in bundle: Bundle) throws -> DetectionPolicies {
        guard let url = bundle.url(
            forResource: (fileName as NSString).deletingPathExtension,
            withExtension: (fileName as NSString).pathExtension
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    public static func decode(_ data: Data) throws -> DetectionPolicies {
        let policies = try JSONDecoder().decode(DetectionPolicies.self, from: data)
        guard policies.schema == supportedSchema else {
            throw UnsupportedSchema(found: policies.schema)
        }
        return policies
    }

    /// Reads the document from a file. The app bundle's copy is built from
    /// `Resources/DetectionPolicies/detection-policies.json`; the remote one (M5) arrives as `Data`
    /// and goes through `decode` after its signature is checked.
    public static func load(from url: URL) throws -> DetectionPolicies {
        try decode(Data(contentsOf: url))
    }
}
