import Foundation
import PappuAnalysis
import Synchronization

/// What each process calls itself, in a world with no `NSWorkspace` to ask.
public final class FakeAppNames: AppNaming, Sendable {
    private let names: Mutex<[pid_t: String]>

    public init(_ names: [pid_t: String] = [:]) {
        self.names = Mutex(names)
    }

    public func set(_ name: String?, for pid: pid_t) {
        names.withLock { $0[pid] = name }
    }

    public func name(of pid: pid_t) -> String? {
        names.withLock { $0[pid] }
    }
}
