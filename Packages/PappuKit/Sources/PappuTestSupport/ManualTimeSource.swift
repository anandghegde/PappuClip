import Synchronization

/// A clock that moves only when a test says so. Pass `reader` as the `now` of an `AttemptClock`.
public final class ManualTimeSource: Sendable {
    private let instant: Mutex<ContinuousClock.Instant>

    public init(start: ContinuousClock.Instant = .now) {
        instant = Mutex(start)
    }

    public var now: ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    public func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }

    public var reader: @Sendable () -> ContinuousClock.Instant {
        { self.now }
    }
}
