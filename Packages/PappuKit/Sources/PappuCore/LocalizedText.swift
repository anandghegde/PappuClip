import Foundation

/// A string an extension shows, in whatever languages its author wrote it in (§8.3).
///
/// Two forms, because the format this one has to read already has two: a plain string, which is the
/// shape almost every manifest in the wild uses, and a dictionary keyed by language code, in which
/// `en` is required. Both decode to the same value, and a manifest that round-trips through this type
/// keeps the form it arrived in — an author who wrote one string gets one string back, which matters
/// for View Source (EXM-7) and for the registry's diff.
///
/// **Why the extensions' strings do not go through the app's catalogue.** Every word *the app* says is
/// looked up in `Localizable.strings` (PRD §7.12, and `BarStrings` is the pattern). An extension's
/// words are not the app's: they arrive with the extension, they change when it updates, and a
/// catalogue the app ships could never hold them. The bundled built-ins are extensions by the same
/// rule (architecture §19 item 2), so their names live here too, in `Resources/BuiltinExtensions/`,
/// and the other languages are added to that file in M4 alongside the externalisation audit.
public enum LocalizedText: Sendable, Equatable, Hashable, Codable {
    /// One string, in no declared language. Read as English, because that is what `en` being required
    /// in the other form means.
    case plain(String)
    /// Language code to string. `en` is present or the value does not decode.
    case localized([String: String])

    public struct MissingEnglish: Error, CustomStringConvertible, Equatable {
        public var languages: [String]
        public var description: String {
            "A localizable string needs an `en` entry; this one has \(languages.sorted().joined(separator: ", "))."
        }
    }

    public init(_ text: String) {
        self = .plain(text)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let plain = try? container.decode(String.self) {
            self = .plain(plain)
            return
        }
        let table = try container.decode([String: String].self)
        guard table["en"] != nil else { throw MissingEnglish(languages: Array(table.keys)) }
        self = .localized(table)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let text): try container.encode(text)
        case .localized(let table): try container.encode(table)
        }
    }

    /// English, which every form has and which is what the app falls back to.
    public var english: String {
        switch self {
        case .plain(let text): text
        case .localized(let table): table["en"] ?? ""
        }
    }

    /// The best match for `languages`, most-preferred first, and English when none of them is here.
    ///
    /// Matching is by the language alone: an author who wrote `pt` meant it for a reader whose Mac
    /// says `pt-BR`, and a reader whose Mac says `pt-BR` would rather have `pt` than English.
    public func text(for languages: [String]) -> String {
        guard case .localized(let table) = self else { return english }
        for language in languages {
            if let exact = table[language] { return exact }
            let base = String(language.prefix(while: { $0 != "-" && $0 != "_" }))
            if let loose = table[base] { return loose }
        }
        return english
    }

    /// What the running system prefers, which is what the bar draws.
    public func text(for locale: Locale = .current) -> String {
        text(for: [locale.identifier.replacingOccurrences(of: "_", with: "-")]
            + Locale.preferredLanguages)
    }
}

extension LocalizedText: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .plain(value)
    }
}

extension LocalizedText: CustomStringConvertible {
    /// English, deliberately: a description is for a log or a test failure, and neither should change
    /// with the machine's language.
    public var description: String { english }
}
