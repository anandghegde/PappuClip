import Foundation
import Yams

/// The three formats a config arrives in (FMT-1, FMT-4).
public enum ConfigFormat: String, Sendable, Equatable, Hashable, CaseIterable {
    /// YAML 1.2. Also what a snippet's body is read as, which is why flow YAML and JSON are accepted
    /// there (FMT-1): both are YAML 1.2.
    case yaml
    /// `Config.json`, parsed as JSON and nothing else.
    case json
    /// `Config.plist`, XML or binary.
    case plist
}

/// Bytes or text to `ConfigValue` (architecture §9.1, "Decode").
///
/// **YAML is read as 1.2, not as libYAML's 1.1.** Yams resolves plain scalars with YAML 1.1's rules
/// by default, under which `yes`, `no`, `on`, `off`, `y` and `n` are booleans and `0777` is octal. A
/// PopClip extension written against a YAML 1.2 reader means them as strings — a Key Press combo of
/// `n`, an option value of `no` — and reading them otherwise changes what the extension does. So the
/// document is composed with Yams' `basic` resolver, which leaves every scalar a string, and each
/// *plain* scalar is then typed here with the 1.2 core schema. Quoted, literal and folded scalars are
/// strings whatever they spell, as the specification says.
public enum ConfigDecoding {
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public enum Reason: Sendable, Equatable {
            /// The bytes are not text in any encoding the format allows.
            case notText
            /// The file is empty or holds only comments.
            case empty
            /// FMT-1: a tab where indentation was expected.
            case tabIndentation(line: Int)
            /// The format's own parser refused it. The message is the parser's.
            case syntax(String)
        }

        public var format: ConfigFormat
        public var reason: Reason

        public init(format: ConfigFormat, reason: Reason) {
            self.format = format
            self.reason = reason
        }

