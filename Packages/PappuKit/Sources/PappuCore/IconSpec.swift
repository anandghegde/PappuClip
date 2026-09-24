import Foundation

/// An icon specifier, read (§8.11, architecture §9.6).
///
/// A specifier is any number of modifiers and then one base form: `square filled T`,
/// `scale=90 file:yandex.png`, `symbol:bold`. The parser reads the whole grammar, because a specifier
/// half-read is one whose meaning changes the day the other half is written. What the bar *draws* is
/// narrower and is `IconRenderer`'s concern: §8.11 is P0 for text, file and SF Symbol bases, and P1 for
/// Iconify, `svg:` and `data:`, which are kept whole as `.unread` so that the bar can fall back to the
/// title and M4 can draw them without a format change.
public struct IconSpec: Sendable, Equatable, Hashable {
    public enum Base: Sendable, Equatable, Hashable {
        /// `symbol:<SF Symbol name>`.
        case symbol(String)
        /// Up to three characters, with or without the optional `text:` prefix.
        case text(String)
        /// A `.png` or `.svg` in the package, relative to its root, with or without `file:`.
        case file(String)
        /// A form this build does not render, kept as written: `iconify:`, `svg:`, `data:`, or text too
        /// long to be text.
        case unread(String)
    }

    /// §8.11's modifiers. A flag is off and a number is at its neutral value unless the specifier says
    /// otherwise; `=0` turns a flag back off.
    public struct Modifiers: Sendable, Equatable, Hashable {
        public var square = false
        public var circle = false
        public var search = false
        public var strike = false
        public var filled = false
        public var monospaced = false
        public var flipX = false
        public var flipY = false
        public var preserveColor = false
        public var preserveAspect = false
        /// Percentages of the canvas, as PopClip writes them.
        public var moveX: Double = 0
        public var moveY: Double = 0
        public var scale: Double = 100
        /// Degrees.
        public var rotate: Double = 0

        public init() {}

        public static let none = Modifiers()
    }

    public var modifiers: Modifiers
    public var base: Base

    public init(modifiers: Modifiers = .none, base: Base) {
        self.modifiers = modifiers
        self.base = base
    }

    public static func symbol(_ name: String) -> IconSpec { IconSpec(base: .symbol(name)) }
    public static func text(_ text: String) -> IconSpec { IconSpec(base: .text(text)) }
    public static func file(_ path: String) -> IconSpec { IconSpec(base: .file(path)) }
    public static func unread(_ specifier: String) -> IconSpec { IconSpec(base: .unread(specifier)) }

    /// §8.11: "text of up to three characters".
    public static let maximumTextCharacters = 3

    public init(parsing specifier: String) {
        let trimmed = specifier.trimmingCharacters(in: .whitespaces)
        var modifiers = Modifiers()
        var rest = Substring(trimmed)

        // Leading words that are modifiers are modifiers. The first word that is not one starts the
        // base, which keeps its own spaces (`svg:<svg …>`, `text:A B`). A specifier made of nothing
        // but modifier words has its last word as the base: `search` alone is the letters, not an
        // empty icon with a magnifier on it.
        while let space = rest.firstIndex(of: " ") {
            let word = rest[..<space]
            guard Self.apply(word, to: &modifiers) else { break }
            rest = rest[space...].drop(while: { $0 == " " })
        }
        self.init(modifiers: modifiers, base: Self.base(String(rest), modifiers: &modifiers))
        self.modifiers = modifiers
    }

    private static func base(_ text: String, modifiers: inout Modifiers) -> Base {
        let lowered = text.lowercased()
        if lowered.hasPrefix("symbol:") {
            let name = String(text.dropFirst("symbol:".count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? .unread(text) : .symbol(name)
        }
        if lowered.hasPrefix("file:") {
            let path = String(text.dropFirst("file:".count)).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? .unread(text) : .file(path)
        }
        if lowered.hasPrefix("text:") {
            return self.text(String(text.dropFirst("text:".count)), whole: text, modifiers: &modifiers)
        }
        // Every other prefixed form is P1 and kept whole. A bare word with a `:` in it is some prefix
        // this grammar does not have, and guessing that it is text would draw `ab:` on a button.
        if lowered.contains(":") { return .unread(text) }
        if ["png", "svg"].contains((text as NSString).pathExtension.lowercased()) { return .file(text) }
        return self.text(text, whole: text, modifiers: &modifiers)
    }

    /// Text, where `(AB)` and `[AB]` are PopClip's spellings of a circled and a boxed `AB`.
    private static func text(_ body: String, whole: String, modifiers: inout Modifiers) -> Base {
        var candidate = body.trimmingCharacters(in: .whitespaces)
        if candidate.count >= 3, let first = candidate.first, let last = candidate.last {
            if first == "(" && last == ")" {
                modifiers.circle = true
                candidate = String(candidate.dropFirst().dropLast())
            } else if first == "[" && last == "]" {
                modifiers.square = true
                candidate = String(candidate.dropFirst().dropLast())
            }
        }
        guard !candidate.isEmpty, candidate.count <= maximumTextCharacters else { return .unread(whole) }
        return .text(candidate)
    }

    /// Reads one word as a modifier into `modifiers`; false if it is not one.
    private static func apply(_ word: Substring, to modifiers: inout Modifiers) -> Bool {
        let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        // Legacy spellings use an underscore (`flip_x`, `preserve_color`).
        let name = parts[0].lowercased().replacingOccurrences(of: "_", with: "-")
        let value = parts.count == 2 ? String(parts[1]) : nil

        func flag(_ keyPath: WritableKeyPath<Modifiers, Bool>) -> Bool {
            switch value {
            case nil: modifiers[keyPath: keyPath] = true
            case let value?:
                guard let number = Double(value) else { return false }
                modifiers[keyPath: keyPath] = number != 0
            }
            return true
        }
        func number(_ keyPath: WritableKeyPath<Modifiers, Double>) -> Bool {
            guard let value, let number = Double(value) else { return false }
            modifiers[keyPath: keyPath] = number
            return true
        }

        switch name {
        case "square": return flag(\.square)
        case "circle": return flag(\.circle)
        case "search": return flag(\.search)
        case "strike": return flag(\.strike)
        case "filled": return flag(\.filled)
        case "monospaced": return flag(\.monospaced)
        case "flip-x": return flag(\.flipX)
        case "flip-y": return flag(\.flipY)
        case "preserve-color": return flag(\.preserveColor)
        case "preserve-aspect": return flag(\.preserveAspect)
        case "move-x": return number(\.moveX)
        case "move-y": return number(\.moveY)
        case "scale": return number(\.scale)
        case "rotate": return number(\.rotate)
        default: return false
        }
    }
}
