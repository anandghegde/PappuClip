import Foundation

/// A decoded extension config, before anything has decided what its keys mean (architecture §9.1).
///
/// Three file formats arrive here — YAML, JSON and property lists — and each has its own idea of what
/// a number, a boolean and a missing value are. This is the one shape all three are decoded into, so
/// that `ManifestBuilder` is written once and a manifest means the same thing whichever format its
/// author happened to prefer.
///
/// **Dictionaries keep their order.** Neither YAML nor JSON promises any, but authors write keys in an
/// order, and a diagnostic that names "the second of two spellings of `title`" or a View Source that
/// shows the keys where the author put them both need it. It costs a linear lookup over dictionaries
/// that hold a dozen keys.
public enum ConfigValue: Sendable, Equatable, Hashable {
    /// YAML `null` and `~`, JSON `null`, and a plist's `<false/>` (FMT-5, see `ConfigDecoding`).
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ConfigValue])
    /// Keys exactly as written. `KeyNormalizer` reads them; nothing rewrites them, because some
    /// dictionaries are not manifest keys at all — a localizable string is keyed by language code, and
    /// `pt-BR` normalised would be `pt br`.
    case dictionary([Entry])

    public struct Entry: Sendable, Equatable, Hashable {
        public var key: String
        public var value: ConfigValue

        public init(_ key: String, _ value: ConfigValue) {
            self.key = key
            self.value = value
        }
    }

    public var isNull: Bool { self == .null }

    /// A scalar written as text, for keys that take a string and are often given something else —
    /// `popclipVersion: "4151"`, or a YAML author's unquoted `keywords: 2021`.
    public var scalarText: String? {
        switch self {
        case .string(let text): text
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null, .array, .dictionary: nil
        }
    }

    /// What kind of value this is, in words, for a message that says what was expected instead.
    public var kindName: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .int: "an integer"
        case .double: "a number"
        case .string: "a string"
        case .array: "a list"
        case .dictionary: "a dictionary"
        }
    }
}

extension ConfigValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: ConfigValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}

extension ConfigValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ConfigValue)...) {
        self = .dictionary(elements.map { Entry($0.0, $0.1) })
    }
}
