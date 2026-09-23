import Synchronization

/// An ID that only ever goes up (architecture §3.2).
///
/// Every async result, XPC message and clipboard transaction carries one, and gates compare IDs;
/// nothing else decides staleness. Zero is never issued, so it can stand for "none" on the wire.
public protocol SequentialID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Prefix for logs and traces.
    static var label: String { get }
    var rawValue: UInt64 { get }
    init(rawValue: UInt64)
}

extension SequentialID {
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "\(Self.label)#\(rawValue)" }
}

/// One selection attempt. `ActivationCoordinator` holds the single current one; a newer attempt, a focus
/// change, a privacy-state change or the hard cutoff replaces it (ACT-16a).
public struct AttemptID: SequentialID {
    public static let label = "attempt"
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// One action run. `InvocationManager` holds its state; cancellation, pause and revocation flip it
/// synchronously (RUN-3a, RUN-3f).
public struct InvocationID: SequentialID {
    public static let label = "invocation"
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// One clipboard transaction. `ClipboardBroker` holds the single open one; a transaction outlives the
/// answer it gave, because the drain that watches for a late copy is part of it (architecture §5).
public struct ClipboardTransactionID: SequentialID {
    public static let label = "clipboard"
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Issues IDs in order from any thread, the tap thread included.
public final class IDSource<ID: SequentialID>: Sendable {
    private let last = Atomic<UInt64>(0)

    public init() {}

    public func next() -> ID {
        ID(rawValue: last.wrappingAdd(1, ordering: .relaxed).newValue)
    }
}
