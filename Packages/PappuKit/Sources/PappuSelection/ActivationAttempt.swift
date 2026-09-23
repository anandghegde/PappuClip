import CoreGraphics
import Foundation
import PappuAX
import PappuCore

/// ACT-16b as a type: `BarController.show` cannot be called without one, and `ActivationCoordinator`
/// mints one only for an attempt that is still the current attempt and still inside the hard cutoff
/// (architecture §3.1, §3.5).
public struct AppearancePermit: ~Copyable, Sendable {
    public let attempt: AttemptID
    public let route: ActivationRoute
    public let target: TargetApp
    /// What was left of the hard cutoff when it was minted, so the bar knows how much of the render
    /// budget it still has (PRD §11.1).
    public let remaining: Duration

    init(attempt: AttemptID, route: ActivationRoute, target: TargetApp, remaining: Duration) {
        self.attempt = attempt
        self.route = route
        self.target = target
        self.remaining = remaining
    }
}

/// What the bar is given, alongside the permit: the selection, where it is, and what found it.
public struct AttemptPresentation: Sendable {
    public var attempt: AttemptID
    public var route: ActivationRoute
    public var target: TargetApp
    public var verdict: AppearanceVerdict
    /// Nil for `.caret`, which is the bar with no selection (ACT-3).
    public var text: String?
    public var range: AXTextRange?
    /// The selection's bounds, when the app gave them (BAR-3).
    public var bounds: CGRect?
    /// Where the pointer was when the gesture finished, which is where the bar goes when bounds are
    /// unknown (BAR-3). Nil for the routes with no pointer.
    public var pointer: CGPoint?
    /// BAR-3 places a multi-line selection by the direction the user dragged.
    public var dragDirection: DragDirection?
    public var strategy: SelectionStrategyKind?

    public init(
        attempt: AttemptID,
        route: ActivationRoute,
        target: TargetApp,
        verdict: AppearanceVerdict,
        text: String? = nil,
        range: AXTextRange? = nil,
        bounds: CGRect? = nil,
        pointer: CGPoint? = nil,
        dragDirection: DragDirection? = nil,
        strategy: SelectionStrategyKind? = nil
    ) {
        self.attempt = attempt
        self.route = route
        self.target = target
        self.verdict = verdict
        self.text = text
        self.range = range
        self.bounds = bounds
        self.pointer = pointer
        self.dragDirection = dragDirection
        self.strategy = strategy
    }
}

/// `BarController` in PappuSurfaces, once it exists; a recorder in the tests until then.
public protocol BarPresenting: Sendable {
    func show(_ presentation: AttemptPresentation, permit: consuming AppearancePermit) async
}

/// Why an attempt stopped being the current one (ACT-16a).
public enum AttemptInvalidation: String, Sendable, Codable, CaseIterable {
    /// A later gesture, shortcut press or script call asked for a bar of its own.
    case newerAttempt
    /// A mouse-down or a scroll that has not become a gesture yet. The user is doing something else.
    case newerInput
    /// The `AXObserver` on the focused element saw the focus or the selection move.
    case focusChanged
    /// Another application came forward.
    case applicationActivated
    /// Pause, a new hard block, or secure input turning on (ACT-12, ACT-17a, ACT-18).
    case privacyStateChanged
    /// The 700 ms of PRD §11.1 went by.
    case hardCutoff
    /// A tap was off for a while and events may have gone by unseen, a mouse-up among them (ACT-15).
    case tapInterrupted
}

/// One attempt as the inspector will tell it (DIA-2).
///
/// Codes, identifiers, counts and durations. There is no field the selection could be written into —
/// `characters` says how much was read and nothing says what — and a test walks a whole record to prove
/// it, in the same spirit as the one that walks a `PrivacyDenial`.
public struct AttemptRecord: Sendable, Equatable {
    public var attempt: AttemptID
    public var route: ActivationRoute
    public var gesture: Gesture?
    public var pid: pid_t?
    public var bundleID: String?
    /// Why the gate refused, when it did (S1).
    public var denial: PrivacyDenialReason?
    public var strategy: SelectionStrategyKind?
    public var outcome: SelectionRead.Outcome?
    public var verdict: AppearanceVerdict?
    /// How much text came back. Never what it said.
    public var characters: Int?
    /// The first thing the Accessibility probe could not do, when something went wrong (DIA-2).
    public var fault: AXFault?
    public var invalidation: AttemptInvalidation?
    public var showedBar = false
    /// From the start of the attempt to the end of it, on the attempt's own clock.
    public var elapsed: Duration = .zero

    public init(attempt: AttemptID, route: ActivationRoute, gesture: Gesture? = nil) {
        self.attempt = attempt
        self.route = route
        self.gesture = gesture
    }
}

/// The last few attempts, kept in a fixed-size ring because the app runs for weeks and a selection
/// attempt happens every few seconds (implementation plan, M1 week 2).
public struct AttemptTrace: Sendable {
    public let capacity: Int
    private var records: [AttemptRecord] = []

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ record: AttemptRecord) {
        records.append(record)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }

    /// Oldest first.
    public var all: [AttemptRecord] { records }
    public var last: AttemptRecord? { records.last }

    public subscript(attempt: AttemptID) -> AttemptRecord? {
        records.last { $0.attempt == attempt }
    }
}
