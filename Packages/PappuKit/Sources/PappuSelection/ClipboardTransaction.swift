import Foundation
import PappuCore

/// Where a clipboard transaction is (architecture §5).
///
/// The two states M0 spike 6 added are `settling` and `watching`. `settling` is the pause between the
/// change count reaching the expected delta and believing it, and it is what closes most of the
/// first-writer hole. `watching` is the state the old diagram was missing: after the restore there is
/// still a drain to sit through, because an app that was slow to copy can land one after we have
/// answered.
public enum ClipboardPhase: String, Sendable, Codable, CaseIterable {
    /// Reading the user's clipboard, before anything has been touched.
    case snapshotting
    /// The ⌘C is out; watching the change count.
    case awaitingCopy
    /// The count reached the expected delta; waiting to see whether it moves again.
    case settling
    /// The change is ours, and the text has been read.
    case captured
    /// Answered, still watching for a late copy or a foreign write. A transaction that got this far
    /// wrote the user's clipboard back — there is no separate `restored` phase, because the restore is
    /// two calls in the middle of this state's first instant and `restored` on the record says whether
    /// they happened.
    case watching
    /// Over. The slot is free.
    case closed
    /// Never opened. The pasteboard was not touched.
    case skipped
    /// Something else was writing. The pasteboard was left as it stood, which may not be how the
    /// transaction found it.
    case abandoned
}

/// Why a transaction never opened (ACT-10b, ACT-10c). Nothing was written and nothing was lost.
public enum ClipboardRefusal: String, Sendable, Codable, CaseIterable {
    /// Another transaction is open, or is still draining (ACT-10c). One at a time, always: two
    /// overlapping transactions hold two snapshots, and the second restore would undo the first.
    case brokerBusy
    /// Not enough of the read stage left to post a ⌘C and see what it did.
    case outOfBudget
    /// `NSPasteboard.accessBehavior` would prompt or refuse (architecture §19 item 3).
    case accessNotAllowed
    /// A file promise: bytes that do not exist yet and cannot be put back.
    case filePromise
    /// A representation that lists a type and hands back nothing.
    case unreadableRepresentation
    /// Past the memory ceiling.
    case tooLarge
    /// The snapshot did not come back in time, so an app is sitting on a lazy provider.
    case snapshotAbandoned
    /// The ⌘C could not be posted at all. Nothing was asked for, so nothing can have been copied.
    case copyNotPosted
    /// The ⌘V could not be posted at all (RUN-4). The held text comes straight back down: holding the
    /// user's clipboard for a paste that was never asked for is the one thing a write transaction must
    /// not do.
    case pasteNotPosted

    init(_ refusal: SnapshotRefusal) {
        self = switch refusal {
        case .accessNotAllowed: .accessNotAllowed
        case .filePromise: .filePromise
        case .unreadableRepresentation: .unreadableRepresentation
        case .tooLarge: .tooLarge
        case .deadlineExpired: .snapshotAbandoned
        }
    }
}

/// Why a change on the pasteboard could not be attributed to our own ⌘C (ACT-10f, spike 6).
///
/// Every one of these ends the transaction the same way: **the pasteboard is left alone**. Not restored
/// — restoring would destroy whatever the other writer put there, and a write we cannot explain is more
/// likely to be somebody else's than ours. The cost is the user's clipboard holding their selection;
/// the alternative is their clipboard holding something neither of us meant, and that is worse.
public enum ClipboardAmbiguity: String, Sendable, Codable, CaseIterable {
    /// The count moved further than this app's `CopyDelta` allows.
    case unexpectedDelta
    /// The count moved again during the settle, so at least two writers are involved.
    case restlessDuringSettle
    /// The user pressed a key or moved the mouse during the window, so the change may be theirs and the
    /// selection may no longer be the one we asked about.
    case userInputDuringWindow
    /// Keystrokes could not be watched at all — the key tap was refused — so the window cannot be said
    /// to have been quiet (RUN-2g).
    case inputUnwatchable
    /// The reader offered the selection's length from the Accessibility tree and the pasteboard does not
    /// match it. This is the only check that can catch a foreign write which arrived *before* our copy
    /// and moved the count by exactly one.
    case lengthMismatch
    /// Somebody else wrote while our text was on the clipboard for a paste (RUN-4). Theirs is the newest
    /// and is left alone, so the user's own clipboard is not put back either — which is the trade the
    /// read path makes too, and is why an abandoned transaction is always a recorded safety event.
    case foreignWriteWhileHeld
}

