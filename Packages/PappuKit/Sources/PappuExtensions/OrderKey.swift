import Foundation

/// A fractional-index string: the list's order without positions (architecture §11, SYN-2).
///
/// Every list item has one, and the list is sorted by it, then by item ID to settle a tie. Putting an
/// item between two others makes a key between theirs and touches nothing else, so two devices that
/// reorder different parts of the list produce edits that merge without renumbering anything — which
/// is the whole reason the 1.0 store has these rather than integers (sync is 1.x, and needs no
/// migration because of this).
///
/// Keys are base-62 digits in ASCII order (`0-9`, `A-Z`, `a-z`), read as the digits after a radix
/// point: `"V"` is about 0.5, `"8"` is about 0.13. A key never ends in `0`, because `"a"` and
/// `"a0"` are the same number and there would be nothing between them. Plain string comparison is
/// numeric comparison for keys of this form, which is what lets SQLite's `ORDER BY` do the sorting.
public struct OrderKey: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = digits.count

    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.last != "0", rawValue.allSatisfy(Self.digitValue.keys.contains) else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = OrderKey(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(raw) is not an order key.")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: OrderKey, rhs: OrderKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A key strictly between `lower` and `upper`; nil means the start or the end of the list.
    /// `lower` must sort before `upper` — the caller has just read them from a sorted list.
    public static func between(_ lower: OrderKey?, _ upper: OrderKey?) -> OrderKey {
        let low = lower.map { $0.rawValue.map { digitValue[$0]! } } ?? []
        let high = upper.map { $0.rawValue.map { digitValue[$0]! } }
        precondition(high.map { low.lexicographicallyPrecedes($0) } ?? true, "OrderKey.between: \(String(describing: lower)) is not before \(String(describing: upper))")
        return OrderKey(unchecked: String(midpoint(low, high).map { digits[$0] }))
    }

    /// The key after the last one: where an appended item goes.
    public static func after(_ lower: OrderKey?) -> OrderKey { between(lower, nil) }

    /// `count` keys in order, all after `lower`, for a batch of appended items.
    public static func sequence(_ count: Int, after lower: OrderKey?) -> [OrderKey] {
        var keys: [OrderKey] = []
        var last = lower
        for _ in 0..<count {
            let key = after(last)
            keys.append(key)
            last = key
        }
        return keys
    }

    private static let digitValue: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })

    /// Digits strictly between `low` and `high` (nil: 1.0), neither ending in zero. The standard
    /// construction: copy the common prefix, then take the middle digit if there is room, and
    /// otherwise go one digit longer.
    private static func midpoint(_ low: [Int], _ high: [Int]?) -> [Int] {
        if let high {
            var prefix = 0
            while prefix < high.count, (prefix < low.count ? low[prefix] : 0) == high[prefix] {
                prefix += 1
            }
            if prefix > 0 {
                return Array(high.prefix(prefix)) + midpoint(Array(low.dropFirst(prefix)), Array(high.dropFirst(prefix)))
            }
        }
        let lowDigit = low.first ?? 0
        let highDigit = high?.first ?? base
        if highDigit - lowDigit > 1 {
            return [(lowDigit + highDigit + 1) / 2]
        }
        if let high, high.count > 1 {
            // `high` is `d…` with more after it, so `d` alone is below it and above `low`.
            return [high[0]]
        }
        return [lowDigit] + midpoint(Array(low.dropFirst()), nil)
    }
}
