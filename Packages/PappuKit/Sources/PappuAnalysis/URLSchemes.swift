import Foundation

/// The non-http schemes a selection may contain (FLT-2, PRD §7.5), as data rather than code.
///
/// It is a closed list because a detection here is what Open Link offers to hand to `NSWorkspace`, and
/// the set of things a Mac will launch from a URL is not one to guess at from a selection: a scheme
/// that is not named is left as ordinary text. Adding one is a review of
/// `Resources/url-schemes.json`, which is also what makes the rename mitigation in PRD §14 cheap.
public struct URLSchemes: Sendable, Equatable, Codable {
    /// Bumped when a field changes meaning; a document from the future is refused rather than read
    /// with the fields we happen to recognise. The same rule as `DetectionPolicies`.
    public static let supportedSchema = 1

    public struct UnsupportedSchema: Error, CustomStringConvertible, Equatable {
        public var found: Int
        public var description: String {
            "URL scheme list schema \(found); this build reads \(URLSchemes.supportedSchema)."
        }
    }

    public var schema: Int
    public var sequence: Int
    /// Why the list holds what it holds, since JSON cannot carry a comment.
    public var note: String?
    /// Lower-cased, without the colon.
    public var schemes: [String]

    private let lookup: Set<String>

    public init(
        schema: Int = URLSchemes.supportedSchema,
        sequence: Int = 1,
        note: String? = nil,
        schemes: [String]
    ) {
        self.schema = schema
        self.sequence = sequence
        self.note = note
        self.schemes = schemes
        lookup = Set(schemes.map { $0.lowercased() })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schema: try container.decode(Int.self, forKey: .schema),
            sequence: try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 1,
            note: try container.decodeIfPresent(String.self, forKey: .note),
            schemes: try container.decode([String].self, forKey: .schemes)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(schemes, forKey: .schemes)
    }

    private enum CodingKeys: String, CodingKey {
        case schema, sequence, note, schemes
    }

    /// Schemes are case-insensitive by RFC 3986, and users paste them in whatever case they were
    /// written in.
    public func contains(_ scheme: String) -> Bool {
        lookup.contains(scheme.lowercased())
    }

    public static func == (lhs: URLSchemes, rhs: URLSchemes) -> Bool {
        lhs.schema == rhs.schema && lhs.sequence == rhs.sequence
            && lhs.note == rhs.note && lhs.schemes == rhs.schemes
    }

    /// The document's file name, in `Resources/` in the repository and at the top of the app bundle's
    /// resources once there is one to copy it into.
    public static let fileName = "url-schemes.json"

    public static func bundled(in bundle: Bundle) throws -> URLSchemes {
        guard let url = bundle.url(forResource: "url-schemes", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> URLSchemes {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> URLSchemes {
        let schemes = try JSONDecoder().decode(URLSchemes.self, from: data)
        guard schemes.schema == supportedSchema else { throw UnsupportedSchema(found: schemes.schema) }
        return schemes
    }

    /// What the analyser uses when the bundled file cannot be read.
    ///
    /// Empty, not a guess: a missing list means no non-http detections, which costs the user one kind
    /// of action. A built-in guess would mean the app offering to launch schemes nobody reviewed, from
    /// text it found on screen.
    public static let none = URLSchemes(schemes: [])
}
