import Foundation

/// FMT-6: what an extension identifier may be.
///
/// `A–Z a–z 0–9 . - _`, starting and ending with a letter or digit, with no two separators in a row.
/// The rules are there so that an identifier is a safe path component, a safe defaults key and a safe
/// thing to put in a message without quoting, and so that `com.example.x` and `com.example..x` are not
/// two extensions a person cannot tell apart. The reserved prefix is `ExtensionManifest.validate`'s,
/// because whether it is allowed depends on the origin, which the identifier cannot know.
public enum ExtensionIdentifier {
    public enum Problem: Sendable, Equatable, CustomStringConvertible {
        case empty
        case disallowedCharacter(Character)
        case separatorAtEnds
        case consecutiveSeparators

        public var description: String {
            switch self {
            case .empty: "is empty"
            case .disallowedCharacter(let character): "contains \"\(character)\"; only letters, digits, \".\", \"-\" and \"_\" are allowed"
            case .separatorAtEnds: "must start and end with a letter or digit"
            case .consecutiveSeparators: "has two separators in a row"
            }
        }
    }

    static let separators: Set<Character> = [".", "-", "_"]

    /// The first rule `identifier` breaks, or `nil` when it is well formed.
    public static func problem(with identifier: String) -> Problem? {
        guard let first = identifier.first, let last = identifier.last else { return .empty }
        var previousWasSeparator = false
        for character in identifier {
            let isSeparator = separators.contains(character)
            if !isSeparator, !(character.isASCII && (character.isLetter || character.isNumber)) {
                return .disallowedCharacter(character)
            }
            if isSeparator, previousWasSeparator { return .consecutiveSeparators }
            previousWasSeparator = isSeparator
        }
        if separators.contains(first) || separators.contains(last) { return .separatorAtEnds }
        return nil
    }

    public static func isValid(_ identifier: String) -> Bool {
        problem(with: identifier) == nil
    }
}

/// The extension API this build implements (§8.1).
///
/// A manifest's `popclipVersion` names the PopClip build whose API it needs; one above
/// `emulatedPopClip` asks for something this build does not have, and is refused at load rather than
/// run with a piece missing. `pappuclipVersion` is the same gate for the native API.
public enum APILevel {
    /// PopClip 2026.8.1, build 6221: the PRD's reference baseline.
    public static let emulatedPopClip = 6221
    public static let native = 1
}
