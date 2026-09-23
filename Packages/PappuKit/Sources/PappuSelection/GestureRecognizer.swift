import CoreGraphics
import Foundation

/// BAR-3 places the bar of a multi-line selection by this. A level drag counts as downwards, which is
/// harmless because a single-line selection is placed by the Position setting instead.
public enum DragDirection: String, Sendable, Codable {
    case upwards, downwards
}

/// What the pointer did, from the event stream alone (architecture §4.2).
public enum Gesture: Sendable, Equatable, Codable {
    case dragSelect(direction: DragDirection)
    /// Double-click and up, including click-and-hold-then-drag (ACT-1, ACT-2).
    case multiClick(count: Int, dragged: Bool)
    case shiftClick
    /// Reported while the button is still down (ACT-3).
    case longPress
    /// One of the above with ⌘ held at some point in it (ACT-7). Kept as an output so that the
    /// inspector can say why no bar appeared (DIA-2).
    case suppressed
}

/// A gesture is only a candidate: whether a bar appears is decided downstream from the element under
/// `pressLocation`, the baseline range and the read itself (ACT-14).
public struct GestureCandidate: Sendable, Equatable {
    public var gesture: Gesture
    public var pressLocation: CGPoint
    /// Where the pointer was at mouse-up. For a long press, the press location.
    public var releaseLocation: CGPoint
    public var windowNumber: Int
    /// When the gesture was complete, on the events' own clock. The attempt's clock starts here.
    public var timestampNs: UInt64
}

/// A pure state machine, `Idle → Pressed → Dragging → Released` plus `LongPressArmed`, fed by the values
/// the mouse tap copies out. It has no AppKit or AX dependency and owns no timer, so a recorded event
/// stream replays through it exactly (see `GestureRecording` in PappuTestSupport).
///
/// Keyboard-only selection never reaches it, because no key tap exists while idle (ACT-8, ACT-19).
public struct GestureRecognizer: Sendable {
    /// Provisional values, to be tuned from the gesture corpus.
    public struct Configuration: Sendable, Equatable {
        /// Movement from the press location, in points, that turns a press into a drag.
        public var dragSlop: Double
        public var longPressMs: Int

        public init(dragSlop: Double = 4, longPressMs: Int = 500) {
            self.dragSlop = dragSlop
            self.longPressMs = longPressMs
        }
    }

    public struct PressID: Hashable, Sendable {
        let rawValue: UInt64
    }

    public enum Effect: Sendable, Equatable {
        /// Start the one-shot timer, replacing any earlier one. The deadline is on the events' clock,
        /// so time the event spent queued counts towards the 0.5 s.
        case armLongPress(PressID, deadlineNs: UInt64)
        case disarmLongPress
        case candidate(GestureCandidate)
    }

    private struct Press {
        var id: PressID
        var down: PointerEvent
        /// Shift was down at the press and an earlier press in the same window gave it an anchor.
        var extendsSelection: Bool
    }

    private enum State {
        case idle
        case longPressArmed(Press)
        case pressed(Press)
        case dragging(Press)
    }

    public let configuration: Configuration
    private var state = State.idle
    private var lastPressID: UInt64 = 0
    private var lastPressWindow: Int?
    /// ⌘ seen anywhere in the current click sequence, so ⌘ on the first click of a double-click counts.
    private var commandSeen = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// No input produces more than one effect.
    public mutating func handle(_ event: PointerEvent) -> Effect? {
        switch event.kind {
        case .down: down(event)
        case .dragged: dragged(event)
        case .up: up(event)
        case .scroll: nil
        }
    }

    /// A timer that was disarmed, or belongs to an earlier press, may still fire; it is ignored.
    public mutating func longPressTimerFired(_ id: PressID) -> Effect? {
        guard case .longPressArmed(let press) = state, press.id == id else { return nil }
        state = .pressed(press)
        return candidate(.longPress, press, at: press.down.location, timestampNs: deadline(of: press))
    }

    /// For a rebuilt tap (ACT-15): whatever press was in progress, its mouse-up may never arrive.
    public mutating func reset() -> Effect? {
        defer { state = .idle }
        if case .longPressArmed = state { return .disarmLongPress }
        return nil
    }

    // A press while one is in progress means a mouse-up was lost. The new press simply takes over.
    private mutating func down(_ event: PointerEvent) -> Effect? {
        if event.clickCount <= 1 { commandSeen = false }
        commandSeen = commandSeen || event.modifiers.contains(.command)

        lastPressID += 1
        let shift = event.modifiers.contains(.shift)
        let press = Press(
            id: PressID(rawValue: lastPressID),
            down: event,
            extendsSelection: shift && lastPressWindow == event.windowNumber
        )
        lastPressWindow = event.windowNumber

        // A double- or triple-click-and-hold waits for release like any other selection (ACT-2).
        guard event.clickCount <= 1, !shift else {
            state = .pressed(press)
            return nil
        }
        state = .longPressArmed(press)
        return .armLongPress(press.id, deadlineNs: deadline(of: press))
    }

    private mutating func dragged(_ event: PointerEvent) -> Effect? {
        let press: Press
        let wasArmed: Bool
        switch state {
        case .idle: return nil
        case .longPressArmed(let current): (press, wasArmed) = (current, true)
        case .pressed(let current), .dragging(let current): (press, wasArmed) = (current, false)
        }
        commandSeen = commandSeen || event.modifiers.contains(.command)

        let dx = event.location.x - press.down.location.x
        let dy = event.location.y - press.down.location.y
        guard (dx * dx + dy * dy).squareRoot() > configuration.dragSlop else { return nil }
        state = .dragging(press)
        return wasArmed ? .disarmLongPress : nil
    }

    private mutating func up(_ event: PointerEvent) -> Effect? {
        defer { state = .idle }
        commandSeen = commandSeen || event.modifiers.contains(.command)

        let press: Press
        let dragged: Bool
        switch state {
        case .idle: return nil
        // A plain click. It selects nothing, but it is the anchor of a later Shift-click.
        case .longPressArmed: return .disarmLongPress
        case .pressed(let current): (press, dragged) = (current, false)
        case .dragging(let current): (press, dragged) = (current, true)
        }

        let count = max(press.down.clickCount, event.clickCount)
        let gesture: Gesture
        if count >= 2 {
            gesture = .multiClick(count: count, dragged: dragged)
        } else if press.extendsSelection {
            gesture = .shiftClick
        } else if dragged {
            gesture = .dragSelect(direction: event.location.y < press.down.location.y ? .upwards : .downwards)
        } else {
            // A long press that has already been reported, or a Shift-click with nothing to extend.
            return nil
        }
        return candidate(gesture, press, at: event.location, timestampNs: event.timestampNs)
    }

    private func candidate(_ gesture: Gesture, _ press: Press, at release: CGPoint, timestampNs: UInt64) -> Effect {
        .candidate(GestureCandidate(
            gesture: commandSeen ? .suppressed : gesture,
            pressLocation: press.down.location,
            releaseLocation: release,
            windowNumber: press.down.windowNumber,
            timestampNs: timestampNs
        ))
    }

    private func deadline(of press: Press) -> UInt64 {
        press.down.timestampNs + UInt64(configuration.longPressMs) * 1_000_000
    }
}
