import Foundation
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

// MARK: The scene

private let target = TargetApp(pid: 501, bundleID: "com.example.editor")
private let held = "the user's own clipboard"

private func broker(
    _ pasteboard: ScriptedPasteboard,
    timing: ClipboardTiming = .initial
) -> ClipboardBroker {
    ClipboardBroker(
        pasteboard: pasteboard,
        input: pasteboard,
        copy: pasteboard,
        pasting: pasteboard,
        scheduling: pasteboard,
        timing: timing
    )
}

/// The attempt's clock, on the pasteboard's virtual one. `spentMs` is what strategies 1–4 used up
/// before the fallback was reached, which is the only thing that shrinks the window.
private func attemptClock(_ pasteboard: ScriptedPasteboard, spentMs: Int = 0) -> AttemptClock {
    AttemptClock(start: pasteboard.now.advanced(by: .milliseconds(-spentMs)), now: pasteboard.reader)
}

/// A permit from a policy that allows strategy 5 on this route, so every test starts where the real
/// chain would: past ACT-10j. Minted the only way there is, through the store.
private func permit(
    delta: CopyDelta = .one,
    route: ActivationRoute = .hotkey,
    coexistence: Coexistence = .none,
    attempt: UInt64 = 1
) -> SyntheticCopyPermit {
    let policies = DetectionPolicies(
        default: DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: true,
            hotkeySyntheticCopy: true,
            quiescence: true,
            expectedCopyDelta: delta
        )
    )
    guard let permit = DetectionPolicyStore(policies).syntheticCopyPermit(
        attempt: AttemptID(rawValue: attempt),
        route: route,
        target: target,
        coexistence: coexistence
    ) else {
        preconditionFailure("this policy allows strategy 5 on \(route)")
    }
    return permit
}

/// The record as it stands when the transaction is really over, drain and all.
private func closedRecord(of broker: ClipboardBroker) async -> ClipboardTransactionRecord {
    for await record in broker.closed { return record }
    preconditionFailure("the broker closed its stream without closing the transaction")
}

/// Every string anywhere inside a value, for the DIA-2 walk.
private func strings(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    let mirror = Mirror(reflecting: value)
    guard !mirror.children.isEmpty else { return ["\(value)"] }
    return mirror.children.flatMap { strings(in: $0.value) }
}

// MARK: - The happy path

