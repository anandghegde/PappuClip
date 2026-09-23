import Foundation
import PappuAX
import PappuCore
import PappuSelection
import Synchronization

/// Stands in for `AXObserver`, which needs a live Accessibility grant, an app to register with and a
/// running run loop. A test plays the app: it registers, or refuses to, and posts notices.
public final class FakeAXObserver: AXObserving, Sendable {
    /// What was asked of the app, as the app saw it.
    public struct Registration: Sendable, Equatable {
        public var pid: pid_t
        public var notifications: [AXNotification]
    }

    private struct State {
        var fire: (@Sendable (AXNotification) -> Void)?
        var registrations: [Registration] = []
        var stops = 0
        var fault: AXFault?
    }

    private let state = Mutex(State())

    /// - Parameter refusing: What every registration comes back with, for the apps that answer nothing.
    public init(refusing fault: AXFault? = nil) {
        state.withLock { $0.fault = fault }
    }

    public var registrations: [Registration] { state.withLock { $0.registrations } }
    public var observedApplication: pid_t? { state.withLock { $0.fire == nil ? nil : $0.registrations.last?.pid } }
    public var isObserving: Bool { state.withLock { $0.fire != nil } }
    public var stopCount: Int { state.withLock { $0.stops } }

    /// From here on, registrations are refused with `fault`; nil lets them through again.
    public func refuse(with fault: AXFault?) {
        state.withLock { $0.fault = fault }
    }

    public func start(
        pid: pid_t,
        notifications: [AXNotification],
        _ fire: @escaping @Sendable (AXNotification) -> Void
    ) -> AXFault? {
        state.withLock { state in
            state.registrations.append(Registration(pid: pid, notifications: notifications))
            guard let fault = state.fault else {
                state.fire = fire
                return nil
            }
            // A refused registration leaves nothing behind, as the real one does.
            state.fire = nil
            return fault
        }
    }

    public func stop() {
        state.withLock { state in
            state.stops += 1
            state.fire = nil
        }
    }

    /// Posts a notice. Nothing happens when nobody is registered, which is the point of `stop`.
    @discardableResult
    public func send(_ notification: AXNotification) -> Bool {
        guard let fire = state.withLock({ $0.fire }) else { return false }
        fire(notification)
        return true
    }
}

/// Stands in for `NSWorkspace`'s activation notices. A test brings an app to the front.
public final class FakeApplicationActivations: ApplicationActivationWatching, Sendable {
    private struct State {
        var fire: (@Sendable (TargetApp) -> Void)?
        var starts = 0
        var stops = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var isObserving: Bool { state.withLock { $0.fire != nil } }
    public var startCount: Int { state.withLock { $0.starts } }
    public var stopCount: Int { state.withLock { $0.stops } }

    public func start(_ fire: @escaping @Sendable (TargetApp) -> Void) {
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

    @discardableResult
    public func send(_ app: TargetApp) -> Bool {
        guard let fire = state.withLock({ $0.fire }) else { return false }
        fire(app)
        return true
    }
}

/// Stands in for `NSWorkspace`'s launch and termination notices. A test launches and quits apps by
/// sending the set that is running afterwards.
public final class FakeRunningApplications: RunningApplicationsWatching, Sendable {
    private struct State {
        var fire: (@Sendable (Set<String>) -> Void)?
        var running: Set<String>
    }

    private let state: Mutex<State>

    /// - Parameter running: What is running when `start` is called, and so what it reports first.
    public init(running: Set<String> = []) {
        state = Mutex(State(running: running))
    }

    public var isObserving: Bool { state.withLock { $0.fire != nil } }

    public func start(_ fire: @escaping @Sendable (Set<String>) -> Void) {
        let running = state.withLock { state -> Set<String>? in
            guard state.fire == nil else { return nil }
            state.fire = fire
            return state.running
        }
        if let running { fire(running) }
    }

    public func stop() {
        state.withLock { $0.fire = nil }
    }

    /// Reports `running` as the apps running now, as a launch or a termination would.
    @discardableResult
    public func send(_ running: Set<String>) -> Bool {
        guard let fire = state.withLock({ state -> (@Sendable (Set<String>) -> Void)? in
            state.running = running
            return state.fire
        }) else { return false }
        fire(running)
        return true
    }
}
