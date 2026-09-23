import Foundation

/// One entry in an action's `requirements` (§8.5 step 2, FLT-5).
///
/// The list is closed, because it is an API this project does not own: an extension written for
/// PopClip names one of these strings and expects the same answer here. A spelling that is not on the
/// list is kept as `.unrecognised` rather than dropped, and an action that asks for something we do
/// not understand is never shown — an unknown requirement is a requirement that does not hold, which
/// is the safe half of the two ways to be wrong.
public struct ActionRequirement: Sendable, Equatable, Hashable, Codable {
    /// The conditions themselves, without the `!`.
    public enum Condition: Sendable, Equatable, Hashable {
        /// There is a selection. The synonym `copy` means the same thing and is the older spelling.
        case text
        /// Cut is available where the selection is (FLT-6).
        case cut
        /// Paste is available where the selection is (FLT-6).
        case paste
        /// The selection contains at least one web address. Narrows the action's input to the first
        /// one (step 3). Legacy `httpurl` is the same condition.
        case url
        /// The selection is one address and nothing else. Narrows to it.
        case isURL
        /// The selection contains at least one web address. Legacy `httpurls` is the same condition.
        case urls
        /// The selection contains at least one email address. Narrows to the first.
        case email
        case emails
        /// The selection contains a path that exists on this Mac. Narrows to the first.
        case path
        /// The control can describe its text with attributes, which is what a formatting action needs.
        case formatting
        /// `option-<id>=<value>`, with booleans written `1` and `0`. The option *model* is §8.9 and
        /// lands in M2; the condition is parsed now so that a manifest carrying one is read faithfully
        /// rather than rejected, and `ActionMatching` is told how to answer it by whoever holds the
        /// values.
        case option(id: String, value: String)
        /// A spelling this build does not know. Never satisfied.
        case unrecognised(String)
    }

    public var condition: Condition
    /// `!` in front of the entry: the condition must *not* hold.
    public var isNegated: Bool

    public init(_ condition: Condition, negated: Bool = false) {
        self.condition = condition
        self.isNegated = negated
    }

    /// The default when an action names no requirements at all (§8.3): there is a selection.
    public static let text = ActionRequirement(.text)

    // MARK: Spelling

    public init(parsing spelling: String) {
        var body = spelling.trimmingCharacters(in: .whitespaces)
        var negated = false
        while body.hasPrefix("!") {
            negated.toggle()
            body.removeFirst()
            body = body.trimmingCharacters(in: .whitespaces)
        }
        self.init(Condition(parsing: body), negated: negated)
    }

    public var spelling: String {
        (isNegated ? "!" : "") + condition.spelling
    }

    public init(from decoder: any Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(spelling)
    }
}

extension ActionRequirement.Condition {
    /// Legacy and synonym spellings, folded onto the condition they mean (§8.5, Appendix A).
    ///
    /// `copy` is PopClip's older name for `text`, and `httpurl`/`httpurls` predate non-http schemes
    /// having their own lists. Matching is case-insensitive because manifests in the wild are.
    static let synonyms: [String: ActionRequirement.Condition] = [
        "text": .text,
        "copy": .text,
        "cut": .cut,
        "paste": .paste,
        "url": .url,
        "httpurl": .url,
        "isurl": .isURL,
        "urls": .urls,
        "httpurls": .urls,
        "email": .email,
        "emails": .emails,
        "path": .path,
        "formatting": .formatting,
    ]

    init(parsing body: String) {
        let lowered = body.lowercased()
        if let known = Self.synonyms[lowered] {
            self = known
            return
        }
        // `option-<id>=<value>`. The id keeps its case, because option ids are author-chosen
        // identifiers and `option-apiKey` is not `option-apikey`.
        if lowered.hasPrefix("option-") {
            let rest = body.dropFirst("option-".count)
            if let equals = rest.firstIndex(of: "=") {
                self = .option(id: String(rest[rest.startIndex..<equals]), value: String(rest[rest.index(after: equals)...]))
                return
            }
            // No `=` at all is PopClip's shorthand for "the option is on".
            self = .option(id: String(rest), value: "1")
            return
        }
        self = .unrecognised(body)
    }

    var spelling: String {
        switch self {
        case .text: "text"
        case .cut: "cut"
        case .paste: "paste"
        case .url: "url"
        case .isURL: "isurl"
        case .urls: "urls"
        case .email: "email"
        case .emails: "emails"
        case .path: "path"
        case .formatting: "formatting"
        case .option(let id, let value): "option-\(id)=\(value)"
        case .unrecognised(let spelling): spelling
        }
    }

    /// Which detection, if any, this condition narrows the action's input to (§8.5 step 3).
    ///
    /// Only four conditions narrow, and `urls`/`emails` — the plural forms — deliberately do not: an
    /// action that asks for "the addresses" wants all of them, and narrowing to the first would be a
    /// quiet way of losing the rest.
    var narrowsTo: NarrowingKind? {
        switch self {
        case .url, .isURL: .url
        case .email: .email
        case .path: .path
        default: nil
        }
    }
}

/// The detection kinds the matching pipeline narrows to (§8.5 step 3).
///
/// A mirror of the analyser's `Detection.Kind`, in the module the pipeline lives in, because
/// `PappuCore` is below `PappuAnalysis` and the CLI and the registry's CI run the pipeline with no
/// analyser at all (architecture §15).
public enum NarrowingKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Both address kinds: a bare `omnifocus:///task/1` is as much a link as an `https://` one, which
    /// is the same rule `AnalyzedSelection.isSingleURL` follows.
    case url
    case email
    case path
}
