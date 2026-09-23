import AppKit
import Foundation
import PappuCore
import Synchronization

/// Which apps are running, as bundle identifiers, every time that changes (ONB-6, ACT-10i, ACT-10j).
///
/// The whole set rather than the app that launched or quit: a notice can be missed or arrive twice, and
/// a set read afresh each time cannot drift the way a running count of launches and terminations can.
public protocol RunningApplicationsWatching: Sendable {
    /// Calls `fire` once with the apps running now, then again after every launch and termination.
    /// Calling `start` twice must not subscribe twice.
    func start(_ fire: @escaping @Sendable (Set<String>) -> Void)
    func stop()
}

/// `RunningApplicationsWatching` from `NSWorkspace`'s launch and termination notices.
///
/// Apps with no bundle identifier — command-line tools, some helpers — are left out. Nothing
/// `Coexistence` asks about is one of them.
public final class WorkspaceRunningApplicationsWatcher: RunningApplicationsWatching {
    private let tokens = Mutex<[any NSObjectProtocol]>([])

    public init() {}

    deinit {
        stop()
    }

    public func start(_ fire: @escaping @Sendable (Set<String>) -> Void) {
        let started = tokens.withLock { tokens -> Bool in
            guard tokens.isEmpty else { return false }
            let center = NSWorkspace.shared.notificationCenter
            tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
                .map { name in
                    center.addObserver(forName: name, object: nil, queue: .main) { _ in
                        fire(Self.running())
                    }
                }
            return true
        }
        // After subscribing, so that a launch between the read and the subscription is not lost: at
        // worst it is reported twice, and a second report of the same set changes nothing.
        if started { fire(Self.running()) }
    }

    public func stop() {
        tokens.withLock { tokens in
            for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            tokens = []
        }
    }

    private static func running() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}
