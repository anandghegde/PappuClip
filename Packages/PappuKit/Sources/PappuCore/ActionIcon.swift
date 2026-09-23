import Foundation

/// An action's `icon` key, in the three states §8.3 gives it.
///
/// The distinction between "no key" and "`null`" is the whole reason this is not a `String?`. An
/// action with no `icon` key inherits the extension's, and an extension with no `icon` key inherits
/// its first action's; an action whose `icon` is an explicit `null` has asked for **no icon** and
/// falls back to its title instead. Collapsing the two would make a deliberate text button into an
/// accidental one.
public enum ActionIcon: Sendable, Equatable, Hashable {
    /// No `icon` key. Inherit.
    case unset
    /// `icon: null`. Draw the title, not an icon.
    case none
    /// A specifier (§8.11), kept as the author wrote it.
    case specifier(String)

    public var specifier: String? {
        if case .specifier(let text) = self { return text }
        return nil
    }

    /// The first of `self` and `fallbacks` that says anything, following §8.3's inheritance. An
    /// explicit `.none` stops the walk: it is an answer, not a gap.
    public func resolved(orInheriting fallbacks: ActionIcon...) -> ActionIcon {
        var candidates = [self]
        candidates.append(contentsOf: fallbacks)
        for candidate in candidates where candidate != .unset { return candidate }
        return .unset
    }

    // MARK: Coding

    init<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) throws {
        guard container.contains(key) else {
            self = .unset
            return
        }
        if try container.decodeNil(forKey: key) {
            self = .none
            return
        }
        self = .specifier(try container.decode(String.self, forKey: key))
    }

    func encode<Key: CodingKey>(into container: inout KeyedEncodingContainer<Key>, forKey key: Key) throws {
        switch self {
        case .unset: break
        case .none: try container.encodeNil(forKey: key)
        case .specifier(let text): try container.encode(text, forKey: key)
        }
    }
}

/// What an icon specifier resolves to, as far as M1 reads them (§8.11).
///
/// §8.11 is P0 for three base forms — a file in the package, up to three characters of text, and an
/// SF Symbol — and P1 for Iconify, `svg:` and `data:`, with a list of modifiers in front of any of
/// them. **M1 reads two of the three**, because the third needs a package directory to resolve a
/// relative path against and packages are M2. Anything else, modifiers included, is kept whole as
/// `.unread` so that nothing is silently dropped and the caller can fall back to the title.
public enum IconSpec: Sendable, Equatable, Hashable {
    /// `symbol:<SF Symbol name>`.
    case symbol(String)
    /// Up to three characters, with or without the optional `text:` prefix.
    case text(String)
    /// A form this build does not render, kept as written. M2 and M4 shrink this case.
    case unread(String)

    /// §8.11: "text of up to three characters".
    public static let maximumTextCharacters = 3

    public init(parsing specifier: String) {
        let trimmed = specifier.trimmingCharacters(in: .whitespaces)
        if let name = Self.body(of: trimmed, after: "symbol:"), !name.isEmpty {
            self = .symbol(name)
            return
        }
        if let text = Self.body(of: trimmed, after: "text:") {
            self = Self.textOrUnread(text, whole: trimmed)
            return
        }
        // A bare specifier with no prefix is text, but only if it could be: anything holding a `:` is
        // some other form's prefix — `iconify:`, `svg:`, `data:` — and anything longer than three
        // characters is a file path or a form we do not read.
        guard !trimmed.contains(":") else {
            self = .unread(trimmed)
            return
        }
        self = Self.textOrUnread(trimmed, whole: trimmed)
    }

    private static func textOrUnread(_ text: String, whole: String) -> IconSpec {
        let candidate = text.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, candidate.count <= maximumTextCharacters else { return .unread(whole) }
        return .text(candidate)
    }

    private static func body(of specifier: String, after prefix: String) -> String? {
        guard specifier.lowercased().hasPrefix(prefix) else { return nil }
        return String(specifier.dropFirst(prefix.count))
    }
}
