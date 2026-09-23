import Foundation
import Synchronization

public enum TapKind: Sendable, Hashable, CaseIterable {
    /// Left down, dragged, up and the scroll wheel. Never consumes.
    case mouse
    case keyDown
}

public enum TapDisposition: Sendable, Equatable {
    case pass
    /// The event goes no further. Only the key tap does this, for a bar's own keys (BAR-9).
    case consume
}

/// Runs on the tap's thread, between the user's input and the app it is meant for. It must return at once.
public typealias TapHandler = @Sendable (TapInput) -> TapDisposition

/// One installed tap, as the service sees it.
public protocol InstalledTap: AnyObject, Sendable {
    /// False once macOS has switched the tap off, and when its port is gone.
    var isEnabled: Bool { get }
    func enable()
    func remove()
}

/// The seam between the service and `CGEventTap`: `SessionTapInstaller` in the app, a fake in tests.
public protocol TapInstalling: Sendable {
    /// Nil when macOS refuses the tap, which is how a missing Accessibility grant shows up.
    func install(_ kind: TapKind, handler: @escaping TapHandler) -> (any InstalledTap)?
}

/// Owns the two taps of architecture §4.1: the mouse tap, up whenever PappuClip is not paused, and the
/// key-down tap, which exists only while somebody holds a `KeyTapLease` (ACT-19). Keeps both alive when
/// macOS switches them off (ACT-15).
public final class EventTapService: Sendable {
    public enum Output: Sendable, Equatable {
        case pointer(PointerEvent)
        /// A tap was off for a while, or had to be rebuilt, or could not be. Events may have gone by
        /// unseen, a mouse-up among them: reset the recogniser, and count it as input having happened.
        case interrupted
    }

    public enum TapHealth: Sendable, Equatable {
        /// Nobody wants this tap now: the service is stopped, or no lease is held.
        case notWanted
        case healthy
        case reenabled
        case rebuilt
        /// macOS will not create it. The grant is missing or was taken away.
        case refused
    }

    public struct HealthReport: Sendable, Equatable {
        public var mouse: TapHealth
        public var key: TapHealth
    }

    /// For the inspector and the tests. It holds counts and no event.
    public struct Status: Sendable, Equatable {
        public var mouseTapInstalled: Bool
        public var keyTapInstalled: Bool
        public var keyTapLeases: Int
        public var reenables: Int
        public var rebuilds: Int
    }

    /// Runs on the key tap's thread for every key-down while the lease is held. It must return at once.
    public typealias KeyHandler = @Sendable (KeyPress) -> TapDisposition

    private struct State {
        var running = false
        var mouseTap: (any InstalledTap)?
        var keyTap: (any InstalledTap)?
        var leases: [UInt64: KeyHandler] = [:]
        var lastLease: UInt64 = 0
        var reenables = 0
        var rebuilds = 0
    }

    /// In order, for a single consumer (the `ActivationCoordinator`).
    public let events: AsyncStream<Output>

    private let installer: any TapInstalling
    private let continuation: AsyncStream<Output>.Continuation
    private let state = Mutex(State())
    private let epoch = InputEpochCounter()

    public init(installer: any TapInstalling) {
        self.installer = installer
        (events, continuation) = AsyncStream.makeStream(of: Output.self)
    }

    deinit {
        state.withLock { state in
            state.mouseTap?.remove()
            state.keyTap?.remove()
        }
        continuation.finish()
    }

    public var status: Status {
        state.withLock { state in
            Status(
                mouseTapInstalled: state.mouseTap != nil,
                keyTapInstalled: state.keyTap != nil,
                keyTapLeases: state.leases.count,
                reenables: state.reenables,
                rebuilds: state.rebuilds
            )
        }
    }

    // MARK: The mouse tap

    /// Returns whether the mouse tap is in place. When it is refused the service still counts as started,
    /// and `checkHealth()` tries again, so a grant given later is picked up without a restart.
    @discardableResult
    public func start() -> Bool {
        state.withLock { state in
            state.running = true
            if state.mouseTap == nil { state.mouseTap = installer.install(.mouse, handler: handler(for: .mouse)) }
            return state.mouseTap != nil
        }
    }

    /// For pause. The key tap is not touched: it belongs to its leases, and pausing ends what holds them.
    public func stop() {
        state.withLock { state in
            state.running = false
            state.mouseTap?.remove()
            state.mouseTap = nil
        }
    }

    // MARK: The key tap (ACT-19)

