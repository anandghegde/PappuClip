import Foundation

/// HTML reduced to formatting, for anything the app turns into an attributed string (JS-7).
///
/// **Why it exists.** AppKit reads HTML with WebKit, and WebKit fetches what a page refers to: an image,
/// a stylesheet, a font. A script's `RichString` handed to it unchanged would be a network request made
/// by the app on the script's behalf, outside the `network` entitlement and `networkHosts` (JS-8,
/// SEC-6). So what AppKit is given has been through this first, and this keeps nothing that can refer
/// to anything: an allowlist of formatting tags with no attributes, except a link's address.
///
/// It is a tokenizer, not a parser: tags it does not keep are dropped and their text is kept, except for
/// the elements whose content is not text (scripts, styles, embedded documents), which go with it.
/// Malformed markup comes out as text, escaped.
public enum SafeHTML {
    /// Formatting, and nothing that loads, runs or submits.
    public static let keptTags: Set<String> = [
        "a", "abbr", "b", "big", "blockquote", "br", "caption", "cite", "code", "dd", "del", "div", "dl",
        "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "ins", "kbd", "li", "mark", "ol", "p",
        "pre", "q", "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "table", "tbody", "td",
        "tfoot", "th", "thead", "tr", "u", "ul",
    ]

    /// Elements whose content goes with them.
    public static let droppedWithContent: Set<String> = [
        "script", "style", "template", "iframe", "frame", "frameset", "object", "embed", "noscript",
        "svg", "math", "head", "title", "textarea", "select", "audio", "video", "canvas",
    ]

    static let voidTags: Set<String> = ["br", "hr"]

    /// A link keeps its address only for these.
    static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    public static func clean(_ html: String) -> String {
        let characters = Array(html.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        func append(_ text: String) { output.append(contentsOf: text.unicodeScalars) }

        while index < characters.count {
            let character = characters[index]
            guard character == "<" else {
                output.append(character)
                index += 1
                continue
            }
            // A comment, or a declaration such as a doctype: gone.
            if starts(characters, at: index, with: "<!--") {
                index = find(characters, "-->", from: index + 4).map { $0 + 3 } ?? characters.count
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "!" || characters[index + 1] == "?" {
                index = find(characters, ">", from: index + 2).map { $0 + 1 } ?? characters.count
                continue
            }
            guard let tag = readTag(characters, at: index) else {
                append("&lt;")
                index += 1
                continue
            }
            index = tag.end
            if !tag.closing, droppedWithContent.contains(tag.name) {
                index = skipContent(of: tag.name, in: characters, from: index)
                continue
            }
            guard keptTags.contains(tag.name) else { continue }
            if tag.closing {
                if !voidTags.contains(tag.name) { append("</\(tag.name)>") }
            } else if tag.name == "a", let href = tag.attributes["href"], let link = safeLink(href) {
                append("<a href=\"\(escaped(link))\">")
            } else {
                append("<\(tag.name)>")
            }
        }
        return String(output)
    }

    /// `&`, `<`, `>` and `"` as entities: text made safe to put inside HTML.
    public static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func safeLink(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), linkSchemes.contains(scheme) else { return nil }
        return trimmed
    }

    struct Tag {
        var name: String
        var closing: Bool
        var attributes: [String: String]
        var end: Int
    }

    /// The tag starting at `start`, which is a `<`, or nil when what follows is not one.
    static func readTag(_ characters: [Unicode.Scalar], at start: Int) -> Tag? {
        var index = start + 1
        var closing = false
        if index < characters.count, characters[index] == "/" {
            closing = true
            index += 1
        }
        let nameStart = index
        while index < characters.count, isNameCharacter(characters[index], first: index == nameStart) { index += 1 }
        guard index > nameStart else { return nil }
        let name = String(String.UnicodeScalarView(characters[nameStart..<index])).lowercased()
        var attributes: [String: String] = [:]
        while index < characters.count {
            let character = characters[index]
            if character == ">" {
                return Tag(name: name, closing: closing, attributes: attributes, end: index + 1)
            }
            if character == " " || character == "\t" || character == "\n" || character == "\r" || character == "/" {
                index += 1
                continue
            }
            let attributeStart = index
            while index < characters.count, !" \t\n\r/>=".unicodeScalars.contains(characters[index]) { index += 1 }
            let attribute = String(String.UnicodeScalarView(characters[attributeStart..<index])).lowercased()
            var value = ""
            while index < characters.count, characters[index] == " " { index += 1 }
            if index < characters.count, characters[index] == "=" {
                index += 1
                while index < characters.count, characters[index] == " " { index += 1 }
                if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                    let quote = characters[index]
                    let valueStart = index + 1
                    guard let close = find(characters, String(quote), from: valueStart) else { return nil }
                    value = String(String.UnicodeScalarView(characters[valueStart..<close]))
                    index = close + 1
                } else {
                    let valueStart = index
                    while index < characters.count, !" \t\n\r>".unicodeScalars.contains(characters[index]) { index += 1 }
                    value = String(String.UnicodeScalarView(characters[valueStart..<index]))
                }
            }
            if !attribute.isEmpty, attributes[attribute] == nil { attributes[attribute] = decodedEntities(value) }
        }
        return nil
    }

