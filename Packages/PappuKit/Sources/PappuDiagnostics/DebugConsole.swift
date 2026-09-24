import Foundation
import Synchronization

/// One line in the Debug Console (DIA-1).
public struct ConsoleEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// `print()` or `console.log()`. The text is what was printed.
        case printed
        /// An extension's code would not load: its package would not read, or the helper refused it.
        /// The text is why.
        case loadFailed
        /// An action ran to the end. The text is what it returned, empty for nothing.
        case returned
        /// An action threw. The text is the message.
        case threw
        /// An action was stopped before it ended. No text.
        case stopped
        /// The JavaScript helper went away while this extension's code was running (SEC-1d). No text.
        case crashed
        /// The extension's code did not stop when asked, and the helper was restarted to stop it. No text.
        case hung
        /// The extension crashed the helper too often, and its code will not run again until the app
        /// restarts (SEC-1d). No text.
        case suspended
    }

    public let id: UInt64
    public let date: Date
    /// The extension's name, as the user knows it.
    public let source: String
    public let kind: Kind
    /// What the extension said, as it said it. The words around it are the window's, looked up by
    /// `kind`, so nothing here needs translating.
    public let text: String
}

/// What extensions said, most recent last, for the Debug Console window (DIA-1, architecture §13).
///
/// **In memory, bounded, and nowhere else.** Nothing here is written to disk or sent anywhere: a
/// script may print the selection, and the console is where the user who wrote it reads it back. The
/// oldest lines go once there are `capacity` of them.
///
/// Anyone may add from any thread; the window watches `changes()`.
public final class DebugConsole: Sendable {
    private struct State {
        var entries: [ConsoleEntry] = []
        var nextID: UInt64 = 0
        var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    public let capacity: Int
    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(capacity: Int = 2_000, now: @escaping @Sendable () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    public var entries: [ConsoleEntry] {
        state.withLock { $0.entries }
    }

    public func add(_ kind: ConsoleEntry.Kind, from source: String, _ text: String = "") {
        let date = now()
        let watchers = state.withLock { state in
            state.nextID += 1
            state.entries.append(ConsoleEntry(id: state.nextID, date: date, source: source, kind: kind, text: text))
            if state.entries.count > capacity { state.entries.removeFirst(state.entries.count - capacity) }
            return Array(state.watchers.values)
        }
        for watcher in watchers { watcher.yield() }
    }

    public func clear() {
        let watchers = state.withLock { state in
            state.entries.removeAll()
            return Array(state.watchers.values)
        }
        for watcher in watchers { watcher.yield() }
    }

    /// A signal each time the lines change. Coalesced: a burst of prints may be one signal.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.watchers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.watchers.removeValue(forKey: id) }
        }
        return stream
    }
}