    /// Installs the key-down tap if this is the first lease. Nil when macOS refuses the tap; the caller
    /// then has no view of the keyboard and must fail closed (RUN-2g).
    public func leaseKeyTap(_ handler: @escaping KeyHandler) -> KeyTapLease? {
        let id: UInt64? = state.withLock { state in
            if state.keyTap == nil { state.keyTap = installer.install(.keyDown, handler: self.handler(for: .keyDown)) }
            guard state.keyTap != nil else { return nil }
            state.lastLease += 1
            state.leases[state.lastLease] = handler
            return state.lastLease
        }
        return id.map { KeyTapLease(service: self, id: $0) }
    }

    fileprivate func release(lease id: UInt64) {
        state.withLock { state in
            guard state.leases.removeValue(forKey: id) != nil, state.leases.isEmpty else { return }
            state.keyTap?.remove()
            state.keyTap = nil
        }
    }

    // MARK: Health (ACT-15)

    /// To be called on wake, when the session becomes active and when the app is activated. No timer
    /// polls the taps: a tap that macOS switches off while in use says so through its own callback.
    @discardableResult
    public func checkHealth() -> HealthReport {
        let report = state.withLock { state in
            let mouse = check(state.mouseTap, kind: .mouse, wanted: state.running)
            let key = check(state.keyTap, kind: .keyDown, wanted: !state.leases.isEmpty)
            (state.mouseTap, state.keyTap) = (mouse.tap, key.tap)
            for health in [mouse.health, key.health] {
                if health == .reenabled { state.reenables += 1 }
                if health == .rebuilt { state.rebuilds += 1 }
            }
            return HealthReport(mouse: mouse.health, key: key.health)
        }
        let undisturbed: [TapHealth] = [.healthy, .notWanted]
        if !undisturbed.contains(report.mouse) || !undisturbed.contains(report.key) {
            continuation.yield(.interrupted)
        }
        return report
    }

    /// Returns the tap that is in place afterwards, which is a new one if the old one's port was gone.
    private func check(_ tap: (any InstalledTap)?, kind: TapKind, wanted: Bool) -> (tap: (any InstalledTap)?, health: TapHealth) {
        guard wanted else { return (tap, .notWanted) }
        if let tap {
            if tap.isEnabled { return (tap, .healthy) }
            tap.enable()
            if tap.isEnabled { return (tap, .reenabled) }
            // Its port is gone. A new tap is the only way back.
            tap.remove()
        }
        let rebuilt = installer.install(kind, handler: handler(for: kind))
        return (rebuilt, rebuilt == nil ? .refused : .rebuilt)
    }

    // MARK: On the tap's thread

    private func handler(for kind: TapKind) -> TapHandler {
        // Weak, because the installer keeps the handler for as long as the tap exists.
        { [weak self] input in self?.handle(input, from: kind) ?? .pass }
    }

    private func handle(_ input: TapInput, from kind: TapKind) -> TapDisposition {
        switch input {
        case .pointer(let event):
            // A down or a scroll is the user starting something new; a drag or an up is the middle and
            // the end of what the down already counted (architecture §3.4). Our own posted events never
            // reach here: `TapInput.init(type:event:ownTag:)` drops them.
            if event.kind == .down || event.kind == .scroll { epoch.advance() }
            continuation.yield(.pointer(event))
            return .pass
        case .keyDown(let press):
            epoch.advance()
            let handlers = state.withLock { Array($0.leases.values) }
            // Every holder sees every key: one may be a bar and another an invocation watching for input.
            let consumed = handlers.reduce(false) { $1(press) == .consume || $0 }
            return consumed ? .consume : .pass
        case .disabled:
            // Events went by unseen, so input may have happened. Counting it is the honest reading:
            // whoever is comparing epochs should decide it is not safe rather than that it was quiet.
            epoch.advance()
            let tap = state.withLock { state in
                state.reenables += 1
                return kind == .mouse ? state.mouseTap : state.keyTap
            }
            tap?.enable()
            continuation.yield(.interrupted)
            return .pass
        }
    }
}

/// The input epoch of architecture §3.4, from the only place that sees every event (ACT-19, ACT-10f).
///
/// The key-down tap exists only while a lease is held, so `watchInput()` takes one for the caller. A
/// listen-only lease consumes nothing: it is there to make keystrokes *visible*, which is what a
/// clipboard transaction needs during its window.
extension EventTapService: InputEpochReading {
    public var inputEpoch: InputEpoch { epoch.epoch }

    public func watchInput() -> (any InputWatch)? {
        leaseKeyTap { _ in .pass }
    }
}

/// Keeps the key-down tap installed. The tap goes when the last lease is released or dropped.
public final class KeyTapLease: Sendable, InputWatch {
    private let service: EventTapService
    private let id: UInt64

    fileprivate init(service: EventTapService, id: UInt64) {
        self.service = service
        self.id = id
    }

    /// Releasing twice is harmless.
    public func release() {
        service.release(lease: id)
    }

    public func stop() { release() }

    deinit {
        release()
    }
}
