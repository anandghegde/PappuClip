import Foundation

/// A code config's script (FMT-2): the whole text, and how its header was written.
public struct CodeBody: Sendable, Equatable {
    /// The comment style of the header, which is what says what language the text is.
    public enum Style: String, Sendable, Equatable {
        /// `//`: TypeScript unless `language: javascript` or the file is `.js`.
        case slashes
        /// `--`: AppleScript.
        case dashes
        /// `#`: shell, run by `interpreter` or the `#!` line.
        case hash
    }

    public var text: String
    public var style: Style
    /// The `#!` line's command, without the `#!`, when the text starts with one.
    public var shebang: String?
    /// What the file name says, for a package's `Config.js` or `Config.ts`. Nil for a snippet.
    public var impliedLanguage: ScriptLanguage?

    public init(text: String, style: Style, shebang: String? = nil, impliedLanguage: ScriptLanguage? = nil) {
        self.text = text
        self.style = style
        self.shebang = shebang
        self.impliedLanguage = impliedLanguage
    }

    /// FMT-2: "A JavaScript body that exports or calls `defineExtension()` loads as a module." CommonJS
    /// exports and AMD's `define({...})` count, because the corpus has both.
    public var looksLikeModule: Bool {
        text.range(of: #"(^|\n)\s*export\s"#, options: .regularExpression) != nil
            || text.range(of: #"\bdefineExtension\s*\("#, options: .regularExpression) != nil
            || text.range(of: #"\bmodule\.exports\b"#, options: .regularExpression) != nil
            || text.range(of: #"(^|\n)\s*exports\.\w+\s*="#, options: .regularExpression) != nil
            || text.range(of: #"(^|\n)\s*define\s*\("#, options: .regularExpression) != nil
    }
}

/// FMT-1 and FMT-2: is this text an extension, and if so, where is its config?
///
/// Two shapes. A **config snippet** starts with the marker on its first line and is YAML after it. A
/// **code snippet** is a script whose config is a run of comment lines beginning at the marker — the
/// whole text is also the script. The marker is `#popclip` or `#pappuclip`, with or without a space
/// after the `#`, case-insensitive, and anything may follow it on the same line.
public enum SnippetDetector {
    /// PopClip's limit for installing from a selection (§7.4's Install Extension action). Longer text is
    /// not offered as a snippet; a file has no limit.
    public static let maximumSelectionLength = 5_000

    public enum Detected: Sendable, Equatable {
        /// FMT-1: YAML (or JSON, which YAML 1.2 includes) after the marker line.
        case config(yaml: String)
        /// FMT-2: the header's YAML, and the text it configures.
        case code(yaml: String, body: CodeBody)
    }

    static let markers = ["popclip", "pappuclip"]

    /// Whether `text` is a snippet and, if so, which kind. Nil means it is not one, which for a
    /// selection is the ordinary case and for a `.popcliptxt` file is an error the caller reports.
    public static func detect(_ text: String, impliedLanguage: ScriptLanguage? = nil) -> Detected? {
        // `\r\n` is one Character in Swift, so splitting on "\n" would leave a CRLF file as one line.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A byte-order mark is invisible in an editor and would hide the marker.
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = first.dropFirst() }
        guard let first = lines.first else { return nil }

        if isMarker(first) {
            return .config(yaml: lines.dropFirst().joined(separator: "\n"))
        }

        // A code snippet: a leading `#!`, blank lines and other comments may come before the marker,
        // and nothing else — a marker below the first line of code is text that mentions one.
        var shebang: String?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed.hasPrefix("#!") {
                shebang = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty { continue }
            guard let (style, prefix) = commentStyle(of: trimmed) else { return nil }
            guard isMarker(trimmed.dropFirst(prefix.count)) else { continue }
            let header = lines[(index + 1)...].prefix { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
            }.map { line in
                var content = line.drop { $0 == " " || $0 == "\t" }.dropFirst(prefix.count)
                if content.first == " " { content = content.dropFirst() }
                return String(content)
            }
            let body = CodeBody(text: text, style: style, shebang: shebang, impliedLanguage: impliedLanguage)
            return .code(yaml: header.joined(separator: "\n"), body: body)
        }
        return nil
    }

    /// For text from a selection: `detect`, within the length limit.
    public static func detect(selection text: String) -> Detected? {
        guard text.count <= maximumSelectionLength else { return nil }
        return detect(text)
    }

    /// `#popclip`, `# popclip`, `#pappuclip`, `# pappuclip`, followed by the end of the line or by
    /// something that is not part of the word.
    static func isMarker<S: StringProtocol>(_ line: S) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard rest.first == "#" else { return false }
        rest = rest.dropFirst().drop { $0 == " " }
        for marker in markers {
            guard rest.lowercased().hasPrefix(marker) else { continue }
            let after = rest.dropFirst(marker.count).first
            if after == nil || !(after!.isLetter || after!.isNumber) { return true }
        }
        return false
    }

    private static func commentStyle(of line: String) -> (CodeBody.Style, String)? {
        if line.hasPrefix("//") { return (.slashes, "//") }
        if line.hasPrefix("--") { return (.dashes, "--") }
        if line.hasPrefix("#") { return (.hash, "#") }
        return nil
    }
}
