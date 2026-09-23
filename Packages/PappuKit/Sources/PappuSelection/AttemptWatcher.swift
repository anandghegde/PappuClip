import Foundation
import PappuAX
import PappuCore
import Synchronization

/// The two Accessibility notifications an attempt is watched with (architecture §4.5).
///
/// A closed list, like `AXAttribute`, and for the same reason: these are the only things PappuClip ever
/// asks an app to tell it about. Both are events rather than values — neither carries the user's text,
/// and nothing here reads an attribute to find out what changed. That the selection moved is enough to
/// retire an attempt; what it moved to is none of our business (ACT-12).
public enum AXNotification: String, Sendable, Equatable, CaseIterable {
    /// `kAXFocusedUIElementChangedNotification`: the user is somewhere else now.
    case focusedElementChanged = "AXFocusedUIElementChanged"
    /// `kAXSelectedTextChangedNotification`: the selection a bar was about to be shown for has moved.
    case selectedTextChanged = "AXSelectedTextChanged"
}

/// The seam between the watcher and `AXObserver`: `SystemAXObserver` in the app, a fake in tests, which
/// have no app to register with and no run loop for Accessibility to deliver on.
///
/// One registration at a time, replaced rather than stacked, because at most one app is ever the app the
/// attempt in hand is about. `start` blocks on that app as every Accessibility call does, so it is only
/// ever called from `AXActor`.
public protocol AXObserving: Sendable {
    /// - Returns: Nil when the registration took, and the fault when the app would not have it. An app
    ///   that will not answer is watched by nothing and its attempts simply run unwatched, which is the
    ///   same position PappuClip is in for every app that has no Accessibility tree at all.
    func start(
        pid: pid_t,
        notifications: [AXNotification],
        _ fire: @escaping @Sendable (AXNotification) -> Void
    ) -> AXFault?

    /// Stopping twice must be harmless.
    func stop()
}

/// The seam over `NSWorkspace.didActivateApplicationNotification`: `WorkspaceActivationWatcher` in the
/// app, a fake in tests, which have no apps to bring forward.
public protocol ApplicationActivationWatching: Sendable {
    /// Calling `start` twice must not subscribe twice.
    func start(_ fire: @escaping @Sendable (TargetApp) -> Void)
    func stop()
}

/// What a watcher saw, and which attempt it was watching when it saw it (ACT-16a).
///
/// The attempt travels with the reason because a notice reaches the coordinator a hop later, by which
/// time the attempt it is about may be over and a newer one current. A notice retires the attempt it was
/// raised for or nothing at all.
public struct AttemptNotice: Sendable, Equatable {
    public var attempt: AttemptID
    public var reason: AttemptInvalidation

    public init(attempt: AttemptID, reason: AttemptInvalidation) {
        self.attempt = attempt
        self.reason = reason
    }
}

/// What `ActivationCoordinator` tells the watchers about the attempt in hand.
///
/// Four moments rather than two, because the two costs are different: registering with an app is an
/// Accessibility call that blocks on it, and saying which attempt is armed is a flag. `prepare` pays the
/// first at mouse-down, off the latency budget (architecture §4.3); the rest are free.
public protocol AttemptWatching: Sendable {
    /// Mouse-down, for the app the pointer is over. A gesture that never becomes an attempt has cost one
    /// registration, which is why it is made at most once per app.
    func prepare(for target: TargetApp) async

    /// The attempt is the current one: another app coming forward retires it from here.
    func arm(_ attempt: AttemptID, in target: TargetApp) async

    /// The strategy chain has answered, so the text the attempt holds can now go stale: the selection
    /// and focus notices retire it from here.
    func readReturned(for attempt: AttemptID) async

    /// The attempt is over, whatever became of it.
    func disarm(_ attempt: AttemptID) async
}

/// The watchers of ACT-16a that live outside the coordinator: an `AXObserver` on the app the attempt is
/// about, and `NSWorkspace`'s activation notices (architecture §4.5).
///
/// It decides nothing. It raises an `AttemptNotice` for the attempt that was armed when the notice came
/// in, and `ActivationCoordinator.watch(_:)` is the one consumer; the coordinator remains the only place
/// that retires an attempt.
///
/// **Why a selection notice only counts once the read is back.** The mouse tap sees mouse-up before the
/// app it happened in does. The app then finishes the gesture, settles the selection and posts
/// `AXSelectedTextChanged` — after the attempt has begun. Taken at face value, the user's own drag would
/// retire the attempt it started, and no bar would appear on the path that matters most. What saves it is
/// the order on the other end: the app posts that notice while it is handling the mouse-up, and answers
/// our read afterwards, so a notice raised before the answer arrived describes what the answer contains.
/// Only a notice after it says that what we hold has gone stale. The race this leaves is our own main
/// thread being blocked long enough for a notice to be delivered late, which is the smaller relative of
/// the gap in architecture §19 item 1.
///
/// **Why an activation notice counts at once.** A click into an app that was not in front activates it,
/// and that notice can arrive after the gesture is over, so the same problem would arise — except that
/// this notice says *which* app came forward, and the one the attempt is about is the one the gesture
/// itself brought there. Filtering by pid is exact, so no window is needed.
public final class AttemptWatcher: AttemptWatching, Sendable {
    /// For the inspector (DIA-2) and the tests: how many attempts each kind of notice retired. Counts,
    /// never content.
    public struct Retirements: Sendable, Equatable {
        public var counts: [AttemptInvalidation: Int] = [:]

