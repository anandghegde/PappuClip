import AppKit
import Foundation
import PappuCore
import Synchronization

/// Which app came forward, as `NSWorkspace` says it (ACT-16a).
///
/// The notice `WorkspaceHealthTriggers` takes as "look at the taps again" is taken here as "the user is
/// somewhere else now". They are two readings of one notification and are kept apart, because the health
/// monitor wants every one of them and the attempt watcher wants the pid.
public final class WorkspaceActivationWatcher: ApplicationActivationWatching {
    private let token = Mutex<(any NSObjectProtocol)?>(nil)

    public init() {}

    deinit {
        stop()
    }

    public func start(_ fire: @escaping @Sendable (TargetApp) -> Void) {
        token.withLock { token in
            guard token == nil else { return }
            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                // Read here rather than passed on: `NSRunningApplication` is a live object, and what the
                // watcher needs of it is two values.
                fire(TargetApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier))
            }
        }
    }

    public func stop() {
        token.withLock { token in
            guard let current = token else { return }
            NSWorkspace.shared.notificationCenter.removeObserver(current)
            token = nil
        }
    }
}
