import Foundation
import Synchronization

/// One live registration, as the service holds it.
public protocol RegisteredHotkey: AnyObject, Sendable {
    /// Unregistering twice must be harmless.
    func unregister()
}

/// The seam between the service and `RegisterEventHotKey`: `SystemHotkeyRegistrar` in the app, a fake
/// in tests, which have no application event target for Carbon to deliver through.
public protocol HotkeyRegistering: Sendable {
    /// Nil when macOS will not have the combination, which in practice means another app holds it.
    func register(_ shortcut: HotkeyShortcut, handler: @escaping @Sendable () -> Void) -> (any RegisteredHotkey)?
}

/// Holds the one global shortcut of ACT-5: at most one combination is registered at a time, and none
/// while the user has not chosen one. Nothing here reads a selection or consults the gate — a press is
/// an activation route like a gesture, and meets `PrivacyGate` afterwards, as every route does.
///
/// Driven from the main thread: settings is its only caller, and Carbon registers there (§4.1).
public final class HotkeyService: Sendable {
    public enum Outcome: Sendable, Equatable {
        case registered
        /// No shortcut is set, because none was asked for.
        case cleared
        /// ACT-5's rule refuses it. Nothing is registered; any earlier shortcut is gone.
        case notAShortcut
        /// Another app holds the combination. Nothing is registered.
        case taken
    }

    public struct Press: Sendable, Equatable {
        public var shortcut: HotkeyShortcut
        /// Read where the press arrives, so the attempt's clock starts at the press and any queueing
        /// counts against the budget (architecture §3.3).
        public var at: ContinuousClock.Instant

        public init(shortcut: HotkeyShortcut, at: ContinuousClock.Instant) {
            self.shortcut = shortcut
            self.at = at
        }
    }

    private struct State {
        var shortcut: HotkeyShortcut?
        var registration: (any RegisteredHotkey)?
    }

    /// In order, for a single consumer (the `ActivationCoordinator`).
    public let presses: AsyncStream<Press>

    private let registrar: any HotkeyRegistering
    private let continuation: AsyncStream<Press>.Continuation
    private let state = Mutex(State())

    public init(registrar: any HotkeyRegistering) {
        self.registrar = registrar
        (presses, continuation) = AsyncStream.makeStream(of: Press.self)
    }

    deinit {
        state.withLock { $0.registration }?.unregister()
        continuation.finish()
    }

    /// The combination in force, or nil when none is.
    public var current: HotkeyShortcut? { state.withLock { $0.shortcut } }

    /// Puts `shortcut` in force, or takes the current one out of force when it is nil. The old
    /// registration always goes first, so choosing the same combination again re-registers it rather
    /// than losing to itself.
    @discardableResult
    public func use(_ shortcut: HotkeyShortcut?) -> Outcome {
        // The call-outs stay outside the lock: `unregister` and `register` hop to the main thread.
        let old = state.withLock { state -> (any RegisteredHotkey)? in
            defer { (state.shortcut, state.registration) = (nil, nil) }
            return state.registration
        }
        old?.unregister()

        guard let shortcut else { return .cleared }
        guard shortcut.isUsableAsGlobalShortcut else { return .notAShortcut }
        // The handler holds the shortcut rather than reading it back, so a press that arrives while
        // the user is changing the shortcut still names the combination that was pressed.
        guard let registration = registrar.register(shortcut, handler: { [weak self] in
            self?.continuation.yield(Press(shortcut: shortcut, at: .now))
        }) else { return .taken }

        state.withLock { $0 = State(shortcut: shortcut, registration: registration) }
        return .registered
    }
}
