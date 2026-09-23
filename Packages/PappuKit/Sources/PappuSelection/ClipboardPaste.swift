import Foundation
import PappuCore

/// How a paste transaction ended (RUN-4, architecture §5, §8.3).
///
/// The read path's promise is "the user's clipboard is the way we found it, or we say so". The write
/// path makes the same promise about a shorter and more dangerous moment: between the clear that puts
/// our text up and the restore that takes it down, the user's clipboard is *gone*, and the only reason
/// that is acceptable is that it is measured in milliseconds and always put back.
public enum ClipboardPasteOutcome: Sendable, Equatable {
    /// The text was held, the ⌘V was posted, and the user's clipboard is back. It does not say the app
    /// took it: a paste leaves no trace on the pasteboard and nothing can observe one.
    case pasted
    /// It never opened, and the pasteboard was not touched.
    case skipped(ClipboardRefusal)
    /// It opened and somebody else wrote while our text was up. The pasteboard is left as it stands,
    /// which is theirs and not the user's — the same rule as the read path, for the same reason.
    case abandoned(ClipboardAmbiguity)
}

/// One paste transaction as the inspector will tell it (DIA-2, DIA-4).
///
/// Counts, codes, identifiers and durations. `characters` is how long the text we held was; nothing
/// here says what it said, and the same `Mirror` walk that guards `InvocationRecord` guards this.
public struct ClipboardPasteRecord: Sendable, Equatable {
    public var transaction: ClipboardTransactionID
    public var invocation: InvocationID
    public var pid: pid_t?
    public var bundleID: String?
    public var outcome: ClipboardPasteOutcome?
    public var safety: [ClipboardSafetyEvent] = []
    /// How long the text we held was. Never what it said.
    public var characters: Int
    /// How many items and representations the user's clipboard held, and how big it was.
    public var snapshotItems: Int?
    public var snapshotRepresentations: Int?
    public var snapshotBytes: Int?
    /// Whether the ⌘V went out. False for a transaction that never got that far.
    public var posted = false
    /// How long the user's clipboard was ours. The number this whole design is about.
    public var held: Duration = .zero
    /// Whether the user's clipboard was put back. False means it was left with somebody else's write
    /// on it, and `safety` says which.
    public var restored = false
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

/// What `ClipboardBroker.paste` hands back. There is no text in it in either direction: the caller
/// supplied the text and the broker has nothing to tell it about it.
public struct ClipboardPasteResult: Sendable, Equatable {
    public let outcome: ClipboardPasteOutcome
    public let record: ClipboardPasteRecord

    init(outcome: ClipboardPasteOutcome, record: ClipboardPasteRecord) {
        self.outcome = outcome
        self.record = record
    }

    /// Whether the ⌘V went out with our text on the clipboard, which is as close to "it was pasted" as
    /// anything on this side of the seam can get.
    public var posted: Bool { record.posted }
}