@Suite struct ClipboardBrokerTests {
    @Test func readsTheCopyAndPutsTheClipboardBack() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("selected words", at: .milliseconds(20))])
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .copied)
        #expect(result.text == "selected words")
        #expect(pasteboard.currentText == held)
        #expect(pasteboard.lastWriteWasMarked)
        #expect(pasteboard.copyPosts == 1)
        #expect(pasteboard.watches == 1)
        #expect(result.record.restored)
        #expect(result.record.observedDelta == 1)
        #expect(result.record.characters == 14)
        #expect(result.record.untilCopy != nil)
        #expect(result.record.snapshotItems == 1)

        let closed = await closedRecord(of: broker)
        #expect(closed.phase == .closed)
        #expect(closed.safety.isEmpty)
        #expect(await broker.isBusy == false)
    }

    /// The count moves on the *clear*, so at the moment it moves there is nothing readable there. The
    /// settle is what makes the text wait unnecessary in the common case — and the reason a broker that
    /// read the instant the count moved would come back empty on a real Mac.
    @Test func waitsForTextThatAppearsAfterTheCount() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("late bytes", at: .milliseconds(20))])
        pasteboard.set(textDelay: .milliseconds(25))
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .copied)
        #expect(result.text == "late bytes")
        #expect(pasteboard.currentText == held)
    }

    /// A length from an earlier strategy that agrees is the one piece of positive evidence available.
    @Test func acceptsALengthThatAgrees() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("twelve chars", at: .milliseconds(20))])
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard), expectedCharacters: 12)

        #expect(result.outcome == .copied)
        #expect(pasteboard.currentText == held)
    }

    /// An app that clears twice for one ⌘C is allowed to, if its policy says so — and the same script is
    /// ambiguous for an app whose policy says once.
    @Test func believesTheAppsOwnDelta() async {
        let script: [ScriptedPasteboard.Event] = [
            .copy("first", at: .milliseconds(20)),
            .foreignWrite("second", at: .milliseconds(20)),
        ]

        let tolerant = ScriptedPasteboard(text: held, script: script)
        let allowed = await broker(tolerant).read(permit(delta: .oneOrTwo), clock: attemptClock(tolerant))
        #expect(allowed.outcome == .copied)
        #expect(allowed.record.observedDelta == 2)
        #expect(tolerant.currentText == held)

        let strict = ScriptedPasteboard(text: held, script: script)
        let refused = await broker(strict).read(permit(delta: .one), clock: attemptClock(strict))
        #expect(refused.outcome == .ambiguous(.unexpectedDelta))
        #expect(refused.record.observedDelta == 2)
        // Left exactly as it stood: the user's clipboard is gone, but nothing of anybody else's was.
        #expect(strict.currentText == "second")
        #expect(strict.clears == 0)
    }

    // MARK: Nothing copied

    @Test func reportsNothingCopiedAndTouchesNothing() async {
        let pasteboard = ScriptedPasteboard(text: held)
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .nothingCopied)
        #expect(result.text == nil)
        #expect(result.record.untilCopy == nil)
        #expect(pasteboard.currentText == held)
        #expect(pasteboard.clears == 0)

        // A finite drain is an incomplete one, and the record says so rather than the transaction
        // claiming the pasteboard is safe.
        let closed = await closedRecord(of: broker)
        #expect(closed.safety == [.lateCopyPossible])
    }

    /// ACT-10g. The copy lands after the window has closed, so the user's clipboard has been replaced by
    /// their own selection with nobody watching. The drain is the only thing that can put it back.
    @Test func putsTheClipboardBackWhenTheCopyArrivesLate() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("slow app", at: .milliseconds(250))])
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))
        #expect(result.outcome == .nothingCopied)

        let closed = await closedRecord(of: broker)
        #expect(closed.safety == [.lateCopyRestored])
        #expect(closed.restored)
        #expect(pasteboard.currentText == held)
        #expect(pasteboard.lastWriteWasMarked)
    }

    /// The same drain, and a write that is not the copy we asked for. It is left alone: we have no claim
    /// on a pasteboard somebody else has written since.
    @Test func leavesAForeignWriteDuringTheDrainAlone() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [
            .copy("mine", at: .milliseconds(20)),
            .foreignWrite("theirs", at: .milliseconds(300)),
        ])
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))
        #expect(result.outcome == .copied)

        let closed = await closedRecord(of: broker)
        #expect(closed.safety == [.foreignWriteDuringDrain])
        #expect(pasteboard.currentText == "theirs")
        // One restore, the one at the answer. The drain did not write over the stranger.
        #expect(pasteboard.clears == 1)
    }

    // MARK: Attribution (rule 3: a change we cannot explain is not ours)

    /// A writer that is still going when the count first moves is the common shape of the first-writer
    /// hole, and the settle is what catches it.
    @Test func refusesWhenTheCountMovesAgainDuringTheSettle() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [
            .foreignWrite("somebody else", at: .milliseconds(5)),
            .copy("the selection", at: .milliseconds(20)),
        ])
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .ambiguous(.restlessDuringSettle))
        #expect(result.text == nil)
        #expect(result.record.phase == .abandoned)
        #expect(pasteboard.clears == 0)
    }

    /// A clipboard manager reads and often rewrites after every copy, so a quiet 30 ms says less and the
    /// settle is longer (ACT-10i). The same script is attributed one way and not the other.
    @Test func settlesForLongerWhenAClipboardManagerIsRunning() async {
        let script: [ScriptedPasteboard.Event] = [
            .copy("mine", at: .milliseconds(20)),
            .foreignWrite("the manager's rewrite", at: .milliseconds(80)),
        ]
        let managed = Coexistence(clipboardManagerIsRunning: true)

        let watched = ScriptedPasteboard(text: held, script: script)
        let careful = await broker(watched).read(permit(coexistence: managed), clock: attemptClock(watched))
        #expect(careful.outcome == .ambiguous(.restlessDuringSettle))
        #expect(careful.record.clipboardManagerIsRunning)

        // Without one the 30 ms settle is over before the rewrite, so the same write is only noticed
        // afterwards, by the drain.
        let unwatched = ScriptedPasteboard(text: held, script: script)
        let broker = broker(unwatched)
        let quick = await broker.read(permit(), clock: attemptClock(unwatched))
        #expect(quick.outcome == .copied)
        #expect(await closedRecord(of: broker).safety == [.foreignWriteDuringDrain])
    }

    /// Architecture §19 item 1. A keystroke during the window can replace the selection, so whatever is
    /// on the pasteboard may be an answer to a question nobody asked.
    @Test func refusesWhenTheUserTypedDuringTheWindow() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [
            .input(at: .milliseconds(10)),
            .copy("something", at: .milliseconds(20)),
        ])

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .ambiguous(.userInputDuringWindow))
        #expect(pasteboard.clears == 0)
    }

    /// RUN-2g. A refused key tap is not a quiet window; it is an unobserved one, and the difference is
    /// the whole reason this case is not treated as success.
    @Test func refusesWhenKeystrokesCannotBeWatched() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("something", at: .milliseconds(20))])
        pasteboard.set(keyTapIsAvailable: false)

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .ambiguous(.inputUnwatchable))
        #expect(result.record.safety == [.inputUnwatched])
        #expect(pasteboard.clears == 0)
    }

    // MARK: The first-writer hole (spike 6, 10/10)

    /// Written down as a failing-by-design case rather than left to be discovered: a foreign write that
    /// lands between the ⌘C and any copy passes every check the pasteboard can answer. The count moved
    /// once, it stayed still, the user typed nothing. There is nothing here to notice, and the record
    /// says nothing because there is nothing to say.
    @Test func cannotSeeAWriteThatArrivesBeforeTheCopy() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.foreignWrite("someone else's copy", at: .milliseconds(5))])

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .copied)
        #expect(result.text == "someone else's copy")
        #expect(result.record.safety.isEmpty)
        // The user's clipboard does come back. What is lost is the stranger's write, and what is wrong
        // is the text we hand on as if it were the selection.
        #expect(pasteboard.currentText == held)
    }

    /// And the one thing that closes it: a length the reader already knows from the Accessibility tree.
    /// It has to be a fresh reading of the selection — ACT-14's mouse-down baseline would say nothing
    /// about what is selected now.
    @Test func catchesTheFirstWriterWithALengthThatDisagrees() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.foreignWrite("someone else's copy", at: .milliseconds(5))])

        let result = await broker(pasteboard).read(
            permit(),
            clock: attemptClock(pasteboard),
            expectedCharacters: 5
        )

        #expect(result.outcome == .ambiguous(.lengthMismatch))
        #expect(result.text == nil)
        #expect(pasteboard.currentText == "someone else's copy")
        #expect(pasteboard.clears == 0)
    }

    // MARK: Refusals, which cost the user nothing

    @Test func refusesASecondTransactionWhileOneIsOpen() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("mine", at: .milliseconds(20))])
        let broker = broker(pasteboard)

        async let first = broker.read(permit(attempt: 1), clock: attemptClock(pasteboard))
        async let second = broker.read(permit(attempt: 2), clock: attemptClock(pasteboard))
        let outcomes = await [first.outcome, second.outcome]

        // Whichever got in first, exactly one was refused: two open transactions hold two snapshots,
        // and the second restore would undo the first (ACT-10c).
        #expect(outcomes.filter { $0 == .skipped(.brokerBusy) }.count == 1)
        #expect(pasteboard.copyPosts == 1)
        #expect(pasteboard.clears <= 1)
    }

    /// Below the minimum window the transaction would post a ⌘C it has no time to watch, which is worse
    /// than no bar: the clipboard replaced and nothing to show for it.
    @Test func refusesWhenThereIsNotEnoughOfTheReadStageLeft() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("mine", at: .milliseconds(20))])

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard, spentMs: 220))

        #expect(result.outcome == .skipped(.outOfBudget))
        #expect(result.record.phase == .skipped)
        #expect(pasteboard.copyPosts == 0)
        #expect(pasteboard.clears == 0)
    }

    @Test func refusesWhenTheCopyCannotBePosted() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(copyCanBePosted: false)

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .skipped(.copyNotPosted))
        #expect(pasteboard.clears == 0)
    }

    @Test func refusesWhenTheReadWouldPrompt() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(access: .ask)

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .skipped(.accessNotAllowed))
        #expect(pasteboard.copyPosts == 0)
    }

    /// M0 spike 6 watched a hung lazy provider for twelve seconds and could not cancel it. The snapshot
    /// is abandoned, the thread is left behind, and no ⌘C is posted: without a snapshot there is nothing
    /// to put back.
    @Test func refusesWhenTheSnapshotCannotBeTakenInTime() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("mine", at: .milliseconds(20))])
        pasteboard.set(readCost: .milliseconds(200))

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .skipped(.snapshotAbandoned))
        #expect(result.record.safety == [.readAbandoned])
        #expect(pasteboard.copyPosts == 0)
        #expect(pasteboard.clears == 0)
    }

    /// A text read that has to be walked away from is not the same thing as a pasteboard with no text on
    /// it, and the record keeps them apart. The clipboard still goes back: attribution passed.
    @Test func restoresEvenWhenTheTextReadIsAbandoned() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("unreachable", at: .milliseconds(20))])
        pasteboard.set(readCost: .milliseconds(60))

        let result = await broker(pasteboard).read(permit(), clock: attemptClock(pasteboard))

        #expect(result.outcome == .noText)
        #expect(result.text == nil)
        #expect(result.record.safety == [.readAbandoned])
        #expect(result.record.characters == nil)
        #expect(result.record.restored)
        #expect(pasteboard.currentText == held)
    }

    // MARK: DIA-2

    /// The inspector gets to show every one of these records, so a record that could hold a character of
    /// the selection would be a leak with a user interface on it.
    @Test func noRecordCanHoldTheSelection() async {
        let secret = "shibboleth quick brown fox"
        let pasteboard = ScriptedPasteboard(text: "her passphrase", script: [.copy(secret, at: .milliseconds(20))])
        let broker = broker(pasteboard)

        let result = await broker.read(permit(), clock: attemptClock(pasteboard))
        #expect(result.text == secret)

        let closed = await closedRecord(of: broker)
        for record in [result.record, closed] {
            let found = strings(in: record)
            #expect(!found.contains { $0.contains("shibboleth") || $0.contains("passphrase") })
            #expect(found.contains("com.example.editor"))
        }
        // The length is recorded, and is the only thing about the text that is.
        #expect(closed.characters == secret.count)
    }
}

