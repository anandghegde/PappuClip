import Foundation
import PappuAX
import PappuCore
import Synchronization

/// Posts the ⌘C of strategy 5 (ACT-10d).
public protocol SyntheticCopyPosting: Sendable {
    /// - Returns: False when the event could not be created or posted. Nothing was asked for, so nothing
    ///   can have been copied and there is nothing to put back.
    func postCopy() -> Bool
}

/// The one thing in PappuClip that writes to the user's clipboard (architecture §3.5, §5, ACT-10).
///
/// Everything it does is one transaction, and a transaction is a promise: *the user's clipboard is the
/// way we found it, or we say so*. The promise is kept by four rules, and each of them is a thing M0
/// spike 6 measured rather than a thing that seemed sensible:
///
/// 1. **A snapshot exists only when it is faithful.** A file promise or a representation that hands back
///    nothing means the transaction never opens (`PasteboardSnapshot.take`).
/// 2. **A change is ours only when it is the expected size and then stops.** The count moves when a
///    writer *clears*, not when it has written, so the count moving is not evidence of a finished write.
///    The settle is what turns it into evidence.
/// 3. **A change we cannot explain is not ours.** The pasteboard is left exactly as it stands, and the
///    transaction ends `ambiguous`. Restoring over a stranger's write is the one thing worse than losing
///    the user's clipboard to our own.
/// 4. **One transaction at a time**, and a transaction is not over when it has answered: the drain that
///    waits for a late copy is part of it.
///
/// ### The first-writer hole
///
/// Spike 6 found a case the pasteboard cannot close: a foreign write that lands *between* the ⌘C and
/// the app's own copy passes every attribution check, ten times out of ten. Four things are done about
/// it, none of which is a fix:
///
/// - the settle, which catches the common shape of it, a writer that is still going;
/// - `expectedCharacters`, which the reader supplies when an earlier strategy found a range it could not
///   read the text of. It is the only *positive* evidence available: if what is on the pasteboard is not
///   the length the selection was, the change is not ours;
/// - ACT-10j, which keeps strategy 5 off the automatic path for every unlisted app, so the residue
///   exists only where somebody has said this app is worth it, or on a route the user chose;
/// - and saying so. An ambiguous end is a recorded safety event, not a silent one.
///
/// ### Isolation
///
/// A plain actor on the cooperative pool, and deliberately not an `AXActor`-style dedicated queue: the
/// broker has to stay answerable while a transaction is open, so that a second caller is refused
/// promptly with `.brokerBusy` instead of queueing behind a sleeping actor and quietly spending the next
/// attempt's budget. Every call that can block goes out through `ClipboardScheduling.run(within:)`,
/// which runs it where it can be walked away from.
public actor ClipboardBroker {
    private let pasteboard: any PasteboardProviding
    private let input: any InputEpochReading
    private let copy: any SyntheticCopyPosting
    private let pasting: any SyntheticPastePosting
    private let scheduling: any ClipboardScheduling
    private let timing: ClipboardTiming
    private let ids = IDSource<ClipboardTransactionID>()

    /// True from the moment a transaction is admitted until its drain has finished. Set before the first
    /// `await`, so a second caller sees it (ACT-10c).
    private var isOpen = false

    /// Finished transactions, in order, complete with what the drain saw. For the inspector (DIA-2), and
    /// for tests, which need somewhere to wait for a drain that outlives the answer.
    public nonisolated let closed: AsyncStream<ClipboardTransactionRecord>
    private let closing: AsyncStream<ClipboardTransactionRecord>.Continuation

    public init(
        pasteboard: any PasteboardProviding,
        input: any InputEpochReading,
        copy: any SyntheticCopyPosting,
        pasting: any SyntheticPastePosting,
        scheduling: any ClipboardScheduling = SystemClipboardScheduling(),
        timing: ClipboardTiming = .initial
    ) {
        self.pasteboard = pasteboard
        self.input = input
        self.copy = copy
        self.pasting = pasting
        self.scheduling = scheduling
        self.timing = timing
        (closed, closing) = AsyncStream.makeStream(of: ClipboardTransactionRecord.self)
    }

    deinit {
        closing.finish()
    }

    /// Whether a transaction is open or still draining.
    public var isBusy: Bool { isOpen }

    /// Strategy 5 (ACT-9, ACT-10, architecture §5).
    ///
    /// - Parameters:
    ///   - permit: Consumed. Proof that this app's policy allows a simulated ⌘C on this route (ACT-10j).
    ///   - clock: The attempt's clock, never restarted, so the window is sized by what strategies 1–4
    ///     have already spent.
    ///   - expectedCharacters: The selection's length, when an earlier strategy found a range it could
    ///     not read the text of. It has to be a *fresh* reading of the selection and not ACT-14's
    ///     mouse-down baseline, which is from before the gesture and says nothing about what is selected
    ///     now. Nil when there is no such reading, and then the length check does not run.
    public func read(
        _ permit: consuming SyntheticCopyPermit,
        clock: AttemptClock,
        expectedCharacters: Int? = nil
    ) async -> ClipboardResult {
        let (attempt, route, target) = (permit.attempt, permit.route, permit.target)
        let expectedDelta = permit.expectedDelta
        let managerIsRunning = permit.clipboardManagerIsRunning
        var record = ClipboardTransactionRecord(
            transaction: ids.next(),
            attempt: attempt,
            route: route,
            target: target
        )
        record.expectedDelta = expectedDelta
        record.clipboardManagerIsRunning = managerIsRunning

        guard !isOpen else { return finish(&record, .skipped(.brokerBusy)) }
        let settle = timing.settle(managerIsRunning: managerIsRunning)
        let budget = clock.remaining(in: .stage(.read), on: .clipboardFallback)
        guard timing.window(within: budget, managerIsRunning: managerIsRunning) >= timing.minimumWindow else {
            return finish(&record, .skipped(.outOfBudget))
        }

        isOpen = true
        let started = scheduling.now

        let snapshot: PasteboardSnapshot
        switch await takeSnapshot(within: min(timing.snapshot, budget)) {
        case .success(let taken):
            snapshot = taken
        case .failure(let refusal):
            if refusal == .deadlineExpired { record.note(.readAbandoned) }
            isOpen = false
            return finish(&record, .skipped(ClipboardRefusal(refusal)), from: started)
        }
        record.snapshotItems = snapshot.items.count
        record.snapshotRepresentations = snapshot.representationCount
        record.snapshotBytes = snapshot.bytes

        // The snapshot was not free, so the window is sized from what is left now, not from what was
        // left when the transaction was admitted. Below the minimum there is no point posting a ⌘C we
        // could not watch the result of.
        let window = timing.window(
            within: clock.remaining(in: .stage(.read), on: .clipboardFallback),
            managerIsRunning: managerIsRunning
        )
        guard window >= timing.minimumWindow else {
            isOpen = false
            return finish(&record, .skipped(.outOfBudget), from: started)
        }

        // Keystrokes are invisible unless the key tap is up, and the window is exactly the moment a
        // keystroke could replace the selection (architecture §19 item 1). The watch is given back at
        // the answer; the drain does not need it, because the drain never trusts a change.
        let watch = input.watchInput()
        defer { watch?.stop() }
        if watch == nil { record.note(.inputUnwatched) }
        let epoch = input.inputEpoch

        guard copy.postCopy() else {
            isOpen = false
            return finish(&record, .skipped(.copyNotPosted), from: started)
        }
        record.phase = .awaitingCopy

        let postedAt = scheduling.now
        guard let moved = await waitForChange(from: snapshot.changeCount, within: window) else {
            // The count never moved: the app copied nothing, and nothing was written. The drain still
            // runs, because an app that was merely slow will land its copy on the user's clipboard with
            // nobody watching.
            record.phase = .watching
            let answered = finish(&record, .nothingCopied, from: started, keepOpen: true)
            drain(record, snapshot: snapshot, expecting: snapshot.changeCount, outstanding: expectedDelta, settle: settle)
            return answered
        }
        record.untilCopy = postedAt.duration(to: scheduling.now)

        record.phase = .settling
        let settled = await settleCount(from: moved, for: settle)
        record.observedDelta = settled - snapshot.changeCount
        if let ambiguity = attribution(
            delta: settled - snapshot.changeCount,
            expected: expectedDelta,
            restless: settled != moved,
            epoch: epoch,
            watched: watch != nil
        ) {
            return abandon(&record, ambiguity, from: started)
        }

        // The count moved on the clear, so there may be nothing readable there yet.
        let read = await readText(within: timing.textWait)
        if read.abandoned { record.note(.readAbandoned) }
        let text = read.text
        // No text is no evidence, in either direction: the check only fires on a length that disagrees.
        // Attribution has already passed by this point, so a pasteboard holding something unreadable is
        // still ours to put back.
        if let expectedCharacters, let text, text.count != expectedCharacters {
            return abandon(&record, .lengthMismatch, from: started)
        }
        record.phase = .captured
        record.characters = text?.count

        // The last look before the restore's two calls. Everything after this line is the gap ACT-10f is
        // about, and the gap cannot be made smaller — only reported.
        guard pasteboard.changeCount == settled else {
            record.note(.foreignWriteBeforeRestore)
            return abandon(&record, .restlessDuringSettle, from: started)
        }
        let report = snapshot.restore(to: pasteboard, expecting: settled)
        if report.destroyedANewerWrite { record.note(.destroyedANewerWrite) }
        record.restored = true
        record.phase = .watching

        let answered = finish(&record, text == nil ? .noText : .copied, text: text, from: started, keepOpen: true)
        // Nothing is outstanding now: the copy we asked for has been and gone, so anything the drain sees
        // belongs to somebody else and is left alone.
        drain(record, snapshot: snapshot, expecting: report.final, outstanding: nil, settle: settle)
        return answered
    }

    // MARK: Writing (RUN-4, architecture §8.3)

    /// Puts `text` on the user's clipboard, asks the app to paste it, and takes it back down.
    ///
    /// This is the other direction of the same promise, over a shorter and sharper moment: from the
    /// clear that puts our text up to the restore that takes it down, the user's clipboard *is gone*,
    /// and the only thing that makes that acceptable is that it is milliseconds long and always put
    /// back. Four things follow from that, and none of them is optional:
    ///
    /// 1. **No snapshot, no transaction.** If the user's clipboard cannot be read faithfully — a file
    ///    promise, a dead provider, `accessBehavior` that would prompt — nothing is written at all. An
    ///    action whose result cannot be pasted is offered for explicit copy instead (RUN-2c), which
    ///    costs the user a click; a clipboard replaced with no way to put it back costs them their
    ///    clipboard.
    /// 2. **The hold is blind.** A paste moves no change count and leaves no type behind, so there is
    ///    no signal that the app has taken the text. `ClipboardTiming.hold` is how long we wait anyway,
    ///    and it says **provisional** for exactly that reason. Too short and the app pastes the user's
    ///    own clipboard over their selection; too long and their clipboard is missing for no reason.
    /// 3. **A stranger's write wins.** If the count moves while our text is up, somebody else owns the
    ///    pasteboard and the restore does not run — the same rule as the read path (rule 3), and the
    ///    same recorded ambiguity rather than a silent one.
    /// 4. **A ⌘V that could not be posted takes the text straight back down.** Holding the user's
    ///    clipboard for a paste nobody was ever asked for is the one shape this must never take.
    ///
    /// The text is marked transient and concealed (ACT-10h): it is a value the user never copied, and a
    /// clipboard manager recording it would be a worse leak than the duplicate entry the markers exist
    /// to prevent.
    ///
    /// Verification is **not** this type's business and cannot be: RUN-2a is answered by
    /// `MutationPermit`, which `PappuRuntime.TextMutator` holds and this module cannot even name. What
    /// the broker guarantees is narrower and complete — that the user's clipboard survives the paste.
    public func paste(
        _ text: String,
        for invocation: InvocationID,
        into target: TargetApp
    ) async -> ClipboardPasteResult {
        await paste(content: [.text(text)], for: invocation, into: target)
    }

    /// The same paste, holding several representations of one value at once — plain text, HTML, RTF —
    /// for a script's `pasteContent` (JS-4). Everything above about the hold and the restore is true of
    /// it unchanged; the record counts the plain text's characters, or none.
    public func paste(
        content: [PasteboardRepresentation],
        for invocation: InvocationID,
        into target: TargetApp
    ) async -> ClipboardPasteResult {
        var record = ClipboardPasteRecord(
            transaction: ids.next(),
            invocation: invocation,
            target: target,
            characters: Self.characters(in: content)
        )
        guard !isOpen else { return finish(&record, .skipped(.brokerBusy)) }

        isOpen = true
        defer { isOpen = false }
        let started = scheduling.now

        let snapshot: PasteboardSnapshot
        switch await takeSnapshot(within: timing.snapshot) {
        case .success(let taken):
            snapshot = taken
        case .failure(let refusal):
            if refusal == .deadlineExpired { record.note(.readAbandoned) }
            return finish(&record, .skipped(ClipboardRefusal(refusal)), from: started)
        }
        record.snapshotItems = snapshot.items.count
        record.snapshotRepresentations = snapshot.representationCount
        record.snapshotBytes = snapshot.bytes

        // Putting our text up is a clear and a write, which is what a restore is, and the clear has the
        // same gap in front of it: a write that lands between the snapshot's count and this call is
        // destroyed by it. It cannot be closed, only noticed (ACT-10f).
        let cleared = pasteboard.clear()
        if cleared != snapshot.changeCount + 1 { record.note(.destroyedANewerWrite) }
        let ours = pasteboard.write([content + Self.markers])
        let putUp = scheduling.now

        guard pasting.postPaste() else {
            let ambiguity = takeDown(snapshot, expecting: ours, from: putUp, into: &record)
            return finish(&record, ambiguity.map { .abandoned($0) } ?? .skipped(.pasteNotPosted), from: started)
        }
        record.posted = true

        await scheduling.sleep(for: timing.hold)

        let ambiguity = takeDown(snapshot, expecting: ours, from: putUp, into: &record)
        return finish(&record, ambiguity.map { .abandoned($0) } ?? .pasted, from: started)
    }

    /// ACT-10h's two markers as representations, with no bytes behind them, which is the convention
    /// they are read by.
    private static let markers = PasteboardMarker.all.map { PasteboardRepresentation(type: $0, data: Data()) }

    /// Takes the held text back down, and says why it could not be.
    ///
    /// Shared by the ordinary ending and by the ⌘V that never went out, because the second case must
    /// give the clipboard back sooner rather than not at all.
    private func takeDown(
        _ snapshot: PasteboardSnapshot,
        expecting ours: Int,
        from putUp: ContinuousClock.Instant,
        into record: inout ClipboardPasteRecord
    ) -> ClipboardAmbiguity? {
        defer { record.held = putUp.duration(to: scheduling.now) }
        guard pasteboard.changeCount == ours else {
            record.note(.foreignWriteBeforeRestore)
            return .foreignWriteWhileHeld
        }
        let report = snapshot.restore(to: pasteboard, expecting: ours)
        if report.destroyedANewerWrite { record.note(.destroyedANewerWrite) }
        record.restored = true
        return nil
    }

    private func finish(
        _ record: inout ClipboardPasteRecord,
        _ outcome: ClipboardPasteOutcome,
        from started: ContinuousClock.Instant? = nil
    ) -> ClipboardPasteResult {
        record.outcome = outcome
        record.elapsed = started.map { $0.duration(to: scheduling.now) } ?? .zero
        return ClipboardPasteResult(outcome: outcome, record: record)
    }

    // MARK: Keeping (PRD §7.4)

    /// What is on the user's clipboard, as text.
    ///
    /// The one read here that opens nothing, clears nothing and writes nothing. It exists for the two
    /// built-ins that have to know what is on the clipboard before they act: Paste, whose visibility
    /// depends on there being text at all (`BuiltinConditions.clipboardHasText`), and ⇧ Paste, which
    /// pastes that text as plain.
    ///
    /// It goes out through `ClipboardScheduling.run(within:)` like every other call that can block: a
    /// lazy provider on somebody else's pasteboard is served by *their* main thread and can hang for as
    /// long as it likes (M0 spike 6 watched one for twelve seconds).
    ///
    /// - Returns: Nil when there is no text, when reading would prompt (architecture §19 item 3), or
    ///   when a transaction is open — during a paste's hold the pasteboard holds *our* text, and
    ///   answering with it would tell the caller the user's clipboard says something it does not.
    public func plainText() async -> String? {
        guard !isOpen, pasteboard.accessBehavior.readsWithoutAPrompt else { return nil }
        return await readText(within: timing.textWait).text
    }

    /// Puts `text` on the user's clipboard and leaves it there.
    ///
    /// **Not a transaction, on purpose.** The other two paths borrow the user's clipboard and promise to
    /// give it back; this one is the user asking for it to be replaced — Copy, or ⌥ Open Link's list of
    /// addresses. So there is no snapshot to take, nothing to restore, no attribution to make and no
    /// drain to sit through. Three consequences follow, and each is the opposite of the rule that holds
    /// everywhere else here:
    ///
    /// 1. **No markers.** `PasteboardMarker.transient` and `.concealed` are on the paste path because
    ///    the text there is a value the user never asked for and a clipboard manager recording it would
    ///    be a leak. Here the user pressed Copy, and a clipboard manager *should* have it.
    /// 2. **No `accessBehavior` check.** That property governs *reading* another app's clipboard, and
    ///    nothing is read: a write neither prompts nor is refused.
    /// 3. **The gap is still noticed.** A write that lands between the count check and `clear()` is
    ///    destroyed by it (ACT-10f), and that is as true of a write the user asked for as of a restore.
    ///    It cannot be closed, so it is recorded.
    ///
    /// What does carry over is the one-at-a-time rule: a write while a transaction is open would land on
    /// top of a snapshot that is about to be put back over it, so it is refused with `.brokerBusy`.
    public func write(
        _ text: String,
        for invocation: InvocationID,
        into target: TargetApp
    ) -> ClipboardWriteResult {
        write(content: [.text(text)], for: invocation, into: target)
    }

    /// The same write, of several representations of one value — a script's `copyContent` or
    /// `pasteboard.content` (JS-4, JS-7).
    public func write(
        content: [PasteboardRepresentation],
        for invocation: InvocationID,
        into target: TargetApp
    ) -> ClipboardWriteResult {
        var record = ClipboardWriteRecord(
            transaction: ids.next(),
            invocation: invocation,
            target: target,
            characters: Self.characters(in: content)
        )
        guard !isOpen else { return finish(&record, .skipped(.brokerBusy)) }

        let started = scheduling.now
        let before = pasteboard.changeCount
        let cleared = pasteboard.clear()
        if cleared != before + 1 { record.note(.destroyedANewerWrite) }
        _ = pasteboard.write([content])
        return finish(&record, .written, from: started)
    }

    /// What is on the user's clipboard, as each of `types` the first item has: a script's
    /// `pasteboard.content` (JS-7). On the same terms as `plainText()` — nil when reading would prompt,
    /// when a transaction is open, or when the read did not come back in time — and one item only, as
    /// PopClip reads it.
    public func content(types: [String]) async -> [String: Data]? {
        guard !isOpen, pasteboard.accessBehavior.readsWithoutAPrompt else { return nil }
        let box = Mutex<[String: Data]?>(nil)
        let pasteboard = pasteboard
        let finished = await scheduling.run(within: timing.textWait) {
            let listed = Set(pasteboard.itemTypes().first ?? [])
            var found: [String: Data] = [:]
            for type in types where listed.contains(type) {
                if let data = pasteboard.data(item: 0, type: type) { found[type] = data }
            }
            box.withLock { $0 = found }
        }
        guard finished else { return nil }
        return box.withLock { $0 }
    }

    /// How long the plain text among `content` is, for a record that counts and never keeps.
    private static func characters(in content: [PasteboardRepresentation]) -> Int {
        guard let plain = content.first(where: { $0.type == PasteboardRepresentation.plainText }) else { return 0 }
        return String(data: plain.data, encoding: .utf8)?.count ?? 0
    }

    private func finish(
        _ record: inout ClipboardWriteRecord,
        _ outcome: ClipboardWriteOutcome,
        from started: ContinuousClock.Instant? = nil
    ) -> ClipboardWriteResult {
        record.outcome = outcome
        record.elapsed = started.map { $0.duration(to: scheduling.now) } ?? .zero
        return ClipboardWriteResult(outcome: outcome, record: record)
    }

    // MARK: Waiting

    /// Polls until the count leaves `start`. Nil when it never did.
    private func waitForChange(from start: Int, within window: Duration) async -> Int? {
        let deadline = scheduling.now + window
        while true {
            let count = pasteboard.changeCount
            if count != start { return count }
            guard scheduling.now < deadline else { return nil }
            await scheduling.sleep(for: timing.poll)
        }
    }

    /// Waits `settle` out and returns where the count ended up. A caller that gets back what it put in
    /// knows the pasteboard was quiet for the whole of it.
    private func settleCount(from count: Int, for settle: Duration) async -> Int {
        let deadline = scheduling.now + settle
        var last = count
        while scheduling.now < deadline {
            await scheduling.sleep(for: timing.poll)
            last = pasteboard.changeCount
        }
        return last
    }

    /// Rules 2 and 3 as one function, so the race suite has one thing to aim at.
    private func attribution(
        delta: Int,
        expected: CopyDelta,
        restless: Bool,
        epoch: InputEpoch,
        watched: Bool
    ) -> ClipboardAmbiguity? {
        if restless { return .restlessDuringSettle }
        if !expected.contains(delta) { return .unexpectedDelta }
        if !watched { return .inputUnwatchable }
        if input.inputEpoch != epoch { return .userInputDuringWindow }
        return nil
    }

    // MARK: Reads that may block

    private func takeSnapshot(within limit: Duration) async -> Result<PasteboardSnapshot, SnapshotRefusal> {
        let box = Mutex<Result<PasteboardSnapshot, SnapshotRefusal>?>(nil)
        let pasteboard = pasteboard
        let ceiling = timing.ceilingBytes
        let finished = await scheduling.run(within: limit) {
            let result = PasteboardSnapshot.take(from: pasteboard, ceilingBytes: ceiling)
            box.withLock { $0 = result }
        }
        // An abandoned thread may fill the box long after this line. Nobody reads it again.
        guard finished, let result = box.withLock({ $0 }) else { return .failure(.deadlineExpired) }
        return result
    }

    /// - Returns: `abandoned` when the read did not come back inside its limit, which is a different
    ///   thing from a pasteboard with no text on it and is recorded as such: a thread was left behind in
    ///   somebody else's lazy provider, and `noText` would otherwise look like an ordinary image copy.
    private func readText(within limit: Duration) async -> (text: String?, abandoned: Bool) {
        let box = Mutex<String?>(nil)
        let pasteboard = pasteboard
        let finished = await scheduling.run(within: limit) {
            let text = pasteboard.text()
            box.withLock { $0 = text }
        }
        guard finished else { return (nil, true) }
        return (box.withLock { $0 }, false)
    }

    // MARK: The drain (architecture §5, ACT-10g)

    /// Keeps watching after the answer, and holds the slot while it does.
    ///
    /// Two things can still happen. The app's copy can land late, and then the user's clipboard has been
    /// replaced by their own selection with nobody watching — so the snapshot goes back over it. Or
    /// somebody else can write, and then the pasteboard is theirs and is left alone.
    ///
    /// Telling the two apart is the same attribution as before: `outstanding` is the delta the copy we
    /// asked for would move the count by, and nil once that copy has already been and gone. A finite
    /// drain is an incomplete one, which spike 6 says of any drain; what is left over is
    /// `lateCopyPossible`.
    private func drain(
        _ record: ClipboardTransactionRecord,
        snapshot: PasteboardSnapshot,
        expecting count: Int,
        outstanding: CopyDelta?,
        settle: Duration
    ) {
        Task {
            var record = record
            let deadline = scheduling.now + timing.drain
            while scheduling.now < deadline {
                await scheduling.sleep(for: timing.poll)
                let now = pasteboard.changeCount
                guard now != count else { continue }
                let settled = outstanding == nil ? now : await settleCount(from: now, for: settle)
                if let outstanding,
                   settled == now,
                   outstanding.contains(settled - count),
                   pasteboard.changeCount == settled {
                    let report = snapshot.restore(to: pasteboard, expecting: settled)
                    if report.destroyedANewerWrite { record.note(.destroyedANewerWrite) }
                    record.restored = true
                    record.note(.lateCopyRestored)
                } else {
                    record.note(.foreignWriteDuringDrain)
                }
                close(record)
                return
            }
            if outstanding != nil { record.note(.lateCopyPossible) }
            close(record)
        }
    }

    private func close(_ record: ClipboardTransactionRecord) {
        var record = record
        record.phase = .closed
        isOpen = false
        closing.yield(record)
    }

    // MARK: Endings

    private func abandon(
        _ record: inout ClipboardTransactionRecord,
        _ ambiguity: ClipboardAmbiguity,
        from started: ContinuousClock.Instant
    ) -> ClipboardResult {
        record.phase = .abandoned
        isOpen = false
        return finish(&record, .ambiguous(ambiguity), from: started)
    }

    /// Fills in the elapsed time and emits the record, unless the transaction goes on draining and will
    /// emit its own when it is really over.
    private func finish(
        _ record: inout ClipboardTransactionRecord,
        _ outcome: ClipboardOutcome,
        text: String? = nil,
        from started: ContinuousClock.Instant? = nil,
        keepOpen: Bool = false
    ) -> ClipboardResult {
        record.outcome = outcome
        record.elapsed = started.map { $0.duration(to: scheduling.now) } ?? .zero
        if case .skipped = outcome { record.phase = .skipped }
        let answer = ClipboardResult(outcome: outcome, text: outcome == .copied ? text : nil, record: record)
        if !keepOpen { closing.yield(record) }
        return answer
    }
}
