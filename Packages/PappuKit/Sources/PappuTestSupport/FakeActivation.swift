import CoreGraphics
import Foundation
import PappuCore
import PappuSelection
import Synchronization

/// Stands in for the strategy chain, which does not exist yet and which needs a live Accessibility tree
/// when it does.
///
/// A test says what the chain comes back with, and can hold the read open: `duringRead` runs while the
/// permit is spent and before the answer goes back, which is the window every ACT-16 rule is about.
public final class FakeSelectionReader: SelectionReading, Sendable {
    /// One call, as the reader saw it. It holds the permit's codes and never the permit.
    public struct Call: Sendable, Equatable {
        public var attempt: AttemptID
        public var route: ActivationRoute
        public var target: TargetApp
        public var scope: ReadScope
        public var chain: [SelectionStrategyKind]
    }

    private struct State {
        var result = SelectionRead.nothing
        var calls: [Call] = []
        var duringRead: (@Sendable () async -> Void)?
    }

    private let state = Mutex(State())

    public init(_ result: SelectionRead = .nothing) {
        state.withLock { $0.result = result }
    }

    public func answer(with result: SelectionRead) {
        state.withLock { $0.result = result }
    }

    /// Runs inside the read, once. Whatever it does to the coordinator happens while the attempt it
    /// belongs to is still in flight.
    public func interrupt(with body: @escaping @Sendable () async -> Void) {
        state.withLock { $0.duringRead = body }
    }

    public var calls: [Call] { state.withLock { $0.calls } }
    public var wasAsked: Bool { !calls.isEmpty }

    public func read(
        _ permit: consuming ReadPermit,
        attempt: AttemptID,
        chain: [SelectionStrategyKind],
        clock: AttemptClock
    ) async -> SelectionRead {
        let call = Call(
            attempt: attempt,
            route: permit.route,
            target: permit.target,
            scope: permit.scope,
            chain: chain
        )
        let interruption = state.withLock { state -> (@Sendable () async -> Void)? in
            state.calls.append(call)
            defer { state.duringRead = nil }
            return state.duringRead
        }
        await interruption?()
        return state.withLock { $0.result }
    }
}

/// Stands in for `BarController`, and keeps what it was shown so that a test can ask whether a bar
/// appeared, for which attempt, and with how much of the cutoff left (ACT-16b).
public final class FakeBarPresenter: BarPresenting, Sendable {
    /// What the permit said. The permit itself is consumed by the call that takes it.
    public struct Appearance: Sendable, Equatable {
        public var attempt: AttemptID
        public var route: ActivationRoute
        public var target: TargetApp
        public var verdict: AppearanceVerdict
        public var text: String?
        public var remaining: Duration
        public var dragDirection: DragDirection?
        public var pointer: CGPoint?
    }

    private let appearances = Mutex<[Appearance]>([])

    public init() {}

    public var shown: [Appearance] { appearances.withLock { $0 } }
    public var last: Appearance? { shown.last }
    public var showedBar: Bool { !shown.isEmpty }

    public func show(_ presentation: AttemptPresentation, permit: consuming AppearancePermit) async {
        let appearance = Appearance(
            attempt: permit.attempt,
            route: permit.route,
            target: permit.target,
            verdict: presentation.verdict,
            text: presentation.text,
            remaining: permit.remaining,
            dragDirection: presentation.dragDirection,
            pointer: presentation.pointer
        )
        appearances.withLock { $0.append(appearance) }
    }
}

/// A long-press timer that moves only when a test says so, so that ACT-3 costs no half second.
public final class FakeActivationTiming: ActivationTiming, Sendable {
    private struct State {
        var deadlines: [UInt64] = []
        var armed: (@Sendable () -> Void)?
        var disarms = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Every deadline that was armed, in order, on the events' clock.
    public var deadlines: [UInt64] { state.withLock { $0.deadlines } }
    public var isArmed: Bool { state.withLock { $0.armed != nil } }
    public var disarms: Int { state.withLock { $0.disarms } }

    /// What macOS does 0.5 s later. A timer that was disarmed fires nothing.
    public func fire() {
        state.withLock { $0.armed }?()
    }

    public func armLongPress(atNs deadline: UInt64, _ fire: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.deadlines.append(deadline)
            $0.armed = fire
        }
    }

    public func disarmLongPress() {
        state.withLock {
            $0.armed = nil
            $0.disarms += 1
        }
    }
}
