import PappuSelection
import Synchronization

/// Stands in for `RegisterEventHotKey`, which needs a running application event loop to deliver
/// through. A test plays macOS: it refuses combinations another app is holding, and presses them.
public final class FakeHotkeyRegistrar: HotkeyRegistering {
    public final class Registration: RegisteredHotkey {
        public let shortcut: HotkeyShortcut
        fileprivate let handler: @Sendable () -> Void
        private let gone = Atomic(false)

        fileprivate init(shortcut: HotkeyShortcut, handler: @escaping @Sendable () -> Void) {
            self.shortcut = shortcut
            self.handler = handler
        }

        public var isRegistered: Bool { !gone.load(ordering: .relaxed) }

        /// Calls the handler whether or not the registration still stands, which is what a press macOS
        /// had already dispatched when the holder went away amounts to.
        public func fire() {
            handler()
        }

        public func unregister() {
            gone.store(true, ordering: .relaxed)
        }
    }

    private struct State {
        var taken: Set<HotkeyShortcut> = []
        var live: Registration?
        var registrations = 0
    }

    private let state = Mutex(State())

    public init(taken: Set<HotkeyShortcut> = []) {
        state.withLock { $0.taken = taken }
    }

    /// What another app already holding a combination looks like from here.
    public func markTaken(_ shortcuts: Set<HotkeyShortcut>) {
        state.withLock { $0.taken = shortcuts }
    }

    public func register(
        _ shortcut: HotkeyShortcut,
        handler: @escaping @Sendable () -> Void
    ) -> (any RegisteredHotkey)? {
        state.withLock { state in
            guard !state.taken.contains(shortcut) else { return nil }
            let registration = Registration(shortcut: shortcut, handler: handler)
            state.live = registration
            state.registrations += 1
            return registration
        }
    }

    /// The latest registration, if it has not been unregistered.
    public var registered: Registration? {
        state.withLock { $0.live }.flatMap { $0.isRegistered ? $0 : nil }
    }

    public var registrationCount: Int { state.withLock { $0.registrations } }

    /// Presses the registered combination, as macOS would. Returns false when nothing is registered,
    /// which is what a press of a shortcut nobody holds amounts to: it goes to the app in front.
    @discardableResult
    public func press() -> Bool {
        guard let registration = registered else { return false }
        registration.handler()
        return true
    }
}
