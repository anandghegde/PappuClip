import Foundation

/// §8.4 URL: an action's template, expanded for one selection.
///
/// Three placeholders. `{popclip text}` (or `{pappuclip text}`) and `***` are the selection — trimmed,
/// cleaned when `cleanQuery` asks, quoted when ⌥ is held, and percent-encoded as data inside a URL.
/// `{popclip option <id>}` is an option's value, inserted **as written**: the corpus uses options for
/// hosts and paths (`https://{popclip option site}/search?q=…`), which encoding would break. An
/// option that is not set is empty, as §8.7 says of every missing value.
public enum URLTemplate {
    /// The URL to open, or nil when the expansion does not make one — an option value with a space
    /// in it, say. A template with no text placeholder is a fixed URL and is opened as it stands.
    public static func expand(
        _ action: URLAction,
        text: String,
        quoted: Bool,
        options: [String: String] = [:]
    ) -> URL? {
        let term = encoded(text, action: action, quoted: quoted)
        var expanded = action.template
            .replacingOccurrences(of: "{popclip text}", with: term, options: .caseInsensitive)
            .replacingOccurrences(of: "{pappuclip text}", with: term, options: .caseInsensitive)
            .replacingOccurrences(of: "***", with: term)
        expanded = expandingOptions(in: expanded, options: options)
        return URL(string: expanded)
    }

    /// The selection as it goes into the URL.
    ///
    /// Order matters and is PopClip's: trim, clean, quote, then encode — the quotes are part of the
    /// query, so they are encoded with it (`%22`). `spacesAsPlus` is applied to the encoded text,
    /// where a space is `%20` and nothing else is, so a literal `+` in the selection stays `%2B`.
    public static func encoded(_ text: String, action: URLAction, quoted: Bool) -> String {
        var term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if action.cleanQuery { term = cleaned(term) }
        if quoted { term = "\"\(term)\"" }
        var encoded = term.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        if action.spacesAsPlus { encoded = encoded.replacingOccurrences(of: "%20", with: "+") }
        return encoded
    }

    /// `cleanQuery`: line breaks and tabs become spaces and runs of spaces become one, so a
    /// multi-line selection makes a one-line search.
    public static func cleaned(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func expandingOptions(in template: String, options: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = [
            rest.range(of: "{popclip option ", options: .caseInsensitive),
            rest.range(of: "{pappuclip option ", options: .caseInsensitive),
        ].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { break }
            result += rest[..<open.lowerBound]
            let identifier = rest[open.upperBound..<close].trimmingCharacters(in: .whitespaces)
            result += options[identifier] ?? ""
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// RFC 3986's unreserved set, in ASCII: the text is data inside a query, so `&`, `=`, `+` and
    /// `#` in a selection must not become syntax, and a letter outside ASCII is encoded as UTF-8
    /// rather than left for `URL` to decide about.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
