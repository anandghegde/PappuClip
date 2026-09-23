import Foundation
import Synchronization

/// The one-shot long-press timer of ACT-3, behind a seam so that the coordinator owns no timer of its
/// own and a test can decide when 0.5 s has gone by.
///
/// `GestureRecognizer` asks for deadlines on the events' clock — `CGEvent.timestamp`, nanoseconds since
/// startup — so that the time an event spent queued counts towards the half second.
public protocol ActivationTiming: Sendable {
    /// Replaces any deadline already armed. `fire` runs off the caller's thread.
    func armLongPress(atNs deadline: UInt64, _ fire: @escaping @Sendable () -> Void)
    func disarmLongPress()
}

/// The app's timer. `DispatchTime.now().uptimeNanoseconds` is the same clock `CGEvent.timestamp` is on,
/// so the wait is the difference between the two, and an already-passed deadline fires at once.
public final class SystemActivationTiming: ActivationTiming {
    private let armed = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    deinit {
        armed.withLock { $0?.cancel() }
    }

    public func armLongPress(atNs deadline: UInt64, _ fire: @escaping @Sendable () -> Void) {
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = deadline > now ? deadline - now : 0
        let task = Task {
            try? await Task.sleep(for: .nanoseconds(Int64(min(delay, UInt64(Int64.max)))))
            guard !Task.isCancelled else { return }
            fire()
        }
        armed.withLock {
            $0?.cancel()
            $0 = task
        }
    }

    public func disarmLongPress() {
        armed.withLock {
            $0?.cancel()
            $0 = nil
        }
    }
}
