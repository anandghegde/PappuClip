import Foundation
import Synchronization

/// What makes the service look at its taps again (architecture §4.1, ACT-15).
///
/// No timer polls them. A tap macOS switches off while it is in use says so through its own callback,
/// and these three moments cover the rest: a tap can be gone after sleep, after a fast user switch, or
/// because the grant was changed in System Settings while another app was in front.
public enum HealthTrigger: String, Sendable, Hashable, CaseIterable, Codable {
    case wake
    case sessionBecameActive
    case applicationActivated
}

/// The seam between the monitor and the notification centre: `WorkspaceHealthTriggers` in the app, a
/// fake in tests, which have neither a session to wake nor apps to activate.
public protocol HealthTriggering: Sendable {
    /// Calling `start` twice must not subscribe twice.
    func start(_ fire: @escaping @Sendable (HealthTrigger) -> Void)
    func stop()
}

/// Hooks `EventTapService.checkHealth()` to the moments a tap may have gone away unnoticed.
///
/// It is deliberately thin: the service decides what a tap needs and reports an interruption to its
/// consumers, and this only says when to ask. There is no throttling — a health check is two
/// `CGEvent.tapIsEnabled` calls, and app activation, the most frequent of the three, is rarer than
/// anything else on the latency path.
public final class TapHealthMonitor: Sendable {
    /// For the inspector (DIA-2) and the tests. Counts and outcomes, nothing of what was typed.
    public struct Checks: Sendable, Equatable {
        public var counts: [HealthTrigger: Int]
        public var last: EventTapService.HealthReport?

        public var total: Int { counts.values.reduce(0, +) }
    }

    private let service: EventTapService
    private let triggers: any HealthTriggering
    private let state = Mutex(Checks(counts: [:], last: nil))

    public init(service: EventTapService, triggers: any HealthTriggering) {
        self.service = service
        self.triggers = triggers
    }

    deinit {
        triggers.stop()
    }

    public var checks: Checks { state.withLock { $0 } }

    public func start() {
        // Weak, so that a subscription the app forgot to stop does not keep the monitor, and with it
        // the service and its taps, alive.
        triggers.start { [weak self] trigger in self?.check(trigger) }
    }

    public func stop() {
        triggers.stop()
    }

    private func check(_ trigger: HealthTrigger) {
        let report = service.checkHealth()
        state.withLock { checks in
            checks.counts[trigger, default: 0] += 1
            checks.last = report
        }
    }
}
