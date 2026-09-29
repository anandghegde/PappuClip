import Foundation

/// The result panel's Markdown, read safely (JS-17, architecture §7's rich result row).
///
/// Nothing in it can reach out: links lose their destination and images their source, so nothing is
/// fetched and nothing opens on a click; raw HTML stays as the text it is; scripts cannot exist. This is
/// M3's functional reading — inline emphasis, code and whitespace kept as written. The polished renderer,
/// with block structure, TextKit 2 and links that open only on an explicit click, is M4's (DIF-3).
public enum SafeMarkdown {
    /// What the text says, with emphasis and code marked and every way out removed.
    public static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var rendered = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        for run in rendered.runs {
            if run.link != nil { rendered[run.range].link = nil }
            if run.imageURL != nil { rendered[run.range].imageURL = nil }
        }
        return rendered
    }

    /// Whether anything in the rendered text could open, load or fetch something. Always false for
    /// what `render` returns; the test's question and the panel's precondition.
    public static func reachesOut(_ rendered: AttributedString) -> Bool {
        rendered.runs.contains { $0.link != nil || $0.imageURL != nil }
    }
}
