import Foundation

/// EXM-2: what the bar offers when the selection is an extension.
///
/// Worked out on every appearance, inside the auto-appear budget, so it is bounded twice over. Text that
/// does not start like a snippet costs one look at its first lines. Text that does is read in full only
/// when it is within `SnippetDetector.maximumSelectionLength`, which is 5,000 characters of YAML at most.
///
/// An offer is not an install. It names what the text says it is, so that the button can say
/// **Install Extension "Name"**; everything a install decides — identity, collisions, capabilities,
/// consent — happens when it is pressed, through the same review as every other route (EXM-5).
public enum SnippetOffer: Sendable, Equatable {
    /// The text is an extension that loads, called this.
    case install(name: String)
    /// The text starts like an extension and is longer than PopClip's limit for a selection. PRD EXM-2:
    /// "over the limit the bar says so".
    case tooLong
    /// The text starts like an extension and does not load. The reason is the loader's, in its words.
    case unreadable(String)

    /// Nil for text that is not a snippet, which is almost every selection.
    public static func evaluate(_ text: String, locale: Locale = .current) -> SnippetOffer? {
        let limit = SnippetDetector.maximumSelectionLength
        // A selection can be a whole book. The marker is in the header, which is at the start, so the
        // detector is shown no more than the limit and one character past it.
        let head = String(text.prefix(limit + 1))
        guard SnippetDetector.detect(head) != nil else { return nil }
        guard head.count <= limit else { return .tooLong }
        do {
            return .install(name: try ExtensionLoader.loadSnippet(text).manifest.name.text(for: locale))
        } catch {
            return .unreadable(error.description)
        }
    }
}
