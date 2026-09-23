import Foundation
import PappuCore

/// How a *kept* write ended (PRD §7.4: the Copy built-in, and ⌥ Open Link).
///
/// There is no `abandoned` here, and its absence is the difference between this and every other
/// clipboard operation in the program. A read borrows the user's clipboard and a paste holds it for a
/// moment; both promise to put it back, and both can fail to keep that promise. A kept write is the
/// user asking for their clipboard to be *replaced*, so there is nothing to put back, nothing to
/// attribute and nothing to race for: the only way it does not happen is that it never started.
public enum ClipboardWriteOutcome: Sendable, Equatable {
    /// The text is on the clipboard and is staying there.
    case written
    /// Nothing was written and the pasteboard was not touched.
    case skipped(ClipboardRefusal)
}

/// One kept write as the inspector will tell it (DIA-2, DIA-4). Counts, codes and durations; never a
/// word of what was written.
public struct ClipboardWriteRecord: Sendable, Equatable {
    public var transaction: ClipboardTransactionID
    public var invocation: InvocationID
    public var pid: pid_t?
    public var bundleID: String?
    public var outcome: ClipboardWriteOutcome?
    public var safety: [ClipboardSafetyEvent] = []
    /// How long the text was. Never what it said.
    public var characters: Int
    public var elapsed: Duration = .zero

    public init(
        transaction: ClipboardTransactionID,
        invocation: InvocationID,
        target: TargetApp,
        characters: Int
    ) {
        self.transaction = transaction
        self.invocation = invocation
        self.pid = target.pid
        self.bundleID = target.bundleID
        self.characters = characters
    }

    mutating func note(_ event: ClipboardSafetyEvent) {
        guard !safety.contains(event) else { return }
        safety.append(event)
    }
}

public struct ClipboardWriteResult: Sendable, Equatable {
    public let outcome: ClipboardWriteOutcome
    public let record: ClipboardWriteRecord

    init(outcome: ClipboardWriteOutcome, record: ClipboardWriteRecord) {
        self.outcome = outcome
        self.record = record
    }

    public var written: Bool { outcome == .written }
}