        public var total: Int { counts.values.reduce(0, +) }
    }

    private struct Armed {
        var attempt: AttemptID
        var target: TargetApp
        var holdsARead = false
    }

    private struct State {
        var observing: pid_t?
        var armed: Armed?
        var fault: AXFault?
        var retirements = Retirements()
    }

    /// In order, for a single consumer (`ActivationCoordinator.watch(_:)`).
    public let notices: AsyncStream<AttemptNotice>

    private let observer: any AXObserving
    private let activations: any ApplicationActivationWatching
    private let continuation: AsyncStream<AttemptNotice>.Continuation
    private let state = Mutex(State())

    public init(
        observer: any AXObserving = SystemAXObserver(),
        activations: any ApplicationActivationWatching = WorkspaceActivationWatcher()
    ) {
        self.observer = observer
        self.activations = activations
        (notices, continuation) = AsyncStream.makeStream(of: AttemptNotice.self)
    }

    deinit {
        activations.stop()
        continuation.finish()
        // The Accessibility registration is left to `SystemAXObserver`'s own deinit: removing it is an
        // Accessibility call, it blocks on the app, and a deinit cannot wait for the actor it belongs on.
    }

    /// The attempt a notice would retire, and the app the registration is with. For the tests and the
    /// inspector; nothing decides on them.
    public var armedAttempt: AttemptID? { state.withLock { $0.armed?.attempt } }
    public var observedApplication: pid_t? { state.withLock { $0.observing } }
    public var retirements: Retirements { state.withLock { $0.retirements } }
    /// What the last registration was refused with, nil when it took (DIA-2).
    public var fault: AXFault? { state.withLock { $0.fault } }

    /// Subscribes to the workspace's activation notices, for the life of the app. The Accessibility
    /// registration is not made here: it is per app, and the app is not known until a gesture is in one.
    public func start() {
        // Weak, so that a subscription the app forgot to stop does not keep the watcher alive.
        activations.start { [weak self] app in self?.applicationActivated(app) }
    }

    public func stop() async {
        activations.stop()
        await stopObserving()
    }

    // MARK: What the coordinator says

    public func prepare(for target: TargetApp) async {
        guard needsObserver(for: target.pid) else { return }
        await observe(target.pid)
    }

    public func arm(_ attempt: AttemptID, in target: TargetApp) async {
        let needed = state.withLock { state -> Bool in
            state.armed = Armed(attempt: attempt, target: target)
            return state.observing != target.pid
        }
        // The gesture routes have prepared at mouse-down and take the cheap way out here; the routes
        // with no pointer (ACT-5, SCR-1, SCR-2) pay for the registration on the budget, once per app.
        guard needed else { return }
        await observe(target.pid)
    }

    public func readReturned(for attempt: AttemptID) {
        state.withLock { state in
            guard state.armed?.attempt == attempt else { return }
            state.armed?.holdsARead = true
        }
    }

    public func disarm(_ attempt: AttemptID) {
        state.withLock { state in
            // An attempt that was retired, or that a newer one has replaced, is not the armed one any
            // more; disarming it must not leave the newer one unwatched.
            guard state.armed?.attempt == attempt else { return }
            state.armed = nil
        }
    }

    // MARK: What the watchers saw

    private func applicationActivated(_ app: TargetApp) {
        retire(.applicationActivated) { $0.target.pid != app.pid }
    }

    /// Both notifications mean the same thing to an attempt — what it is holding is no longer what the
    /// user has — so `AttemptInvalidation` keeps one reason for the pair and the trace does not say which
    /// of the two arrived.
    private func accessibilityNoticed(_ notification: AXNotification) {
        retire(.focusChanged) { $0.holdsARead }
    }

    /// One notice per attempt: the armed attempt is cleared as it is raised, so an app that posts three
    /// notices for one keystroke retires one attempt and says so once.
    private func retire(_ reason: AttemptInvalidation, when isAbout: (Armed) -> Bool) {
        let notice = state.withLock { state -> AttemptNotice? in
            guard let armed = state.armed, isAbout(armed) else { return nil }
            state.armed = nil
            state.retirements.counts[reason, default: 0] += 1
            return AttemptNotice(attempt: armed.attempt, reason: reason)
        }
        guard let notice else { return }
        continuation.yield(notice)
    }

    // MARK: The Accessibility registration

    private func needsObserver(for pid: pid_t) -> Bool {
        state.withLock { $0.observing != pid }
    }

    /// One app at a time: `start` replaces whatever was registered, so moving from app to app leaves no
    /// observer behind on an app PappuClip is no longer looking at.
    @AXActor
    private func observe(_ pid: pid_t) {
        guard needsObserver(for: pid) else { return }
        let fault = observer.start(pid: pid, notifications: AXNotification.allCases) { [weak self] notification in
            self?.accessibilityNoticed(notification)
        }
        state.withLock { state in
            state.observing = fault == nil ? pid : nil
            state.fault = fault
        }
    }

    @AXActor
    private func stopObserving() {
        observer.stop()
        state.withLock { $0.observing = nil }
    }
}

/// The watcher for everything that is not the app: the tests that are about something else, and the
/// coordinator before the app has wired one up.
public struct UnwatchedAttempts: AttemptWatching {
    public init() {}

    public func prepare(for target: TargetApp) {}
    public func arm(_ attempt: AttemptID, in target: TargetApp) {}
    public func readReturned(for attempt: AttemptID) {}
    public func disarm(_ attempt: AttemptID) {}
}
