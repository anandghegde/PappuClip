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