/// Things worth telling the user about afterwards, whatever the outcome (DIA-2).
///
/// These are not failures of the transaction. They are the places where the pasteboard's own design
/// leaves PappuClip no choice, written down so that the inspector can show them and the M1 exit can be
/// argued about with numbers instead of intentions.
public enum ClipboardSafetyEvent: String, Sendable, Codable, CaseIterable {
    /// A write landed between the count check and `clearContents()`, and clearing destroyed it. Spike 6
    /// measured the gap at 0.13–0.15 ms idle and 0.36 ms contended, and found no way to close it — only
    /// this, which is comparing what clearing returned against the count we expected (ACT-10f).
    case destroyedANewerWrite
    /// A write arrived after the capture and before the restore. The restore was not attempted, so the
    /// user's clipboard is still gone and the other writer's content is what is there.
    case foreignWriteBeforeRestore
    /// A write arrived during the drain and was left alone.
    case foreignWriteDuringDrain
    /// The app's copy arrived after the window had closed, and the snapshot was put back over it.
    case lateCopyRestored
    /// The drain ended with a copy still outstanding. If it lands now, the selection stays on the user's
    /// clipboard: the hole spike 6 says no finite drain can close.
    case lateCopyPossible
    /// A read was abandoned inside its deadline and its thread was left behind.
    case readAbandoned
    /// The transaction ran without being able to see keystrokes.
    case inputUnwatched
}

/// What one transaction came to.
public enum ClipboardOutcome: Sendable, Equatable {
    /// The change was ours and the text was read. The user's clipboard is back, unless a safety event
    /// says otherwise.
    case copied
    /// The count never moved: the app copied nothing. An empty selection, or an app that ignores ⌘C.
    /// The pasteboard was never written to.
    case nothingCopied
    /// The change was ours and no text came back — the pasteboard holds something that is not text, or
    /// the read was abandoned. The clipboard was still put back.
    case noText
    /// It never opened.
    case skipped(ClipboardRefusal)
    /// It opened and could not be trusted. See `ClipboardAmbiguity`.
    case ambiguous(ClipboardAmbiguity)
}

/// One transaction as the inspector will tell it (DIA-2, DIA-4).
///
/// Codes, identifiers, counts and durations, exactly as `AttemptRecord`. `characters` says how much text
/// came back and nothing anywhere says what it was; `types` counts representations and does not name
/// them, because a type name can be specific enough to identify the app the user copied from. A test
/// walks a whole record to prove it.
public struct ClipboardTransactionRecord: Sendable, Equatable {
    public var transaction: ClipboardTransactionID
    public var attempt: AttemptID
    public var route: ActivationRoute
    public var pid: pid_t?
    public var bundleID: String?
    public var phase: ClipboardPhase
    public var outcome: ClipboardOutcome?
    public var safety: [ClipboardSafetyEvent] = []
    /// What the app was allowed to move the count by.
    public var expectedDelta: CopyDelta?
    /// What it did move it by, once settled.
    public var observedDelta: Int?
    /// How many items and representations the snapshot held, and how big it was.
    public var snapshotItems: Int?
    public var snapshotRepresentations: Int?
    public var snapshotBytes: Int?
    public var restored = false
    /// How much text came back. Never what it said.
    public var characters: Int?
    /// Whether a clipboard manager was running, which is why the settle was as long as it was.
    public var clipboardManagerIsRunning = false
    /// From the ⌘C to the count moving. Nil when it never moved.
    public var untilCopy: Duration?
    /// From the start of the transaction to the answer. The drain is not in it.
    public var elapsed: Duration = .zero

    public init(
        transaction: ClipboardTransactionID,
        attempt: AttemptID,
        route: ActivationRoute,
        target: TargetApp,
        phase: ClipboardPhase = .snapshotting
    ) {
        self.transaction = transaction
        self.attempt = attempt
        self.route = route
        self.pid = target.pid
        self.bundleID = target.bundleID
        self.phase = phase
    }

    mutating func note(_ event: ClipboardSafetyEvent) {
        guard !safety.contains(event) else { return }
        safety.append(event)
    }
}

/// What `ClipboardBroker.read` hands back.
///
/// The text and the record are deliberately two things: everything above the broker takes the record
/// and may keep it, and only the strategy chain takes the text and it does not keep it (DIA-4).
public struct ClipboardResult: Sendable {
    public let outcome: ClipboardOutcome
    /// Non-nil only for `.copied`.
    public let text: String?
    /// As it stood at the answer. The complete record, with the drain in it, arrives on
    /// `ClipboardBroker.closed`.
    public let record: ClipboardTransactionRecord

    init(outcome: ClipboardOutcome, text: String? = nil, record: ClipboardTransactionRecord) {
        self.outcome = outcome
        self.text = text
        self.record = record
    }
}
