import Foundation

/// Where something is in the selection, in UTF-16 offsets.
///
/// UTF-16 because that is the only unit every consumer already agrees on: `NSDataDetector` and
/// `NSRegularExpression` produce it, JavaScript string indices are it (JS-3 hands every detection's
/// ranges to extensions), and `AXTextRange` is it too. A `String.Index` would be nicer Swift and
/// impossible to carry across any of those seams.
///
/// It lives in `PappuCore` rather than beside the analyser that produces it because the matching
/// pipeline narrows against it (§8.5 step 3) and the pipeline is below the analyser: the CLI and the
/// registry's CI run the pipeline on machines with no Accessibility tree at all (architecture §15).
public struct TextSpan: Sendable, Equatable, Hashable, Codable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var range: NSRange { NSRange(location: location, length: length) }

    /// One past the last offset the span covers.
    public var end: Int { location + length }

    public var isEmpty: Bool { length <= 0 }

    /// Touching at an edge is not overlapping: `example.com` immediately after a path is two
    /// detections, not one that swallowed the other.
    public func overlaps(_ other: TextSpan) -> Bool {
        location < other.end && other.location < end
    }

    /// The substring, or nil when the span does not fall on the string — which is what a span from one
    /// text applied to another looks like, and is worth an answer rather than a crash.
    public func substring(of text: String) -> String? {
        guard location >= 0, length >= 0 else { return nil }
        let utf16 = text.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: length, limitedBy: utf16.endIndex),
              let lower = String.Index(start, within: text),
              let upper = String.Index(end, within: text)
        else { return nil }
        return String(text[lower..<upper])
    }
}