// MARK: - Seeded interleavings

private let ours = "kestrel"
private let theirs = "starling"

/// One seeded world: what else happens, when, and which of the broker's knobs are set.
private struct Interleaving {
    var script: [ScriptedPasteboard.Event]
    var delta: CopyDelta
    var coexistence: Coexistence
    var textDelay: Duration
    var keyTapIsAvailable: Bool
    /// A write in the restore's unclosable gap (ACT-10f).
    var gapWrite: Bool

    init(seed: UInt64) {
        var rng = Seeded(state: seed)
        let actions: [ScriptedPasteboard.Action] = [.copy(ours), .foreignWrite(theirs), .clearOnly, .input]
        // Times run past the window and into the drain, so that a copy or a stranger can arrive at any
        // point in the transaction's life, including after it has answered.
        script = (0..<rng.int(in: 0...3)).flatMap { _ -> [ScriptedPasteboard.Event] in
            let at = Duration.milliseconds(rng.int(in: 0...24) * 20)
            let first = ScriptedPasteboard.Event(rng.pick(actions), at: at)
            // A third of the time, two of them land in the same instant. That is the one shape the
            // change count cannot take apart — it moves by two and neither write is identifiable — and
            // spreading times evenly would almost never produce it.
            guard rng.int(in: 0...2) == 0 else { return [first] }
            return [first, ScriptedPasteboard.Event(rng.pick(actions), at: at)]
        }
        delta = rng.pick([.one, .oneOrTwo])
        coexistence = Coexistence(clipboardManagerIsRunning: rng.bool())
        textDelay = .milliseconds(rng.int(in: 0...4))
        // Mostly available: an unwatchable window is refused early and has little left to explore.
        keyTapIsAvailable = rng.int(in: 0...3) > 0
        gapWrite = rng.bool()
    }
}

