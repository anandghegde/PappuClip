import Foundation

/// One search preset (PRD §7.4).
public struct SearchEngine: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String
    /// A brand name, shown as written and never translated.
    public var name: String
    /// A URL with `***` where the term goes — the same placeholder the custom-URL setting uses.
    public var template: String

    public init(id: String, name: String, template: String) {
        self.id = id
        self.name = name
        self.template = template
    }

    /// §7.4's placeholder.
    public static let placeholder = "***"

    /// The URL to open for `term`, or nil when the template has no placeholder or does not make a URL.
    ///
    /// The term is percent-encoded against the unreserved set of RFC 3986 rather than against a query
    /// allowed-set, because the term is *data inside* a query: `.urlQueryAllowed` leaves `&`, `=` and
    /// `+` alone, and a selection containing any of them would silently become extra query parameters.
    public func url(searching term: String) -> URL? {
        guard template.contains(Self.placeholder) else { return nil }
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: Self.placeholder, with: encoded))
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

/// `Resources/search-engines.json`: the Search built-in's presets, as data (PRD §7.4).
///
/// Data rather than code for the same reason the scheme list is: the set changes for reasons that
/// have nothing to do with this app — an engine changes its query parameter, a new one is worth
/// offering — and none of those should be a code review. It is also what a user's custom URL is
/// measured against, which is why the placeholder lives on `SearchEngine` and not in the setting.
public struct SearchEngines: Sendable, Equatable, Codable {
    /// Bumped when a field changes meaning. Same rule as `URLSchemes` and `DetectionPolicies`.
    public static let supportedSchema = 1

    public struct UnsupportedSchema: Error, CustomStringConvertible, Equatable {
        public var found: Int
        public var description: String {
            "Search engine list schema \(found); this build reads \(SearchEngines.supportedSchema)."
        }
    }

    public var schema: Int
    public var sequence: Int
    /// Why the list holds what it holds, since JSON cannot carry a comment.
    public var note: String?
    /// The id a fresh install uses (PRD §7.4: Google).
    public var defaultID: String
    public var engines: [SearchEngine]

    public init(
        schema: Int = SearchEngines.supportedSchema,
        sequence: Int = 1,
        note: String? = nil,
        defaultID: String,
        engines: [SearchEngine]
    ) {
        self.schema = schema
        self.sequence = sequence
        self.note = note
        self.defaultID = defaultID
        self.engines = engines
    }

    private enum CodingKeys: String, CodingKey {
        case schema, sequence, note
        case defaultID = "default"
        case engines
    }

    public subscript(id: String) -> SearchEngine? {
        engines.first { $0.id == id }
    }

    /// The engine a fresh install searches with, falling back to the first in the file rather than to
    /// nothing: a `default` naming an engine the file does not hold is a mistake in the data, and the
    /// user's answer to it should be a search, not a missing button.
    public var preferred: SearchEngine? {
        self[defaultID] ?? engines.first
    }

    // MARK: Loading

    /// In `Resources/` in the repository, and at the top of the app bundle's resources.
    public static let fileName = "search-engines.json"

    public static func bundled(in bundle: Bundle) throws -> SearchEngines {
        guard let url = bundle.url(forResource: "search-engines", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> SearchEngines {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> SearchEngines {
        let engines = try JSONDecoder().decode(SearchEngines.self, from: data)
        guard engines.schema == supportedSchema else { throw UnsupportedSchema(found: engines.schema) }
        return engines
    }

    /// What Search uses when the bundled file cannot be read.
    ///
    /// One entry, unlike `URLSchemes.none`, and the difference is worth stating. A missing scheme list
    /// costs the user a kind of detection, and guessing at it would mean launching schemes nobody
    /// reviewed. A missing engine list costs a P0 built-in entirely, and the guess is a single address
    /// the PRD already names as the default. The failure mode of the safe answer is worse than the
    /// failure mode of the guess, which is the whole of why they differ.
    public static let fallback = SearchEngines(
        sequence: 0,
        note: "Fallback: the bundled search-engines.json could not be read.",
        defaultID: "google",
        engines: [SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=***")]
    )
}

/// The Search built-in's setting: which engine, or the user's own URL (PRD §7.4).
///
/// **Why it is a type and not two defaults keys.** The custom URL and the preset are one choice with
/// two spellings, and the rule that a custom URL wins belongs with them rather than with whatever reads
/// them. It is also the first extension *option* in the program (§8.9) — in M2 this becomes two entries
/// in the Search extension's own option table, and this type is what that migration replaces.
public struct SearchPreference: Sendable, Equatable, Hashable, Codable {
    /// The preset the user picked. Nil, or a preset the list no longer holds, means the list's default.
    public var engineID: String?
    /// A URL with `***` where the term goes. Ignored when it carries no placeholder, because a template
    /// that cannot take the selection would search for nothing at all.
    public var customTemplate: String?

    public init(engineID: String? = nil, customTemplate: String? = nil) {
        self.engineID = engineID
        self.customTemplate = customTemplate
    }

    /// The id a custom URL searches under, so that a record can say which of the two was used without
    /// carrying the URL itself.
    public static let customID = "custom"

    /// What to search with, given the bundled list.
    ///
    /// The custom URL wins when it has a placeholder: a user who typed one has said something more
    /// specific than a preset they may never have changed.
    public func engine(in engines: SearchEngines) -> SearchEngine? {
        if let template = customTemplate, template.contains(SearchEngine.placeholder) {
            // The template is its own name: a custom engine is never in the preset picker, and the one
            // thing a settings row or a record can say about it truthfully is the URL the user typed.
            return SearchEngine(id: Self.customID, name: template, template: template)
        }
        return engineID.flatMap { engines[$0] } ?? engines.preferred
    }
}
