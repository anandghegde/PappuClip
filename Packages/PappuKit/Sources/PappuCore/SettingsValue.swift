import Foundation
import Synchronization

/// One remembered setting: decoded once, cached, written back when it changes, and able to tell the
/// program rather than waiting to be asked.
///
/// Most of the app reads settings by *asking* — `PrivacyGate` takes a closure so that a change lands on
/// the next attempt rather than at the next launch (architecture §4.4). A few things have to be *told*:
/// a pause that starts while a bar is up has to take that bar away (`privacyStateChanged`), and a
/// shortcut the user has just recorded has to be registered with the system. `onChange` is for those,
/// and it is the reason this is a class with observers rather than a computed property over storage.
///
/// `PauseStore` is deliberately not built on this. Settling a spent expiry is a rule of its own and it
/// owns a clock this has no use for (ACT-18).
public final class SettingsValue<Value: Codable & Sendable & Equatable>: Sendable {
    public let key: String

    private struct State {
        var cached: Value?
        var observers: [@Sendable (Value) -> Void] = []
    }

    private let fallback: Value
    private let storage: any SettingsStorage
    private let state: Mutex<State>

    public init(key: String, default fallback: Value, storage: any SettingsStorage) {
        self.key = key
        self.fallback = fallback
        self.storage = storage
        state = Mutex(State())
    }

    public var value: Value {
        state.withLock { current(&$0) }
    }

    /// What a caller that only reads holds, so that it never gets the setter by accident.
    public var reader: @Sendable () -> Value {
        { self.value }
    }

    public func set(_ new: Value) {
        // The comparison, the cache and the write happen under the lock so that two writers cannot
        // leave the cache saying one thing and the storage another. The observers are copied out and
        // called after the lock is given up: one of them registers a hotkey and another takes a bar
        // down, and neither should run with the settings held.
        let observers: [@Sendable (Value) -> Void]? = state.withLock { state in
            guard current(&state) != new else { return nil }
            state.cached = new
            write(new)
            return state.observers
        }
        guard let observers else { return }
        for observer in observers { observer(new) }
    }

    /// Change one field of a compound setting without reading it back first.
    public func update(_ change: (inout Value) -> Void) {
        var next = value
        change(&next)
        set(next)
    }

    /// Called on every change, in the order the observers were added, on whichever thread set the
    /// value. Nothing removes an observer: the app registers what it needs at launch and keeps it for
    /// the life of the process, and a token to unregister would be a lifetime to get wrong.
    public func onChange(_ body: @escaping @Sendable (Value) -> Void) {
        state.withLock { $0.observers.append(body) }
    }

    private func current(_ state: inout State) -> Value {
        if let cached = state.cached { return cached }
        let decoded = storage.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? fallback
        state.cached = decoded
        return decoded
    }

    private func write(_ new: Value) {
        // A setting that equals its default is stored as the absence of a value, so that a defaults
        // dump shows what the user changed and a later change of default reaches anyone who never
        // touched it.
        storage.set(new == fallback ? nil : try? JSONEncoder().encode(new), forKey: key)
    }
}