    private static func isNameCharacter(_ character: Unicode.Scalar, first: Bool) -> Bool {
        if ("a"..."z").contains(character) || ("A"..."Z").contains(character) { return true }
        return !first && (("0"..."9").contains(character) || character == "-")
    }

    /// Past the end of the element `name` opened: its closing tag, or the end of the text.
    private static func skipContent(of name: String, in characters: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while let open = find(characters, "</", from: index) {
            if let tag = readTag(characters, at: open), tag.closing, tag.name == name { return tag.end }
            index = open + 2
        }
        return characters.count
    }

    private static func starts(_ characters: [Unicode.Scalar], at index: Int, with prefix: String) -> Bool {
        let scalars = Array(prefix.unicodeScalars)
        guard index + scalars.count <= characters.count else { return false }
        for (offset, scalar) in scalars.enumerated() where characters[index + offset] != scalar { return false }
        return true
    }

    private static func find(_ characters: [Unicode.Scalar], _ needle: String, from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            if starts(characters, at: index, with: needle) { return index }
            index += 1
        }
        return nil
    }

    /// The few entities an address is likely to hold, so `&amp;` in a link is `&` again before it is
    /// checked and escaped once more.
    private static func decodedEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Markdown as HTML, for `RichString(…, { format: "markdown" })` (JS-7).
///
/// The common constructs and no more: ATX headings, paragraphs, block quotes, fenced and indented code,
/// bulleted and numbered lists, rules, and inline emphasis, strong, code, strikethrough and links. Text
/// is escaped before any markup is added, links keep only `SafeHTML`'s schemes, and an image is its alt
/// text, so what comes out is safe to give AppKit by construction.
public enum MarkdownHTML {
    public static func render(_ markdown: String) -> String {
        var html: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>" + paragraph.map(inline).joined(separator: "\n") + "</p>")
            paragraph = []
        }
        func flushList() {
            guard let open = list else { return }
            let tag = open.ordered ? "ol" : "ul"
            html.append("<\(tag)>" + open.items.map { "<li>" + inline($0) + "</li>" }.joined() + "</\(tag)>")
            list = nil
        }
        func flush() {
            flushParagraph()
            flushList()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                html.append("<pre><code>" + SafeHTML.escaped(code.joined(separator: "\n")) + "</code></pre>")
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                html.append("<h\(heading.level)>" + inline(heading.text) + "</h\(heading.level)>")
                index += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                html.append("<hr>")
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var body = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    quoted.append(String(body))
                    index += 1
                }
                html.append("<blockquote>" + render(quoted.joined(separator: "\n")) + "</blockquote>")
                continue
            }
            if let item = listItem(trimmed) {
                flushParagraph()
                if let open = list, open.ordered != item.ordered { flushList() }
                if list == nil { list = (item.ordered, []) }
                list?.items.append(item.text)
                index += 1
                continue
            }
            if line.hasPrefix("    "), paragraph.isEmpty, list == nil {
                var code: [String] = []
                while index < lines.count, lines[index].hasPrefix("    ") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[index].dropFirst(min(4, lines[index].count))))
                    index += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                html.append("<pre><code>" + SafeHTML.escaped(code.joined(separator: "\n")) + "</code></pre>")
                continue
            }
            if var open = list, line.first == " " || line.first == "\t" {
                // A continuation line of the last item.
                open.items[open.items.count - 1] += " " + trimmed
                list = open
                index += 1
                continue
            }
            flushList()
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return html.joined(separator: "\n")
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " else { return nil }
        return (true, String(rest.dropFirst(2)))
    }

    /// Inline markup over escaped text: code spans first, so nothing inside one is read as markup.
    static func inline(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "`") else { break }
            result += spans(String(rest[..<open]))
            result += "<code>" + SafeHTML.escaped(String(rest[afterOpen..<close])) + "</code>"
            rest = rest[rest.index(after: close)...]
        }
        return result + spans(String(rest))
    }

    private static func spans(_ text: String) -> String {
        var links: [String] = []
        var html = SafeHTML.escaped(text)
        // Images first, as their alt text, so the link rule does not take them. Links are set aside while
        // emphasis is read, so an underscore in an address is not taken for markup.
        html = replace(#"!\[([^\]]*)\]\(([^)\s]*)[^)]*\)"#, in: html) { groups in groups[1] }
        html = replace(#"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, in: html) { groups in
            let label = emphasis(groups[1])
            let href = groups[2].replacingOccurrences(of: "&amp;", with: "&")
            links.append(SafeHTML.safeLink(href).map { "<a href=\"\(SafeHTML.escaped($0))\">\(label)</a>" } ?? label)
            return "\u{E000}\(links.count - 1)\u{E001}"
        }
        html = emphasis(html)
        return replace("\u{E000}([0-9]+)\u{E001}", in: html) { groups in
            Int(groups[1]).flatMap { links.indices.contains($0) ? links[$0] : nil } ?? groups[0]
        }
    }

    private static func emphasis(_ text: String) -> String {
        var html = replace(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: text) { "<strong>\($0[2])</strong>" }
        html = replace(#"(\*|_)(?=\S)(.+?)(?<=\S)\1"#, in: html) { "<em>\($0[2])</em>" }
        return replace(#"~~(?=\S)(.+?)(?<=\S)~~"#, in: html) { "<del>\($0[1])</del>" }
    }

    private static func replace(_ pattern: String, in text: String, with make: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
            result += make(groups)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }
}
