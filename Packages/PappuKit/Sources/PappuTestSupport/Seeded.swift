/// A tiny linear congruential generator, so a test that explores many cases explores the same ones on
/// every machine and a failure can be reproduced from the seed in its message.
///
/// Not `RandomNumberGenerator`: that protocol's `next()` is asked for full-width values and the point
/// here is the opposite — a short, obvious sequence that is written down in the test that uses it.
public struct Seeded {
    public var state: UInt64

    public init(state: UInt64) {
        self.state = state
    }

    /// Knuth's constants. The high bits are the ones worth using, hence the shift.
    public mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 16
    }

    public mutating func bool() -> Bool { next() & 1 == 0 }

    public mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
