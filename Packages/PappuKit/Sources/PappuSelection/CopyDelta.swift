import Foundation

/// How far one ⌘C is allowed to move the pasteboard's change count in a given app (ACT-10e).
///
/// This exists because the count is the only evidence the broker has that the copy it asked for is the
/// copy it is looking at, and because the count does not move once per copy in every app. M0 spike 6
/// found that the count moves when a writer *clears*, not when it has finished writing, so an app that
/// clears twice — or a framework that writes a second item behind the first — lands at a delta of two
/// with nothing wrong. A number that varies by app is policy data, not a constant.
///
/// The range is closed on both ends, and an empty range means "never simulate ⌘C here": it is what a
/// user ceiling spells to turn strategy 5 off without arguing about which of the two booleans to clear.
///
/// Intersection is what makes it safe in `DetectionPolicy.restricted(by:)` — two ranges can only ever
/// narrow each other, so the SEC-9 property that a merge never grants holds for this field the same way
/// `&&` makes it hold for the booleans.
public struct CopyDelta: Sendable, Equatable, Codable {
    public let minimum: Int
    public let maximum: Int

    /// Any `minimum > maximum` normalises to the one spelling of empty, so that two policies that both
    /// forbid synthetic copy compare equal however they said it.
    public init(minimum: Int, maximum: Int) {
        if minimum > maximum {
            self.minimum = 1
            self.maximum = 0
        } else {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    /// One clear, one write: what nearly every app does, and the default.
    public static let one = CopyDelta(minimum: 1, maximum: 1)
    /// One or two, for an app that clears twice or writes a second item.
    public static let oneOrTwo = CopyDelta(minimum: 1, maximum: 2)
    /// No copy is attributable, so strategy 5 cannot run.
    public static let none = CopyDelta(minimum: 1, maximum: 0)

    public var isEmpty: Bool { minimum > maximum }

    public func contains(_ delta: Int) -> Bool {
        !isEmpty && delta >= minimum && delta <= maximum
    }

    public func intersected(with other: CopyDelta) -> CopyDelta {
        CopyDelta(minimum: Swift.max(minimum, other.minimum), maximum: Swift.min(maximum, other.maximum))
    }

    /// True when every delta this range accepts is one `other` accepts too.
    public func isAtLeastAsRestrictive(as other: CopyDelta) -> Bool {
        isEmpty || (!other.isEmpty && minimum >= other.minimum && maximum <= other.maximum)
    }
}
