import Foundation

/// The selection with how it looks, for an action that asked for HTML or RTF (FLT-4).
///
/// **Runs, not a document.** What an app gives through Accessibility is text with attributes, and what
/// survives from those into every form an extension reads is bold, italic, underline, strikethrough
/// and size. So that is what this keeps, and the three forms are written from it here:
/// - **HTML** of paragraphs and those five, escaped as it is written, so it refers to nothing and
///   runs nothing. It is already what `SafeHTML` would keep, which makes it the sanitised form as
///   well as the raw one.
/// - **RTF** that TextEdit, Pages and Word read.
/// - **Markdown** of the same paragraphs and emphasis: what turndown would make of the HTML.
///
/// No AppKit, no WebKit: the forms are written by hand, so every one of them is tested here, and no
/// part of the selection is handed to an HTML reader to be interpreted.
///
/// **The fallback** (FLT-4's chain) is `init(plain:)`: an app that gives no attributes still gives
/// text, and plain text is a styled text with no style.
public struct StyledText: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strikethrough: Bool
        /// In points. Nil for the reader's own default.
        public var size: Double?

        public init(
            text: String,
            bold: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            strikethrough: Bool = false,
            size: Double? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
            self.size = size
        }

        /// A run as Accessibility describes one: its font by PostScript name, from which bold and
        /// italic are read the way a font menu shows them (`Helvetica-BoldOblique`).
        public init(text: String, fontName: String?, size: Double?, underline: Bool, strikethrough: Bool) {
            let traits = Self.traits(ofFont: fontName)
            self.init(text: text, bold: traits.bold, italic: traits.italic, underline: underline, strikethrough: strikethrough, size: size)
        }

        static func traits(ofFont name: String?) -> (bold: Bool, italic: Bool) {
            guard let name = name?.lowercased() else { return (false, false) }
            let bold = ["bold", "black", "heavy", "semibold", "demibold"].contains { name.contains($0) }
            let italic = ["italic", "oblique"].contains { name.contains($0) }
            return (bold, italic)
        }

        func looksLike(_ other: Run) -> Bool {
            bold == other.bold && italic == other.italic && underline == other.underline
                && strikethrough == other.strikethrough && size == other.size
        }
    }

    public var runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs
    }

    /// FLT-4's last fallback: the plain text, with no style.
    public init(plain text: String) {
        self.init(runs: [Run(text: text)])
    }

    /// The text alone, which is what the selection was.
    public var string: String { runs.map(\.text).joined() }

    // MARK: The forms

    /// Paragraphs of `<p>`, each run in `<b>`, `<i>`, `<u>` and `<s>` as it needs.
    public var html: String {
        paragraphs.map { paragraph in "<p>" + paragraph.map(Self.html(of:)).joined() + "</p>" }.joined()
    }

    /// Paragraphs a blank line apart, bold as `**`, italic as `*`, strikethrough as `~~`. Underline has
    /// no Markdown and is left as text.
    public var markdown: String {
        paragraphs.map { $0.map(Self.markdown(of:)).joined() }.joined(separator: "\n\n")
    }

    /// RTF with one font, each run a group of its own.
    public var rtf: String {
        var body = ""
        for run in merged {
            var controls = ""
            if run.bold { controls += "\\b" }
            if run.italic { controls += "\\i" }
            if run.underline { controls += "\\ul" }
            if run.strikethrough { controls += "\\strike" }
            if let size = run.size, size > 0 { controls += "\\fs\(Int((size * 2).rounded()))" }
            body += "{" + controls + (controls.isEmpty ? "" : " ") + Self.rtfEscaped(run.text) + "}"
        }
        return "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}}\\f0\\fs24 " + body + "}"
    }

    // MARK: Writing

    /// Adjacent runs that look the same, as one.
    var merged: [Run] {
        var result: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.looksLike(run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// The runs, split at line breaks: a line is a paragraph, as it is in a Mac text view. A break at the
    /// very end ends the last paragraph rather than starting an empty one.
    var paragraphs: [[Run]] {
        var result: [[Run]] = [[]]
        for run in merged {
            let text = run.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
            for (index, piece) in text.components(separatedBy: "\n").enumerated() {
                if index > 0 { result.append([]) }
                if !piece.isEmpty {
                    var part = run
                    part.text = piece
                    result[result.count - 1].append(part)
                }
            }
        }
        if result.count > 1, result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    static func html(of run: Run) -> String {
        var text = SafeHTML.escaped(run.text)
        if run.strikethrough { text = "<s>\(text)</s>" }
        if run.underline { text = "<u>\(text)</u>" }
        if run.italic { text = "<i>\(text)</i>" }
        if run.bold { text = "<b>\(text)</b>" }
        return text
    }

    /// Emphasis goes inside the run's own spaces, because `** bold**` is not bold in any Markdown.
    static func markdown(of run: Run) -> String {
        let text = markdownEscaped(run.text)
        let leading = String(text.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        guard leading.count < text.count else { return text }
        var core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        if run.strikethrough { core = "~~\(core)~~" }
        switch (run.bold, run.italic) {
        case (true, true): core = "***\(core)***"
        case (true, false): core = "**\(core)**"
        case (false, true): core = "*\(core)*"
        case (false, false): break
        }
        return leading + core + trailing
    }

    static func markdownEscaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_`[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Backslashes and braces escaped, a line break a paragraph, and anything outside ASCII as `\uN?`
    /// with the UTF-16 unit as a signed number, which is how RTF spells Unicode.
    static func rtfEscaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "\n", "\u{2029}", "\u{2028}": result += "\\par\n"
            case "\r": continue
            case "\t": result += "\\tab "
            case " "..."~": result.unicodeScalars.append(scalar)
            default:
                for unit in String(scalar).utf16 { result += "\\u\(Int16(bitPattern: unit))?" }
            }
        }
        return result
    }
}
