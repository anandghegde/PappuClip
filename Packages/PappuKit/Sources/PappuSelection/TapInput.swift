import CoreGraphics
import Foundation

/// A key-down as the key tap hands it to the holders of a `KeyTapLease`.
///
/// It exists for the length of that call: a bar deciding whether a key is one of its own (BAR-9, BAR-10).
/// It is never logged, stored or sent anywhere, and no tap produces one while no lease is held (ACT-19).
public struct KeyPress: Sendable, Equatable {
    /// `kCGKeyboardEventKeycode`: a virtual key code, not a character.
    public var keyCode: UInt16
    public var modifiers: PointerEvent.Modifiers
    public var isRepeat: Bool
    /// `CGEvent.timestamp`: nanoseconds since startup.
    public var timestampNs: UInt64

    public init(keyCode: UInt16, modifiers: PointerEvent.Modifiers = [], isRepeat: Bool = false, timestampNs: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.timestampNs = timestampNs
    }
}

/// What a tap's callback copies out of a `CGEvent` before it returns (architecture §4.1).
public enum TapInput: Sendable, Equatable {
    public enum DisabledReason: Sendable, Equatable {
        /// The callback took too long.
        case timeout
        case userInput
    }

    case pointer(PointerEvent)
    case keyDown(KeyPress)
    /// macOS has switched the tap off and says so through the tap's own callback.
    case disabled(DisabledReason)
}

extension TapInput {
    /// Nil for an event of a type no tap of ours asks for, and for one PappuClip posted itself.
    public init?(type: CGEventType, event: CGEvent, ownTag: SyntheticEventTag) {
        // A disabled notice comes with no event worth the name, so it is settled before anything is read.
        switch type {
        case .tapDisabledByTimeout:
            self = .disabled(.timeout)
            return
        case .tapDisabledByUserInput:
            self = .disabled(.userInput)
            return
        default: break
        }
        guard !ownTag.marks(event) else { return nil }

        let pointerKind: PointerEvent.Kind
        switch type {
        case .leftMouseDown: pointerKind = .down
        case .leftMouseDragged: pointerKind = .dragged
        case .leftMouseUp: pointerKind = .up
        case .scrollWheel: pointerKind = .scroll
        case .keyDown:
            self = .keyDown(KeyPress(
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: PointerEvent.Modifiers(event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                timestampNs: event.timestamp
            ))
            return
        default: return nil
        }
        self = .pointer(PointerEvent(
            kind: pointerKind,
            location: event.location,
            modifiers: PointerEvent.Modifiers(event.flags),
            clickCount: pointerKind == .scroll ? 0 : Int(event.getIntegerValueField(.mouseEventClickState)),
            timestampNs: event.timestamp,
            windowNumber: Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        ))
    }
}

extension PointerEvent.Modifiers {
    public init(_ flags: CGEventFlags) {
        self = []
        if flags.contains(.maskShift) { insert(.shift) }
        if flags.contains(.maskControl) { insert(.control) }
        if flags.contains(.maskAlternate) { insert(.option) }
        if flags.contains(.maskCommand) { insert(.command) }
    }
}
