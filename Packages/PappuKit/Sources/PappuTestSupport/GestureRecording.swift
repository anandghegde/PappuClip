import PappuSelection

/// One interaction of the gesture corpus (architecture §17, `Tests/gestures/`): the pointer events the
/// mouse tap saw, and what the recogniser should make of them.
///
/// It holds coordinates, times and window numbers and no text, so a recording made in a real app says
/// nothing about what was selected.
public struct GestureRecording: Sendable, Equatable, Codable {
    public var name: String
    /// "synthetic", or the app and macOS version it was recorded in.
    public var source: String
    public var events: [PointerEvent]
    /// In order. Empty for a non-trigger interaction (PRD §3.3).
    public var expected: [Gesture]

    public init(name: String, source: String = "synthetic", events: [PointerEvent], expected: [Gesture]) {
        self.name = name
        self.source = source
        self.events = events
        self.expected = expected
    }

    /// Runs the events through a recogniser and stands in for the long-press timer: it fires when the
    /// next event is at or past the deadline, as a real timer would have between the two.
    public func replay(through recognizer: GestureRecognizer = GestureRecognizer()) -> [GestureCandidate] {
        var recognizer = recognizer
        var timer: (press: GestureRecognizer.PressID, deadlineNs: UInt64)?
        var candidates: [GestureCandidate] = []

        func apply(_ effect: GestureRecognizer.Effect?) {
            switch effect {
            case .armLongPress(let press, let deadlineNs): timer = (press, deadlineNs)
            case .disarmLongPress: timer = nil
            case .candidate(let candidate): candidates.append(candidate)
            case nil: break
            }
        }

        for event in events {
            if let due = timer, event.timestampNs >= due.deadlineNs {
                timer = nil
                apply(recognizer.longPressTimerFired(due.press))
            }
            apply(recognizer.handle(event))
        }
        return candidates
    }
}
