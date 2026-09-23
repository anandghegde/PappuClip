import Foundation

/// §8.7: what a script is told about the selection it was run on.
///
/// One table, read two ways. A shell script gets each value as an environment variable, under both
/// `POPCLIP_` and `PAPPUCLIP_`. An AppleScript gets it as a `{popclip …}` placeholder written into its
/// source, or as a parameter of the handler it calls. The names are the same in both: `FULL_TEXT` is
/// `POPCLIP_FULL_TEXT` and `{popclip full text}`.
///
/// **Every value is a string, and a missing value is an empty one** (§8.7). A script that tests
/// `[ -n "$POPCLIP_BROWSER_URL" ]` sees an empty variable, not an unset one, in Mail as in Safari.
///
/// Pure, so that `pappu-dev` and the registry's CI can show an author exactly what their script
/// would be given.
public struct ScriptVariables: Sendable, Equatable {
    /// What the table is made from. Everything the runner knows at the moment the action runs.
    public struct Inputs: Sendable, Equatable {
        /// The text the action acts on: narrowed by `url`, `email` or `path`, then by `regex` (§8.5).
        public var text: String
        /// The whole selection, whatever the narrowing did (§8.5 step 5).
        public var fullText: String
        public var html: String
        public var rawHTML: String
        public var markdown: String
        public var urls: [String]
        public var emails: [String]
        public var paths: [String]
        public var modifiers: ModifierFlags
        public var bundleIdentifier: String
        public var appName: String
        public var browserTitle: String
        public var browserURL: String
        public var extensionIdentifier: String
        public var actionIdentifier: String
        /// Option values by option identifier, as the author spelled it. Booleans are `1` and `0`.
        public var options: [String: String]

        public init(
            text: String,
            fullText: String? = nil,
            html: String = "",
            rawHTML: String = "",
            markdown: String = "",
            urls: [String] = [],
            emails: [String] = [],
            paths: [String] = [],
            modifiers: ModifierFlags = [],
            bundleIdentifier: String = "",
            appName: String = "",
            browserTitle: String = "",
            browserURL: String = "",
            extensionIdentifier: String = "",
            actionIdentifier: String = "",
            options: [String: String] = [:]
        ) {
            self.text = text
            self.fullText = fullText ?? text
            self.html = html
            self.rawHTML = rawHTML
            self.markdown = markdown
            self.urls = urls
            self.emails = emails
            self.paths = paths
            self.modifiers = modifiers
            self.bundleIdentifier = bundleIdentifier
            self.appName = appName
            self.browserTitle = browserTitle
            self.browserURL = browserURL
            self.extensionIdentifier = extensionIdentifier
            self.actionIdentifier = actionIdentifier
            self.options = options
        }
    }

