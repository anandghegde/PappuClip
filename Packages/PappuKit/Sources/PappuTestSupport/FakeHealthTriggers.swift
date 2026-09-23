import PappuSelection
import Synchronization

/// Stands in for `NSWorkspace`'s notices. A test plays macOS: it wakes the machine, switches the
/// session back and brings an app to the front.
public final class FakeHealthTriggers: HealthTriggering {
    private struct State {
        var fire: (@Sendable (HealthTrigger) -> Void)?
        var starts = 0
        var stops = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var isObserving: Bool { state.withLock { $0.fire != nil } }
    public var startCount: Int { state.withLock { $0.starts } }
    public var stopCount: Int { state.withLock { $0.stops } }

    public func start(_ fire: @escaping @Sendable (HealthTrigger) -> Void) {
        state.withLock { state in
            state.starts += 1
            guard state.fire == nil else { return }
            state.fire = fire
        }
    }

    public func stop() {
        state.withLock { state in
            state.stops += 1
            state.fire = nil
        }
    }

    /// Delivers a notice. Nothing happens when nobody is observing, which is the point of `stop`.
    @discardableResult
    public func send(_ trigger: HealthTrigger) -> Bool {
        guard let fire = state.withLock({ $0.fire }) else { return false }
        fire(trigger)
        return true
    }
}
