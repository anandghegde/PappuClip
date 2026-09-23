import Foundation
import PappuSelection
import Synchronization

/// Whether PopClip or a clipboard manager is running, kept current so that anything may ask at any
/// moment (ONB-6, ACT-10i, ACT-10j; architecture §13).
///
/// The half of ONB-6 the safety specification leans on, and the only half M1 has: while PopClip runs,
/// the automatic path gets no synthetic ⌘C, because two apps simulating ⌘C at one selection is the race
/// that loses the user's clipboard. The explanation and the offer to pause are M3's. The same reading
/// says whether a clipboard manager is running, which lengthens the broker's settle.
///
/// For the reason `FrontmostApp` gives: the coordinator and the strategy chain ask on an actor and
/// inside an attempt, where they cannot hop to the main thread, so what they are handed is a closure
/// over a stored value that the launch and termination notices keep current.
public final class CoexistenceMonitor: Sendable {
    private let watcher: any RunningApplicationsWatching
    private let state = Mutex(Coexistence.none)

    public init(watcher: any RunningApplicationsWatching = WorkspaceRunningApplicationsWatcher()) {
        self.watcher = watcher
    }

    deinit {
        watcher.stop()
    }

    public func start() {
        watcher.start { [weak self] running in self?.note(running) }
    }

    public func stop() {
        watcher.stop()
    }

    public var current: Coexistence { state.withLock { $0 } }

    /// Strongly, as `FrontmostApp.reader` is and for its reason: a reader that quietly went back to
    /// `.none` would switch strategy 5 back on beside PopClip.
    public var reader: @Sendable () -> Coexistence {
        { [self] in current }
    }

    private func note(_ running: Set<String>) {
        let next = Coexistence(running: running)
        state.withLock { $0 = next }
    }
}
