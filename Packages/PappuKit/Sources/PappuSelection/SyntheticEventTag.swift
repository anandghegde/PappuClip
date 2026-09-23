import CoreGraphics

/// Marks the events PappuClip posts, so that its own taps leave them out of gestures and of the input
/// epoch (architecture §3.4). The value is new at every launch and travels in `eventSourceUserData`.
public struct SyntheticEventTag: Sendable, Equatable {
    public let rawValue: Int64

    /// Zero is what an untagged event carries, so it cannot be a tag.
    public init?(rawValue: Int64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }

    private init(nonZero rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func random() -> SyntheticEventTag {
        SyntheticEventTag(nonZero: .random(in: 1...Int64.max))
    }

    public func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: rawValue)
    }

    public func marks(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == rawValue
    }
}
