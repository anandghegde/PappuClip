import ApplicationServices
import Foundation
import PappuAX
import Synchronization

/// `AXObserver` itself (architecture §4.5), and the second of the two files that touch Core Foundation
/// on the selection path — the other is `SystemAXWorld`.
///
/// Registering blocks on the app being registered with, like any Accessibility call, so it happens on
/// `AXActor`. Delivery is the other way round: an `AXObserver` speaks through a run-loop source, and the
/// only run loop PappuClip runs is the main one, so notices arrive on the main thread and are handed
/// straight to the watcher, which takes a lock and nothing else.
public final class SystemAXObserver: AXObserving {
    /// The callback's context, as a class because a C function pointer can carry nothing else.
    ///
    /// It can be detached: a notice that was already on the run loop when the registration went away
    /// finds a closure that is gone and does nothing, which is cheaper than trying to arrange that no
    /// such notice exists.
    private final class Delivery: Sendable {
        private let handler: Mutex<(@Sendable (AXNotification) -> Void)?>

        init(_ handler: @escaping @Sendable (AXNotification) -> Void) {
            self.handler = Mutex(handler)
        }

        func detach() {
            handler.withLock { $0 = nil }
        }

        /// Anything but the two notifications of `AXNotification` is dropped: an app can post whatever
        /// it likes, and we registered for two things.
        func deliver(_ name: String) {
            guard let notification = AXNotification(rawValue: name) else { return }
            handler.withLock { $0 }?(notification)
        }
    }

    /// `@unchecked Sendable` because an `AXObserver` is a Core Foundation object that the compiler
    /// knows nothing about, and because this one is reached only under the mutex below.
    private struct Registration: @unchecked Sendable {
        var observer: AXObserver
        /// Retained by hand, because the retain the callback relies on is the one in the refcon.
        var context: UnsafeMutableRawPointer
    }

    private let state = Mutex<Registration?>(nil)

    public init() {}

    deinit {
        stop()
    }

    public func start(
        pid: pid_t,
        notifications: [AXNotification],
        _ fire: @escaping @Sendable (AXNotification) -> Void
    ) -> AXFault? {
        stop()
        var created: AXObserver?
        let result = AXObserverCreate(pid, Self.callback, &created)
        guard result == .success, let observer = created else { return AXFault(result) }

        let delivery = Unmanaged.passRetained(Delivery(fire))
        // The same wrapper `SystemAXWorld.application(pid:)` makes, and for the same reason: it talks to
        // nothing, so making one is cheaper than keeping one.
        let application = AXUIElementCreateApplication(pid)
        for notification in notifications {
            let added = AXObserverAddNotification(
                observer, application, notification.rawValue as CFString, delivery.toOpaque()
            )
            // Registering twice is what happens when an earlier registration was not torn down; the app
            // has the notification either way, which is all we wanted.
            guard added == .success || added == .notificationAlreadyRegistered else {
                // Nothing has been delivered: the source is not on a run loop yet.
                delivery.release()
                return AXFault(added)
            }
        }

        // `commonModes`, not `defaultMode`: a notice that waited for a menu or a window drag to finish
        // would arrive after the bar it was meant to stop.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        state.withLock { $0 = Registration(observer: observer, context: delivery.toOpaque()) }
        return nil
    }

    public func stop() {
        let context = state.withLock { registration -> UnsafeMutableRawPointer? in
            guard let current = registration else { return nil }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(current.observer), .commonModes)
            registration = nil
            return current.context
        }
        guard let context else { return }
        Unmanaged<Delivery>.fromOpaque(context).takeUnretainedValue().detach()
        // Let go of it on the main thread, behind whatever the run loop already holds, so that a notice
        // in flight reads a detached context rather than freed memory.
        DispatchQueue.main.async { Unmanaged<Delivery>.fromOpaque(context).release() }
    }

    private static let callback: AXObserverCallback = { _, _, notification, context in
        guard let context else { return }
        Unmanaged<Delivery>.fromOpaque(context).takeUnretainedValue().deliver(notification as String)
    }
}
