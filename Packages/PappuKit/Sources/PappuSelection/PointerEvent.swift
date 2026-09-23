import CoreGraphics
import Foundation

/// What the mouse tap's callback copies out of a `CGEvent` before it returns (architecture §4.1).
///
/// It is plain data, so everything after the tap can be driven by a recording. Events PappuClip posted
/// itself are dropped by the tap service and never become one of these.
public struct PointerEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case down, dragged, up, scroll
    }

    /// From the mouse event's own flags, never from a key tap (ACT-19).
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var kind: Kind
    /// Global display coordinates with a top-left origin, as the tap reports them: y grows downwards.
    public var location: CGPoint
    public var modifiers: Modifiers
    /// `kCGMouseEventClickState`. Zero for a scroll.
    public var clickCount: Int
    /// `CGEvent.timestamp`: nanoseconds since startup.
    public var timestampNs: UInt64
    /// `kCGMouseEventWindowUnderMousePointer`.
    public var windowNumber: Int

    public init(
        kind: Kind,
        location: CGPoint,
        modifiers: Modifiers = [],
        clickCount: Int = 1,
        timestampNs: UInt64,
        windowNumber: Int
    ) {
        self.kind = kind
        self.location = location
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.timestampNs = timestampNs
        self.windowNumber = windowNumber
    }
}

/// Written as a list of names, so a recording can be read and corrected by hand.
extension PointerEvent.Modifiers: Codable {
    private static let names: [(Self, String)] = [
        (.shift, "shift"), (.control, "control"), (.option, "option"), (.command, "command"),
    ]

    public init(from decoder: any Decoder) throws {
        self = []
        for name in try [String](from: decoder) {
            guard let modifier = Self.names.first(where: { $0.1 == name })?.0 else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown modifier '\(name)'")
                )
            }
            insert(modifier)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.names.filter { contains($0.0) }.map(\.1).encode(to: encoder)
    }
}
