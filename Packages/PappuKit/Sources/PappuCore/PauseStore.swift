import Foundation
import Synchronization

/// Where the small, scriptable, local settings live (architecture §14).
///
/// A protocol rather than `UserDefaults` directly, so a test can hold one in memory and so the pause
/// state is not reachable by key from anywhere that has not been given the store.
public protocol SettingsStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// `UserDefaults` behind the protocol. Unchecked because `UserDefaults` is documented as thread-safe
/// but is not annotated for it.
public struct UserDefaultsStorage: SettingsStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Pause, as the menu bar sets it and every route reads it (ACT-18).
///
/// Reading settles a spent expiry and writes the settled value back, so a relaunch an hour later finds
/// `.running` rather than a date in the past, and the menu never has to show a pause that is over.
/// Nothing here schedules a timer; the menu re-reads when it opens and the gate on every attempt.
public final class PauseStore: Sendable {
    public static let storageKey = "privacy.pause"

    private let storage: any SettingsStorage
    private let now: @Sendable () -> Date
    private let cache = Mutex<PauseState?>(nil)

    public init(storage: any SettingsStorage, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.now = now
    }

    /// The pause state as it stands, with a spent expiry already turned back into `.running`.
    public var current: PauseState {
        let settled = stored().settled(at: now())
        set(settled)
        return settled
    }

    public func isPaused() -> Bool { current.isPaused(at: now()) }

    /// The menu's three commands (ACT-18).
    public func pauseForOneHour() { set(.forOneHour(from: now())) }
    public func pauseUntilResumed() { set(.untilResumed) }
    public func resume() { set(.running) }

    private func stored() -> PauseState {
        cache.withLock { cache in
            if let cache { return cache }
            let state = storage.data(forKey: Self.storageKey)
                .flatMap { try? JSONDecoder().decode(PauseState.self, from: $0) } ?? .running
            cache = state
            return state
        }
    }

    private func set(_ state: PauseState) {
        cache.withLock { cache in
            guard cache != state else { return }
            cache = state
            // `.running` is the absence of a pause, so it is stored as the absence of a value.
            storage.set(state == .running ? nil : try? JSONEncoder().encode(state), forKey: Self.storageKey)
        }
    }
}