        public var description: String {
            let name = switch format {
            case .yaml: "YAML"
            case .json: "JSON"
            case .plist: "property list"
            }
            return switch reason {
            case .notText: "The \(name) is not UTF-8 text."
            case .empty: "The \(name) is empty."
            case .tabIndentation(let line): "Line \(line) is indented with a tab, which YAML does not allow."
            case .syntax(let message): "The \(name) could not be read: \(message)"
            }
        }
    }

    public static func decode(_ data: Data, as format: ConfigFormat) throws -> ConfigValue {
        switch format {
        case .yaml:
            guard let text = String(data: data, encoding: .utf8) else {
                throw Failure(format: .yaml, reason: .notText)
            }
            return try decodeYAML(text)
        case .json:
            return try decodeJSON(data)
        case .plist:
            return try decodePlist(data)
        }
    }

    // MARK: YAML

    public static func decodeYAML(_ text: String) throws -> ConfigValue {
        if let line = firstTabIndentedLine(in: text) {
            throw Failure(format: .yaml, reason: .tabIndentation(line: line))
        }
        let node: Node?
        do {
            node = try Yams.compose(yaml: text, .basic)
        } catch {
            throw Failure(format: .yaml, reason: .syntax(String(describing: error)))
        }
        guard let node else { throw Failure(format: .yaml, reason: .empty) }
        return try value(of: node)
    }

    /// libYAML reports a tab in indentation as "found character that cannot start any token", which
    /// is true and useless. A line whose leading whitespace holds a tab is found first, so that the
    /// message says what is wrong. Tabs *after* the indentation — inside a value, or before a comment
    /// — are ordinary characters and stay allowed. Block scalars (`|`, `>`) are skipped, because the
    /// lines inside them are content, not indentation.
    static func firstTabIndentedLine(in text: String) -> Int? {
        var blockIndent: Int?
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(leading.count)
            if let indent = blockIndent {
                // Still inside the block scalar while lines are blank or indented deeper than its key.
                if content.isEmpty || leading.count > indent { continue }
                blockIndent = nil
            }
            if leading.contains("\t"), !content.isEmpty, !content.hasPrefix("#") {
                return offset + 1
            }
            let trimmed = content.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let tail = trimmed.trimmingCharacters(in: .whitespaces)
            // A block scalar's indicator ends the line and follows the key's colon or a list dash.
            if tail.range(of: #"(^|[:\-]\s*)[|>][+-]?[0-9]?$"#, options: .regularExpression) != nil {
                blockIndent = leading.count
            }
        }
        return nil
    }

    private static func value(of node: Node) throws -> ConfigValue {
        switch node {
        case .scalar(let scalar):
            return scalar.style == .plain ? coreSchema(scalar.string) : .string(scalar.string)
        case .sequence(let sequence):
            return .array(try sequence.map(value(of:)))
        case .mapping(let mapping):
            return .dictionary(try mapping.map { key, value in
                // Keys are strings in every manifest. A non-scalar key is not a manifest.
                guard case .scalar(let scalar) = key else {
                    throw Failure(format: .yaml, reason: .syntax("A dictionary key is itself a list or dictionary."))
                }
                return ConfigValue.Entry(scalar.string, try self.value(of: value))
            })
        case .alias:
            // `compose` dereferences aliases; one surviving to here is a Yams change worth hearing about.
            throw Failure(format: .yaml, reason: .syntax("Unresolved alias."))
        }
    }

    /// The YAML 1.2 core schema's tag resolution for a plain scalar (YAML 1.2.2 §10.3.2).
    static func coreSchema(_ text: String) -> ConfigValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
        case ".nan", ".NaN", ".NAN": return .double(.nan)
        default: break
        }
        if text.wholeMatch(of: /[-+]?[0-9]+/) != nil, let value = Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) {
            return .int(value)
        }
        if text.wholeMatch(of: /0o[0-7]+/) != nil, let value = Int(text.dropFirst(2), radix: 8) {
            return .int(value)
        }
        if text.wholeMatch(of: /0x[0-9a-fA-F]+/) != nil, let value = Int(text.dropFirst(2), radix: 16) {
            return .int(value)
        }
        if text.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?/) != nil, let value = Double(text) {
            return .double(value)
        }
        return .string(text)
    }

    // MARK: JSON

    public static func decodeJSON(_ data: Data) throws -> ConfigValue {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            throw Failure(format: .json, reason: .empty)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw Failure(format: .json, reason: .syntax((error as NSError).localizedDescription))
        }
        return try value(ofFoundation: object, format: .json)
    }

    // MARK: Property list

    /// FMT-5: "In plist, `<false/>` stands for `null`." A property list has no null, so PopClip's
    /// format borrows `<false/>` for it — and a key that wants a boolean reads `null` as false, which
    /// is what the author wrote. `ManifestBuilder`'s boolean reader is where that half lives.
    public static func decodePlist(_ data: Data) throws -> ConfigValue {
        guard !data.isEmpty else { throw Failure(format: .plist, reason: .empty) }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw Failure(format: .plist, reason: .syntax((error as NSError).localizedDescription))
        }
        return try value(ofFoundation: object, format: .plist)
    }

    private static func value(ofFoundation object: Any, format: ConfigFormat) throws -> ConfigValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // JSON and plist both hand booleans back as NSNumber; only the CFBoolean type tells them
            // apart from 0 and 1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                let flag = number.boolValue
                return format == .plist && !flag ? .null : .bool(flag)
            }
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                // `1.0` in JSON is still the integer an author meant for `popclipVersion`.
                if double.rounded() == double, abs(double) < 1e15 { return .int(Int(double)) }
                return .double(double)
            }
            return .int(number.intValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map { try value(ofFoundation: $0, format: format) })
        case let dictionary as [String: Any]:
            // Foundation does not keep key order. Sorting makes the result deterministic, which is the
            // part of ordering a diagnostic needs; YAML, the format people write by hand, keeps it.
            return .dictionary(try dictionary.keys.sorted().map { key in
                ConfigValue.Entry(key, try value(ofFoundation: dictionary[key]!, format: format))
            })
        case let date as Date:
            return .string(ISO8601DateFormatter().string(from: date))
        case is Data:
            throw Failure(format: format, reason: .syntax("Binary data is not a manifest value."))
        default:
            throw Failure(format: format, reason: .syntax("Unexpected value of type \(type(of: object))."))
        }
    }
}