/// The exit criterion for the clipboard half of M1: over every interleaving, zero newer writes lost
/// without saying so and zero restores that were not attributed.
///
/// The scenarios above are the cases worth reading; this is the one that has to hold for all of them at
/// once. The properties are deliberately about *what was written*, not about which outcome came back —
/// a transaction is allowed to end any of five ways, and none of them may cost the user a clipboard
/// entry silently.
@Suite struct ClipboardRaceTests {
    /// One seed at a time rather than one `@Test` case each, so that the last thing this test does is
    /// check its own reach: a generator that stopped producing races would otherwise pass everything
    /// here for the worst possible reason.
    @Test func noInterleavingLosesAWriteWithoutSayingSo() async {
        var seen: Set<String> = []
        for seed in 0..<160 {
            seen.formUnion(await run(seed: seed))
        }

        for expected in [
            "copied", "nothingCopied", "noText",
            "ambiguous(unexpectedDelta)", "ambiguous(restlessDuringSettle)",
            "ambiguous(userInputDuringWindow)", "ambiguous(inputUnwatchable)",
            "safety(lateCopyRestored)", "safety(lateCopyPossible)",
            "safety(foreignWriteDuringDrain)", "safety(destroyedANewerWrite)",
        ] {
            #expect(seen.contains(expected), "no interleaving reached \(expected)")
        }
    }

