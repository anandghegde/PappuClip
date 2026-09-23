import AppKit
import Foundation
import Synchronization

/// The three notices of architecture §4.1, as `NSWorkspace` posts them.
///
/// They come from the workspace's own notification centre, not the default one. Nothing is scheduled
/// and nothing polls: between these and the tap's own disabled callback, every way a tap can go away
/// is covered (ACT-15).
public final class WorkspaceHealthTriggers: HealthTriggering {
    private static let notices: [(name: Notification.Name, trigger: HealthTrigger)] = [
        (NSWorkspace.didWakeNotification, .wake),
        (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        (NSWorkspace.didActivateApplicationNotification, .applicationActivated),
    ]

    private let tokens = Mutex<[any NSObjectProtocol]>([])

    public init() {}

    deinit {
        stop()
    }

    public func start(_ fire: @escaping @Sendable (HealthTrigger) -> Void) {
        tokens.withLock { tokens in
            guard tokens.isEmpty else { return }
            let center = NSWorkspace.shared.notificationCenter
            tokens = Self.notices.map { notice in
                center.addObserver(forName: notice.name, object: nil, queue: .main) { _ in fire(notice.trigger) }
            }
        }
    }

    public func stop() {
        tokens.withLock { tokens in
            let center = NSWorkspace.shared.notificationCenter
            for token in tokens { center.removeObserver(token) }
            tokens = []
        }
    }
}
