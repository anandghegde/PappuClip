import Foundation

/// FMT-5: every spelling of a key, folded to one (architecture §9.1, "Normalise keys").
///
/// PopClip's format has been written by hand for over a decade in three file formats, and the corpus
/// shows it: `Extension Name`, `name`; `Image File`, `icon`; `Regular Expression`, `regex`;
/// `shellScriptFile`, `shell script file`, `Shell Script File`. They are one key. The rule is the
/// PRD's, in its order:
///
/// 1. Split into words at spaces, `_`, `-` and lower-to-upper case changes (`keyName`, `KEY_NAME`,
///    `key-name` → `key`, `name`). A run of capitals is one word (`passHTML` → `pass`, `html`).
/// 2. Lowercase them and join with single spaces.
/// 3. Strip a leading `extension` or `option` — `Extension Identifier` is `identifier` at the top level
///    and `Option Identifier` is `identifier` in an option.
/// 4. Apply the legacy map (extension spec Appendix A).
///
/// The canonical spelling is the space-separated one (`shell script file`), because it is the one the
/// legacy map is written in and the one a person reads most easily in a diagnostic.
public enum KeyNormalizer {
    /// Appendix A. Applied after the word rules, to the canonical spelling.
    public static let legacyMap: [String: String] = [
        "apple script": "applescript",
        "apple script file": "applescript file",
        "apple script call": "applescript call",
        "java script": "javascript",
        "java script file": "javascript file",
        "js": "javascript",
        "blocked apps": "excluded apps",
        "flip horizontal": "flip x",
        "flip vertical": "flip y",
        "id": "identifier",
        "image file": "icon",
        "lang": "language",
        "mac os version": "macos version",
        "required os version": "macos version",
        "pop clip version": "popclip version",
        "required software version": "popclip version",
        "params": "parameters",
        "pass html": "capture html",
        "preserve image color": "preserve color",
        "regular expression": "regex",
        "script interpreter": "interpreter",
    ]

    /// Words that step 3 strips when they lead a key with more words after them.
    static let strippedPrefixes: Set<String> = ["extension", "option"]

    public static func normalize(_ key: String) -> String {
        var words = words(of: key)
        if words.count > 1, strippedPrefixes.contains(words[0]) {
            words.removeFirst()
        }
        let joined = words.joined(separator: " ")
        return legacyMap[joined] ?? joined
    }

    /// Steps 1 and 2.
    static func words(of key: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(key)

        func flush() {
            if !current.isEmpty { words.append(current.lowercased()) }
            current = ""
        }

        for (index, character) in characters.enumerated() {
            if character == " " || character == "_" || character == "-" || character == "\t" {
                flush()
                continue
            }
            if character.isUppercase, let previous = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // `keyName`: a capital after a lowercase letter or digit starts a word.
                // `passHTMLFile`: inside a run of capitals, the last one starts a word when a lowercase
                // letter follows it (`HTML` then `File`).
                if previous.isLowercase || previous.isNumber
                    || (previous.isUppercase && next?.isLowercase == true)
                {
                    flush()
                }
            }
            current.append(character)
        }
        flush()
        return words
    }
}

/// A config dictionary read through `KeyNormalizer`: look a key up by its canonical spelling, and
/// learn afterwards which keys nobody asked about.
///
/// This is a view, not a rewrite. The raw keys stay as they were, so that a value which is itself a
/// dictionary of non-keys — a localizable string, keyed by language code — is read with its keys
/// intact, and so that a diagnostic can name the key as the author spelled it.
public struct NormalizedDictionary: Sendable {
    public struct Found: Sendable, Equatable {
        /// As the author wrote it.
        public var rawKey: String
        public var value: ConfigValue
    }

    private var entries: [String: Found] = [:]
    private var order: [String] = []
    /// Canonical keys written more than once under different spellings, with every spelling after the
    /// first. The first wins; the builder reports the rest.
    public private(set) var duplicates: [(canonical: String, rawKey: String)] = []

    public init(_ entries: [ConfigValue.Entry]) {
        for entry in entries {
            let canonical = KeyNormalizer.normalize(entry.key)
            if self.entries[canonical] != nil {
                duplicates.append((canonical, entry.key))
                continue
            }
            self.entries[canonical] = Found(rawKey: entry.key, value: entry.value)
            order.append(canonical)
        }
    }

    public subscript(canonical: String) -> Found? {
        entries[canonical]
    }

    public func contains(_ canonical: String) -> Bool {
        entries[canonical] != nil
    }

    /// Canonical keys in the order the author wrote them.
    public var keys: [String] { order }
}
