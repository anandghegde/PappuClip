import Foundation
import Synchronization

/// How much user input the taps have seen (architecture §3.4).
///
/// Not a `SequentialID`: those start at one so that zero can mean "none", and an epoch is meaningful at
/// zero — it means nobody has touched the Mac since launch. Nothing compares epochs for order, only for
/// equality, and the only question ever asked of it is "is this the same number it was a moment ago".
///
/// PappuClip's own posted events do not count, and that is structural rather than remembered:
/// `TapInput.init(type:event:ownTag:)` returns nil for an event carrying our `SyntheticEventTag`, so a
/// synthetic ⌘C never reaches the counter at all.
public struct InputEpoch: Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let start = InputEpoch(rawValue: 0)

    public var description: String { "epoch#\(rawValue)" }
}

/// Keeps key events visible for as long as it lives.
///
/// The key-down tap exists only while somebody holds a `KeyTapLease` (ACT-19), so without one the epoch
/// counts mouse input and nothing else. A clipboard transaction's window is exactly the moment a
/// keystroke could replace the selection out from under it — architecture §19 item 1 — so the broker
/// takes one of these for the length of a transaction and gives it back at the end.
public protocol InputWatch: Sendable {
    func stop()
}

/// What the broker needs to know about the keyboard and the mouse, and no more.
public protocol InputEpochReading: Sendable {
    var inputEpoch: InputEpoch { get }

    /// - Returns: Nil when the key tap cannot be installed, which is how a missing Accessibility grant
    ///   shows up. The caller then runs blind to keystrokes and must say so rather than assume none
    ///   happened (RUN-2g).
    func watchInput() -> (any InputWatch)?
}

/// The count itself, incremented on the tap's thread and read from anywhere.
///
/// `wrappingAdd` and `.relaxed`: the counter is compared with a value read a few hundred milliseconds
/// ago, so ordering against other memory buys nothing, and a wrap after 2^64 events is not a bug worth
/// a branch.
public final class InputEpochCounter: Sendable {
    private let value = Atomic<UInt64>(0)

    public init() {}

    public var epoch: InputEpoch { InputEpoch(rawValue: value.load(ordering: .relaxed)) }

    /// Called from the tap callback, where it must be free: one atomic add and no allocation.
    public func advance() {
        value.wrappingAdd(1, ordering: .relaxed)
    }
}