    /// - Returns: Labels for what this interleaving reached, for the coverage check above.
    private func run(seed: Int) async -> Set<String> {
        let world = Interleaving(seed: 0xC11B_B0AD &+ UInt64(seed))
        let pasteboard = ScriptedPasteboard(text: held, script: world.script)
        pasteboard.set(textDelay: world.textDelay)
        pasteboard.set(keyTapIsAvailable: world.keyTapIsAvailable)
        if world.gapWrite { pasteboard.writeInRestoreGap("newer than us") }
        let broker = broker(pasteboard)

        let result = await broker.read(
            permit(delta: world.delta, coexistence: world.coexistence),
            clock: attemptClock(pasteboard)
        )
        let record = await closedRecord(of: broker)
        let why = "seed \(seed): \(result.outcome), \(record.safety)"

        // One permit, one ⌘C, and at most one write to the user's clipboard. Two would mean two
        // snapshots were in play, and the second restore would undo the first.
        #expect(pasteboard.copyPosts <= 1, "\(why)")
        #expect(pasteboard.clears <= 1, "\(why)")
        #expect(pasteboard.brokerWrites.count <= 1, "\(why)")

        // Nothing the broker writes is ever anything but the user's own clipboard, marked so that a
        // clipboard manager does not record it a second time.
        if let written = pasteboard.brokerWrites.last {
            #expect(written.first?.first?.data == Data(held.utf8), "\(why)")
            #expect(pasteboard.lastWriteWasMarked, "\(why)")
        }
        #expect(pasteboard.brokerWrites.isEmpty == !record.restored, "\(why)")

        // Zero unattributed restores: a change we could not explain leaves the pasteboard exactly as it
        // stands, and a refusal never touches it at all.
        switch result.outcome {
        case .ambiguous:
            #expect(!record.restored, "\(why)")
            #expect(pasteboard.clears == 0, "\(why)")
        case .skipped:
            #expect(pasteboard.clears == 0, "\(why)")
            #expect(record.observedDelta == nil, "\(why)")
        case .copied, .noText:
            #expect(record.restored, "\(why)")
            #expect(world.delta.contains(record.observedDelta ?? -1), "\(why)")
        case .nothingCopied:
            #expect(record.untilCopy == nil, "\(why)")
        }

        // Zero newer writes lost in silence: the gap cannot be closed, so the only promise available is
        // that clearing over somebody's write is always noticed, and never reported when it did not
        // happen.
        #expect(
            record.safety.contains(.destroyedANewerWrite) == (world.gapWrite && record.restored),
            "\(why)"
        )

        // And none of it says what was copied (DIA-2).
        #expect(!strings(in: record).contains { $0.contains(ours) || $0.contains(theirs) }, "\(why)")

        let outcome = switch result.outcome {
        case .copied: "copied"
        case .noText: "noText"
        case .nothingCopied: "nothingCopied"
        case .skipped(let refusal): "skipped(\(refusal.rawValue))"
        case .ambiguous(let ambiguity): "ambiguous(\(ambiguity.rawValue))"
        }
        return Set([outcome] + record.safety.map { "safety(\($0.rawValue))" })
    }
}
