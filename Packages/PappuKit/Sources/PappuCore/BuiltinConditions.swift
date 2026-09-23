import Foundation

/// The two facts that decide a built-in's visibility and that `requirements` cannot express.
///
/// **Why these are not requirements.** §8.5's vocabulary is an API this project does not own: an
/// extension written for PopClip names one of those spellings and expects the same answer here, so the
/// list stays closed (`ActionRequirement.Condition`). PRD §7.4 asks two things of the built-ins that
/// are not on it — Paste is shown only when *the clipboard has text*, and Search only *up to a maximum
/// length* — and the honest place for them is here: native conditions on native actions, applied by
/// `ActionResolver` after the shared pipeline has had its say, and reachable only through
/// `ActionExecutor.builtin`, which only the app's own bundle may name.
///
/// Inventing `pappu-clipboard-text` as a sixteenth requirement spelling was the alternative. It would
/// have put a condition in the extension vocabulary that no extension can ever use, and made the
/// closed list look open.
public struct BuiltinConditions: Sendable, Equatable, Hashable {
    /// Whether the clipboard holds text Paste could paste. Read once per attempt, from the change
    /// count the broker already tracks — never by taking ownership of the pasteboard (ACT-10).
    public var clipboardHasText: Bool

    /// How long a selection Search will still offer to search for.
    public var maximumSearchCharacters: Int

    public init(clipboardHasText: Bool = false, maximumSearchCharacters: Int = BuiltinConditions.defaultMaximumSearchCharacters) {
        self.clipboardHasText = clipboardHasText
        self.maximumSearchCharacters = maximumSearchCharacters
    }

    /// PRD §7.4's "up to a maximum length", given a number.
    ///
    /// The ceiling is the URL, not the text. A search term is percent-encoded into a query, which
    /// roughly triples a non-ASCII selection, and browsers stop being dependable somewhere past two
    /// thousand characters in an address. 512 characters of selection stays inside that with room for
    /// the template, and is far more than anything anybody means by "search for this".
    ///
    /// A selection past it does not make Search misbehave — it makes Search *absent*, which is the
    /// right answer for a paragraph the user selected to copy.
    public static let defaultMaximumSearchCharacters = 512

    public static let none = BuiltinConditions()
}

extension BuiltinAction {
    /// The native half of a built-in's visibility, applied on top of its manifest's `requirements`.
    ///
    /// Three of the five have nothing to add: Cut, Copy and Open Link say everything they need to say
    /// in their files, which is the shape every built-in should eventually have once the public API
    /// can express them (M3, M4).
    public func isOffered(for facts: MatchingFacts, given conditions: BuiltinConditions) -> Bool {
        switch self {
        case .cut, .copy, .openLink:
            true
        case .paste:
            conditions.clipboardHasText
        case .search:
            // Counted in characters, as the user would count them: a selection is long or short to a
            // person, and the URL budget this protects has slack enough not to need code points.
            facts.text.count <= conditions.maximumSearchCharacters
        }
    }
}