    /// §8.7's modifier values: the `NSEvent.ModifierFlags` bits PopClip has always passed, summed.
    public struct ModifierFlags: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = ModifierFlags(rawValue: 131_072)
        public static let control = ModifierFlags(rawValue: 262_144)
        public static let option = ModifierFlags(rawValue: 524_288)
        public static let command = ModifierFlags(rawValue: 1_048_576)
    }

    /// The prefixes a shell script sees each name under. PopClip's first, so that a listing of the
    /// environment reads the way the extension's author expects.
    public static let environmentPrefixes = ["POPCLIP_", "PAPPUCLIP_"]

    /// Values by name, without a prefix: `TEXT`, `FULL_TEXT`, `OPTION_APIKEY`.
    public let values: [String: String]
    private let options: [String: String]

    public init(_ inputs: Inputs) {
        var values: [String: String] = [
            "TEXT": inputs.text,
            "FULL_TEXT": inputs.fullText,
            "URLENCODED_TEXT": inputs.text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "",
            "HTML": inputs.html,
            "RAW_HTML": inputs.rawHTML,
            "MARKDOWN": inputs.markdown,
            "URLS": inputs.urls.joined(separator: "\n"),
            // Older extensions (§8.7, unverified for the current PopClip build). Setting them costs
            // nothing and an extension that reads them gets the answer it was written for.
            "EMAILS": inputs.emails.joined(separator: "\n"),
            "PATHS": inputs.paths.joined(separator: "\n"),
            "MODIFIER_FLAGS": String(inputs.modifiers.rawValue),
            "BUNDLE_IDENTIFIER": inputs.bundleIdentifier,
            "APP_NAME": inputs.appName,
            "BROWSER_TITLE": inputs.browserTitle,
            "BROWSER_URL": inputs.browserURL,
            "EXTENSION_IDENTIFIER": inputs.extensionIdentifier,
            "ACTION_IDENTIFIER": inputs.actionIdentifier,
        ]
        for (identifier, value) in inputs.options {
            values["OPTION_" + Self.variableName(identifier)] = value
        }
        self.values = values
        options = inputs.options
    }

    // MARK: Shell

    /// Every value under both prefixes.
    public var environment: [String: String] {
        var environment: [String: String] = [:]
        for (name, value) in values {
            for prefix in Self.environmentPrefixes { environment[prefix + name] = value }
        }
        return environment
    }

    /// The value a `stdin` key names. §8.4 lets it name any variable; the corpus only ever says
    /// `text`. Nil for a name that is not one: the runner then gives the script no input at all,
    /// rather than guessing.
    public func value(named name: String) -> String? {
        var key = Self.variableName(name)
        for prefix in Self.environmentPrefixes where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
        }
        return values[key]
    }

    // MARK: AppleScript

    /// The value of one placeholder, written the way a script or an `appleScriptCall` parameter
    /// writes it: `popclip text`, `pappuclip full text`, `popclip option apikey`. Nil when the name is
    /// not one of §8.7's.
    ///
    /// Options are looked up by the identifier as written, so `{popclip option apiKey}` finds the
    /// option `apiKey`; the environment's upper case is only how a shell spells it.
    public func value(forPlaceholder placeholder: String) -> String? {
        let words = placeholder.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, ["popclip", "pappuclip"].contains(first.lowercased()) else { return nil }
        let rest = words.dropFirst()
        if rest.first?.lowercased() == "option", rest.count >= 2 {
            let identifier = rest.dropFirst().joined(separator: " ")
            return options[identifier]
                ?? options.first { $0.key.caseInsensitiveCompare(identifier) == .orderedSame }?.value
                ?? ""
        }
        return values[rest.map { $0.uppercased() }.joined(separator: "_")]
    }

    /// A plain-text AppleScript with its placeholders filled in (§8.4).
    ///
    /// Each value goes in **escaped for an AppleScript string literal**, because that is where scripts
    /// put them — `set theText to "{popclip text}"` — and a selection with a quote in it would
    /// otherwise end the string and run the rest as code. A placeholder this table does not know is
    /// left exactly as written: braces are ordinary AppleScript (records, `{1, 2}`), and only the
    /// names §8.7 defines are ours to replace.
    public func substitutingPlaceholders(in source: String) -> String {
        var result = ""
        var rest = Substring(source)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let name = String(rest[rest.index(after: open)..<close])
            if let value = value(forPlaceholder: name) {
                result += Self.appleScriptEscaped(value)
                rest = rest[rest.index(after: close)...]
            } else {
                // Only the brace is passed over, so a placeholder inside a record is still found.
                result += "{"
                rest = rest[rest.index(after: open)...]
            }
        }
        return result + rest
    }

    /// The characters an AppleScript string literal gives a meaning to, made literal.
    public static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Names

    /// A name as an environment variable spells it: upper case, and anything that is not a letter,
    /// a digit or an underscore made an underscore, so that an option called `api-key` is
    /// `POPCLIP_OPTION_API_KEY` and not a variable no shell can read.
    public static func variableName(_ name: String) -> String {
        String(name.uppercased().unicodeScalars.map { scalar in
            (CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) || scalar == "_" ? Character(scalar) : "_"
        })
    }

    /// RFC 3986's unreserved characters: what `URLENCODED_TEXT` leaves as it is.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
