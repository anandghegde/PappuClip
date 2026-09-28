import Foundation
import Synchronization

/// What dynamic population did for one attempt (JS-13, JS-16, architecture §10.6), for the attempt
/// trace (DIA-2).
///
/// Codes, owners and counts, and never what a population function was given or offered: the owners
/// are local identities, which the trace already holds for approvals, and an action is counted, not
/// named.
public struct PopulationRecord: Sendable, Equatable {
    /// Why no population function was asked at all.
    public enum Skip: String, Sendable, Equatable {
        /// PRD §11.1: once the target budget is spent, a late bar is a static bar.
        case pastTargetBudget
        /// The population stage's deadline had passed before it began.
        case noTimeLeft
    }

    /// How one extension's population ended.
    public enum Outcome: Sendable, Equatable {
        /// It answered in time, with this many actions on the bar.
        case offered(Int)
        /// The helper was not running, or had not loaded the extension: skipped, and warmed for the next
        /// attempt (architecture §10.6).
        case cold
        /// No answer within its deadline. Whatever it answers later is dropped.
        case late
        /// It threw, returned something that is not actions, or the helper went away.
        case failed
        /// SEC-1d: the extension is suspended until the app restarts.
        case suspended
    }

    public struct Entry: Sendable, Equatable {
        /// The installed extension, as its local identity's text.
        public var owner: String
        public var outcome: Outcome

        public init(owner: String, outcome: Outcome) {
            self.owner = owner
            self.outcome = outcome
        }
    }

    public var skipped: Skip?
    public var entries: [Entry]
    /// How long population held the bar.
    public var elapsed: Duration

    public init(skipped: Skip? = nil, entries: [Entry] = [], elapsed: Duration = .zero) {
        self.skipped = skipped
        self.entries = entries
        self.elapsed = elapsed
    }

    /// Some extension was skipped because the helper was cold.
    public var sawColdHelper: Bool { entries.contains { $0.outcome == .cold } }
}

/// Where the bar's side leaves each attempt's `PopulationRecord` for the coordinator, which writes the
/// attempt's trace record after the bar has been shown. A few attempts are kept; an older one's record
/// has been read or never will be.
public final class PopulationLog: Sendable {
    private let capacity: Int
    private let records = Mutex<[(AttemptID, PopulationRecord)]>([])

    public init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    public func record(_ record: PopulationRecord, for attempt: AttemptID) {
        records.withLock { records in
            records.removeAll { $0.0 == attempt }
            records.append((attempt, record))
            if records.count > capacity { records.removeFirst(records.count - capacity) }
        }
    }

    /// The attempt's record, which is then forgotten.
    public func take(for attempt: AttemptID) -> PopulationRecord? {
        records.withLock { records in
            guard let index = records.firstIndex(where: { $0.0 == attempt }) else { return nil }
            return records.remove(at: index).1
        }
    }
}
