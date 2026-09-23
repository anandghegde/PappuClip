import PappuSelection
import Synchronization

/// Stands in for `CGEventTap`, which needs the Accessibility grant and a window server. A test plays
/// macOS: it refuses taps, sends input through them, switches them off and takes their ports away.
public final class FakeTapInstaller: TapInstalling {
    public final class Tap: InstalledTap {
        private struct State {
            var enabled = true
            var portIsGone = false
            var removed = false
        }

        private let state = Mutex(State())
        fileprivate let handler: TapHandler

        fileprivate init(handler: @escaping TapHandler) {
            self.handler = handler
        }

        public var isEnabled: Bool { state.withLock { $0.enabled && !$0.portIsGone && !$0.removed } }
        public var wasRemoved: Bool { state.withLock { $0.removed } }

        public func enable() {
            state.withLock { $0.enabled = true }
        }

        public func remove() {
            state.withLock { $0.removed = true }
        }

        /// What macOS does to a tap whose callback was slow. With `notifying`, it says so through the
        /// callback, as it does for a tap in use; without, the tap is just found off later.
        public func switchOff(notifying reason: TapInput.DisabledReason? = nil) {
            state.withLock { $0.enabled = false }
            if let reason { _ = handler(.disabled(reason)) }
        }

        /// After this, `enable()` does not bring the tap back.
        public func losePort() {
            state.withLock { $0.portIsGone = true }
        }
    }

    private struct State {
        var refused: Set<TapKind> = []
        var current: [TapKind: Tap] = [:]
        var installs: [TapKind: Int] = [:]
    }

    private let state = Mutex(State())

    public init(refusing refused: Set<TapKind> = []) {
        state.withLock { $0.refused = refused }
    }

    /// What a missing, given or withdrawn grant looks like from here.
    public func refuse(_ kinds: Set<TapKind>) {
        state.withLock { $0.refused = kinds }
    }

    public func install(_ kind: TapKind, handler: @escaping TapHandler) -> (any InstalledTap)? {
        state.withLock { state in
            guard !state.refused.contains(kind) else { return nil }
            let tap = Tap(handler: handler)
            state.current[kind] = tap
            state.installs[kind, default: 0] += 1
            return tap
        }
    }

    /// The latest tap of that kind, if it has not been removed.
    public func tap(_ kind: TapKind) -> Tap? {
        state.withLock { $0.current[kind] }.flatMap { $0.wasRemoved ? nil : $0 }
    }

    public func installCount(_ kind: TapKind) -> Int {
        state.withLock { $0.installs[kind, default: 0] }
    }

    /// Delivers input as the tap's thread would. Nil when no such tap exists, or it is switched off.
    @discardableResult
    public func send(_ input: TapInput, to kind: TapKind) -> TapDisposition? {
        guard let tap = tap(kind), tap.isEnabled else { return nil }
        return tap.handler(input)
    }
}
