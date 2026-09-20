import AppKit
import CryptoKit
import PappuCore
import PappuHarness
import Synchronization

/// Spike 6: whether the clipboard transaction of architecture §5 stands on what `NSPasteboard` really does,
/// and whether `InputEpoch` can carry the quiescence tier (RUN-2).
///
/// What the design assumes, and this run checks:
/// 1. A moved change count means there is something to read. (architecture §5, "count advanced, attribution checks pass")
/// 2. A snapshot can copy every item and representation inside the read stage, lazily provided data
///    included, and a file promise can be told from the rest. (ACT-10a, ACT-10b)
/// 3. Writing a snapshot back gives the pasteboard the user had. (ACT-10e)
/// 4. "Restore only if the count still equals the value recorded at capture" keeps a newer copy safe. (ACT-10f)
/// 5. A drain window is enough to keep a late copy from being taken for a user copy. (ACT-16c)
/// 6. An app may read the general pasteboard without the user being asked. (architecture §19 item 3)
/// 7. An event tap counts every mouse-down, key-down and scroll, and can leave out the events we post. (architecture §3.4)
///
/// Everything up to 5 runs on a pasteboard of the spike's own, against a second process that plays the
/// source app, so nothing the user copied is touched. 6 reads the real clipboard, writes a probe and puts
/// back what was there. 7 and the run against a real app need permissions and the operator.
///
/// What it cannot check: which clipboard managers honour the transient and concealed markers (ACT-10i).
struct ClipboardSpike: Spike {
    let id = "spike-6-clipboard"
    let title = "6 · Clipboard ownership and quiescence"
    let question = """
        Clipboard transaction ownership and destination verification under delayed copy, concurrent user copy, \
        source edits and app switches. Validate the quiescence tier (RUN-2): how reliably the event tap and \
        frontmost-window checks detect intervening input, and what time window is safe.
        """
    let instructions = """
        The first run needs nobody: it works on a pasteboard of its own and, with "The real clipboard" on, reads \
        the clipboard once, writes a probe and puts back what was there. Leave the clipboard alone for those two \
        seconds. For "InputEpoch against real input", type, click and scroll in another app when the log asks. \
        For "A transaction against the frontmost app", run once per app: switch to it during the countdown and \
        select a sentence. The selected text is never recorded, only its length.
        """

    let options = [
        SpikeOption(
            id: Option.general, title: "The real clipboard",
            detail: "Reads NSPasteboard.general, writes a probe with pbcopy and puts back what was there. Off, only the private pasteboard is used.",
            defaultOn: true
        ),
        SpikeOption(
            id: Option.hung, title: "A provider that never answers",
            detail: "How long a snapshot is held up by lazy data whose owner hangs or has died. Adds up to 20 s.", defaultOn: true
        ),
        SpikeOption(
            id: Option.epoch, title: "InputEpoch against real input",
            detail: "Needs a tap, so Accessibility or Input Monitoring. Asks you to type, click and scroll for ten seconds.", defaultOn: true
        ),
        SpikeOption(
            id: Option.live, title: "A transaction against the frontmost app",
            detail: "Needs permission to post events. Sends ⌘C to the app in front five times and puts the clipboard back.", defaultOn: false
        ),
    ]

    private enum Option {
        static let general = "general"
        static let hung = "hung"
        static let epoch = "epoch"
        static let live = "live"
    }

    private static let visibilityRounds = 50
    private static let pollSamples = 1_000
    private static let snapshotRounds = 5
    private static let transactionRounds = 10
    private static let hungProviderSeconds = 20
    private static let hungReadLimit: Duration = .seconds(12)
    private static let generalReadLimit: Duration = .seconds(6)
    private static let operatorSeconds = 10
    private static let liveRounds = 5
    private static let liveCopyLimit: Duration = .seconds(1)
    private static let liveSettle: Duration = .milliseconds(300)
    private static let countdownSeconds = 8
    private static let keyC: CGKeyCode = 8

    func run(recorder: RunRecorder, enabled: Set<String>) {
        let permissions = PermissionSnapshot.current()
        recorder.setParameter("permissions", permissions.summary)
        changeCounts(recorder: recorder)
        pollCost(recorder: recorder)

        let name = "app.pappuclip.spike6.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        guard let fixture = FixtureProcess(pasteboardName: name) else {
            recorder.observe("fixture.starts", .inconclusive, "The second process did not come up, so nothing across processes was measured.")
            return
        }
        recorder.observe("fixture.starts", .info, "A second SpikeLab process (pid \(fixture.pid)) owns the pasteboard \(name).")

        visibility(pasteboard, fixture: fixture, recorder: recorder)
        snapshots(pasteboard, fixture: fixture, recorder: recorder)
        transactions(pasteboard, fixture: fixture, recorder: recorder)
        checkThenClear(pasteboard, fixture: fixture, recorder: recorder)
        if enabled.contains(Option.hung) {
            // Each of these kills its fixture, so they come last and the later ones start their own.
            deadOwner(pasteboard, fixture: fixture, typesReadFirst: false, recorder: recorder)
            if let next = FixtureProcess(pasteboardName: name) {
                deadOwner(pasteboard, fixture: next, typesReadFirst: true, recorder: recorder)
            }
            if let next = FixtureProcess(pasteboardName: name) {
                hungProvider(pasteboard, fixture: next, recorder: recorder)
            }
        } else {
            fixture.quit()
        }

        if enabled.contains(Option.general) { generalPasteboard(recorder: recorder) }
        sessionCounters(recorder: recorder)
        if enabled.contains(Option.epoch) { inputEpoch(permissions: permissions, recorder: recorder) }
        if enabled.contains(Option.live) { liveTransactions(permissions: permissions, recorder: recorder) }
    }

    // MARK: 1. What moves the change count

    private func changeCounts(recorder: RunRecorder) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var returned: [String: Int] = [:]
        let writes: [(String, () -> Void)] = [
            ("clearContents", { returned["clearContents"] = pasteboard.clearContents() - pasteboard.changeCount }),
            ("setString", { pasteboard.setString("a", forType: .string) }),
            ("setData", { pasteboard.setData(Data("a".utf8), forType: .rtf) }),
            ("writeObjects", { pasteboard.writeObjects(["b" as NSString]) }),
            ("declareTypes", { returned["declareTypes"] = pasteboard.declareTypes([.string], owner: nil) - pasteboard.changeCount }),
            ("addTypes", { pasteboard.addTypes([.html], owner: nil) }),
            ("prepareForNewContents", { pasteboard.prepareForNewContents(with: []) }),
            ("readString", { _ = pasteboard.string(forType: .string) }),
        ]
        var deltas: [String: Int] = [:]
        for (name, write) in writes {
            let before = pasteboard.changeCount
            write()
            deltas[name] = pasteboard.changeCount - before
            recorder.record("count.delta", unit: "count", labels: ["write": name], value: Double(deltas[name] ?? 0))
        }
        let clears = ["clearContents", "declareTypes", "prepareForNewContents"]
        let asExpected = deltas.allSatisfy { clears.contains($0.key) ? $0.value == 1 : $0.value == 0 }
        recorder.observe(
            "count.movesWhenClearedNotWhenWritten", asExpected ? .confirmed : .refuted,
            deltas.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                + ". The count says a writer has started, not that it has finished."
        )
        recorder.observe(
            "count.clearingReturnsTheNewCount", returned.values.allSatisfy { $0 == 0 } ? .confirmed : .refuted,
            "clearContents and declareTypes return the count they leave behind, which is how a writer learns whether it was alone."
        )
    }

    private func pollCost(recorder: RunRecorder) {
        let own = NSPasteboard.withUniqueName()
        defer { own.releaseGlobally() }
        for (label, pasteboard) in [("private", own), ("general", NSPasteboard.general)] {
            for _ in 0..<Self.pollSamples {
                recorder.measure("poll.changeCountRead", labels: ["pasteboard": label]) { _ = pasteboard.changeCount }
            }
        }
        let result = recorder.finish()
        let p95 = result.p95("poll.changeCountRead", labels: ["pasteboard": "general"]) ?? 0
        recorder.observe(
            "poll.isCheap", p95 < 0.1 ? .confirmed : .refuted,
            String(format: "Reading the general count: p95 %.4f ms. One read a millisecond for the whole %.0f ms fallback read stage is %.2f ms of work.",
                   p95, recorder.budgets.budget(for: .read, on: .clipboardFallback).milliseconds,
                   p95 * recorder.budgets.budget(for: .read, on: .clipboardFallback).milliseconds)
        )
    }

    // MARK: 2. When another process's write can be seen

    private func visibility(_ pasteboard: NSPasteboard, fixture: FixtureProcess, recorder: RunRecorder) {
        var emptyFirstReads: [String: Int] = [:]
        var rounds: [String: Int] = [:]
        var disagreements = 0
        let kinds = [("text", Self.visibilityRounds), ("declare", Self.visibilityRounds / 2), ("rich", Self.visibilityRounds / 2), ("gapped:20", 10)]
        for (kind, count) in kinds {
            let labels = ["write": kind]
            for round in 0..<count {
                let before = pasteboard.changeCount
                fixture.send("write 0 \(kind) visible-\(round)")
                // No sleep: this measures the pasteboard, not the poll interval.
                let limit = ContinuousClock.now + .seconds(2)
                while pasteboard.changeCount == before, ContinuousClock.now < limit {}
                let seen = PasteboardFixture.uptimeNanos()
                var firstReadWasEmpty = false
                while pasteboard.string(forType: .string) == nil, ContinuousClock.now < limit { firstReadWasEmpty = true }
                let readable = PasteboardFixture.uptimeNanos()
                guard let wrote = FixtureWrite(fixture.wait(for: "wrote", timeout: .seconds(3))) else { continue }
                rounds[kind, default: 0] += 1
                if firstReadWasEmpty { emptyFirstReads[kind, default: 0] += 1 }
                if wrote.changeCount != pasteboard.changeCount { disagreements += 1 }
                recorder.record("visibility.countSeenAfterTheClear", labels: labels, value: Self.milliseconds(from: wrote.cleared, to: seen))
                recorder.record("visibility.textReadableAfterTheCount", labels: labels, value: Self.milliseconds(from: seen, to: readable))
                recorder.record("fixture.clearToWritten", labels: labels, value: Self.milliseconds(from: wrote.cleared, to: wrote.end))
            }
        }
        let natural = kinds.map(\.0).filter { $0 != "gapped:20" }
        let early = natural.reduce(0) { $0 + (emptyFirstReads[$1] ?? 0) }
        let detail = kinds.map { "\($0.0) \(emptyFirstReads[$0.0] ?? 0)/\(rounds[$0.0] ?? 0)" }.joined(separator: ", ")
        recorder.observe(
            "attribution.theCountMovesBeforeTheTextIsThere", (emptyFirstReads["gapped:20"] ?? 0) > 0 ? .confirmed : .refuted,
            "Rounds where the first read after the count moved found no string: \(detail). "
                + "\(early) of those were writers that did nothing between clearing and writing. "
                + "\"Count moved, no text type\" is not yet \"the app copied something that is not text\"."
        )
        recorder.observe(
            "count.isTheSameInBothProcesses", disagreements == 0 ? .confirmed : .refuted,
            "\(disagreements) rounds where the writer's count after its write differed from the reader's."
        )
    }

    // MARK: 3. Snapshot and restore

    private func snapshots(_ pasteboard: NSPasteboard, fixture: FixtureProcess, recorder: RunRecorder) {
        let kinds = [
            "text", "rich", "multi", "transient", "fileURL", "big:1000000", "big:10000000", "big:50000000",
            "lazy:0:1000", "lazy:50:1000", "lazy:0:10000000", "promise",
        ]
        for kind in kinds {
            let labels = ["content": kind]
            var faithful = 0
            var rounds = 0
            var last: BrokerSnapshot?
            for round in 0..<Self.snapshotRounds {
                fixture.discardEvents()
                fixture.send("write 0 \(kind) snapshot-\(round)")
                guard fixture.wait(for: "wrote", timeout: .seconds(10)) != nil else { continue }
                let snapshot = recorder.measure("snapshot.take", labels: labels) { BrokerSnapshot(pasteboard) }
                recorder.record("snapshot.bytes", unit: "bytes", labels: labels, value: Double(snapshot.bytes))
                last = snapshot
                rounds += 1
                guard snapshot.isRestorable else { continue }
                recorder.measure("snapshot.restore", labels: labels) { _ = snapshot.restore(to: pasteboard, marked: false) }
                if BrokerSnapshot(pasteboard).fingerprint == snapshot.fingerprint { faithful += 1 }
            }
            guard let last else {
                recorder.observe("snapshot.roundTrips", .inconclusive, "The fixture never wrote it.", labels: labels)
                continue
            }
            let shape = "\(last.items.count) items, \(last.representationCount) representations, \(last.bytes) bytes, \(last.unreadable) unreadable"
            if kind == "promise" {
                recorder.observe(
                    "snapshot.seesAFilePromise", last.holdsPromise ? .confirmed : .refuted,
                    "\(shape). Types: \(last.items.flatMap { $0.map(\.type) }.joined(separator: " "))", labels: labels
                )
            } else {
                recorder.observe(
                    "snapshot.roundTrips", faithful == rounds && rounds > 0 ? .confirmed : .refuted,
                    "\(faithful)/\(rounds) came back with the same types in the same order and the same bytes. \(shape).", labels: labels
                )
            }
        }

        let result = recorder.finish()
        let stage = recorder.budgets.budget(for: .read, on: .clipboardFallback).milliseconds
        func cost(_ kind: String) -> Double {
            (result.p95("snapshot.take", labels: ["content": kind]) ?? 0) + (result.p95("snapshot.restore", labels: ["content": kind]) ?? 0)
        }
        let costs = ["text", "rich", "big:1000000", "big:10000000", "big:50000000"].map { String(format: "%@ %.1f ms", $0, cost($0)) }
        recorder.observe(
            "snapshot.fitsTheFallbackReadStage", cost("big:10000000") <= stage ? .confirmed : .refuted,
            "Snapshot plus restore, p95: \(costs.joined(separator: ", ")), out of a \(Int(stage)) ms stage that the copy itself also spends from."
        )
        let eager = result.p95("snapshot.take", labels: ["content": "text"]) ?? 0
        let lazy = result.p95("snapshot.take", labels: ["content": "lazy:0:1000"]) ?? 0
        let slow = result.p95("snapshot.take", labels: ["content": "lazy:50:1000"]) ?? 0
        recorder.observe(
            "snapshot.paysForLazyData", .info,
            String(format: "p95 to snapshot: text %.2f ms; with 1 KB provided on demand %.2f ms; when the provider takes 50 ms, %.2f ms. "
                + "The snapshot waits on the source app's main thread.", eager, lazy, slow)
        )
    }

    // MARK: 4. The transaction, against scripted interleavings

    private struct Scenario {
        var name: String
        /// Milliseconds after the trigger. Nil when the app never copies.
        var appCopiesAfter: Int?
        var foreignWriteAfter: Int?
        /// Stands in for the work between capture and restore: reading the text and handing it on.
        var hold: Duration = .zero
        var watchAfterRestore = false
    }

    private func transactions(_ pasteboard: NSPasteboard, fixture: FixtureProcess, recorder: RunRecorder) {
        let scenarios = [
            Scenario(name: "promptCopy", appCopiesAfter: 5),
            Scenario(name: "slowCopy", appCopiesAfter: 150),
            Scenario(name: "lateCopyIntoTheDrain", appCopiesAfter: 400),
            Scenario(name: "copyAfterTheDrain", appCopiesAfter: 900),
            Scenario(name: "noCopy"),
            Scenario(name: "foreignWriteAfterCapture", appCopiesAfter: 5, foreignWriteAfter: 20, hold: .milliseconds(30)),
            Scenario(name: "foreignWriteFirst", appCopiesAfter: 60, foreignWriteAfter: 5),
            Scenario(name: "foreignWriteFirst.watchingAfterRestore", appCopiesAfter: 60, foreignWriteAfter: 5, watchAfterRestore: true),
        ]
        let transaction = Transaction()
        var captures = 0
        var lateTexts = 0
        recorder.setParameter("transaction.window", "\(Int(transaction.window.milliseconds)) ms")
        recorder.setParameter("transaction.drain", "\(Int(transaction.drain.milliseconds)) ms")

        for scenario in scenarios {
            let labels = ["scenario": scenario.name]
            var ends: [String: Int] = [:]
            var wrongText = 0
            var selectionLeftBehind = 0
            var foreignLost = 0
            var originalLost = 0
            for round in 0..<Self.transactionRounds {
                fixture.discardEvents()
                // What the user had copied before, from another app.
                fixture.send("write 0 rich original-\(round)")
                guard fixture.wait(for: "wrote", timeout: .seconds(3)) != nil else { continue }

                let start = ContinuousClock.now
                let outcome = transaction.run(on: pasteboard, hold: scenario.hold, watchAfterRestore: scenario.watchAfterRestore) {
                    if let after = scenario.appCopiesAfter { fixture.send("write \(after) text selection-\(round)") }
                    if let after = scenario.foreignWriteAfter { fixture.send("write \(after) text foreign-\(round)") }
                }
                ends[outcome.end.rawValue, default: 0] += 1
                if let captured = outcome.capturedAfter {
                    recorder.record("transaction.untilCapture", labels: labels, duration: captured)
                    captures += 1
                    if outcome.textWasLate { lateTexts += 1 }
                }
                recorder.record("transaction.open", labels: labels, duration: start.duration(to: .now))

                // Judge the pasteboard once every scripted write has landed.
                let last = max(scenario.appCopiesAfter ?? 0, scenario.foreignWriteAfter ?? 0)
                let settled = start + .milliseconds(last + 150)
                if ContinuousClock.now < settled { Thread.sleep(forTimeInterval: (ContinuousClock.now.duration(to: settled)).milliseconds / 1_000) }
                let left = pasteboard.string(forType: .string) ?? ""
                if let text = outcome.text, !text.hasPrefix("selection-") { wrongText += 1 }
                if left.hasPrefix("selection-") { selectionLeftBehind += 1 }
                if scenario.foreignWriteAfter != nil, !left.hasPrefix("foreign-") { foreignLost += 1 }
                if scenario.foreignWriteAfter == nil, !left.hasPrefix("original-") { originalLost += 1 }
            }
            let safe = wrongText == 0 && selectionLeftBehind == 0 && foreignLost == 0 && originalLost == 0
            recorder.observe(
                "transaction.leavesNoHarm", safe ? .confirmed : .refuted,
                "Ended \(ends.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")). "
                    + "Took another writer's text for the selection: \(wrongText). Selection left on the pasteboard: \(selectionLeftBehind). "
                    + "Foreign write lost: \(foreignLost). Earlier copy lost: \(originalLost). Of \(Self.transactionRounds) rounds.",
                labels: labels
            )
        }
        recorder.observe(
            "transaction.meetsTheCountBeforeTheText", .info,
            "With a 1 ms poll, \(lateTexts) of \(captures) captures found no string at the first look and had to look again."
        )
        let result = recorder.finish()
        if let prompt = result.p95("transaction.untilCapture", labels: ["scenario": "promptCopy"]) {
            recorder.observe(
                "transaction.pollingAddsLittle", prompt <= 10 ? .confirmed : .refuted,
                String(format: "A copy scripted for 5 ms after the trigger was captured at p95 %.1f ms with a 1 ms poll.", prompt)
            )
        }
    }

    // MARK: 5. Is "check the count, then restore" one step

    private func checkThenClear(_ pasteboard: NSPasteboard, fixture: FixtureProcess, recorder: RunRecorder) {
        for _ in 0..<200 {
            let start = ContinuousClock.now
            _ = pasteboard.changeCount
            pasteboard.clearContents()
            recorder.record("restore.checkToClear", labels: ["otherWriter": "idle"], duration: start.duration(to: .now))
        }

        fixture.discardEvents()
        fixture.send("burst 2500 800")
        let labels = ["otherWriter": "busy"]
        var attempts = 0
        var betweenCheckAndClear = 0
        var afterClear = 0
        var writeRefused = 0
        var stableLooks = 0
        var mixed = 0
        while fixture.wait(for: "burstDone", timeout: .zero) == nil, attempts < 20_000 {
            let start = ContinuousClock.now
            let checked = pasteboard.changeCount
            let cleared = pasteboard.clearContents()
            recorder.record("restore.checkToClear", labels: labels, duration: start.duration(to: .now))
            // A type the other writer never uses, so that a pasteboard holding both can be recognised.
            let wrote = pasteboard.setData(Data("restore".utf8), forType: PasteboardFixture.blobType)
            attempts += 1
            if cleared != checked + 1 { betweenCheckAndClear += 1 }
            let after = pasteboard.changeCount
            if after != cleared {
                afterClear += 1
                if !wrote { writeRefused += 1 }
                let types = pasteboard.types ?? []
                let text = pasteboard.string(forType: .string)
                // Only a look the count did not move under says anything.
                if pasteboard.changeCount == after {
                    stableLooks += 1
                    if types.contains(PasteboardFixture.blobType), text?.hasPrefix("burst-") == true { mixed += 1 }
                }
            }
            Thread.sleep(forTimeInterval: 0.0005)
        }
        let result = recorder.finish()
        recorder.observe(
            "restore.checkThenClearIsNotOneStep", betweenCheckAndClear > 0 ? .confirmed : .inconclusive,
            String(format: "With another process writing about once a millisecond, %d of %d restores had a foreign write land between reading the "
                + "count and clearing. The gap is p50 %.3f ms, p95 %.3f ms then, and p95 %.3f ms with no other writer. "
                + "clearContents returning more than the checked count plus one shows it, after the newer write is gone.",
                betweenCheckAndClear, attempts, result.p50("restore.checkToClear", labels: labels) ?? 0,
                result.p95("restore.checkToClear", labels: labels) ?? 0, result.p95("restore.checkToClear", labels: ["otherWriter": "idle"]) ?? 0)
        )
        recorder.observe(
            "restore.neverMixesWithANewerWrite", stableLooks == 0 ? .inconclusive : (mixed == 0 ? .confirmed : .refuted),
            "The count moved between our clear and the end of our write \(afterClear) times, and our write was refused in \(writeRefused) of them. "
                + "In \(stableLooks) looks that the count held still for, \(mixed) pasteboards held our representation beside the other writer's text."
        )
    }

    // MARK: 6. Lazy data whose owner is gone or stuck

    /// A reader that listed the types while the owner lived may go on seeing them, so both orders are run.
    private func deadOwner(_ pasteboard: NSPasteboard, fixture: FixtureProcess, typesReadFirst: Bool, recorder: RunRecorder) {
        fixture.discardEvents()
        fixture.send("write 0 lazy:0:1000 orphan")
        guard fixture.wait(for: "wrote", timeout: .seconds(3)) != nil else { return }
        let listedBefore = typesReadFirst ? pasteboard.pasteboardItems?.first?.types.count : nil
        fixture.kill()
        let labels = ["typesReadFirst": String(typesReadFirst)]
        let snapshot = recorder.measure("snapshot.take", labels: ["content": "lazy, owner killed"].merging(labels) { $1 }) { BrokerSnapshot(pasteboard) }
        recorder.observe(
            "lazy.aDeadOwnersPromiseIsDropped", snapshot.unreadable == 0 && snapshot.representationCount == 1 ? .confirmed : .refuted,
            "The owner wrote a string and a promise, and was killed. "
                + (listedBefore.map { "\($0) representations were listed while it lived. " } ?? "Nothing was read while it lived. ")
                + "Afterwards \(snapshot.representationCount) listed and \(snapshot.unreadable) of them unreadable. "
                + "Confirmed means the pasteboard forgets what nobody can provide, so a snapshot never meets it.",
            labels: labels
        )
    }

    private func hungProvider(_ pasteboard: NSPasteboard, fixture: FixtureProcess, recorder: RunRecorder) {
        fixture.send("write 0 lazy:\(Self.hungProviderSeconds * 1_000):10 stuck")
        guard fixture.wait(for: "wrote", timeout: .seconds(3)) != nil else { return }
        nonisolated(unsafe) let pasteboard = pasteboard
        recorder.log("Reading lazy data from a provider that sleeps for \(Self.hungProviderSeconds) s. Waiting up to \(Self.hungReadLimit.components.seconds) s.")
        let read = Deadline.run(limit: Self.hungReadLimit) { pasteboard.data(forType: PasteboardFixture.blobType)?.count ?? -1 }
        if let bytes = read.value {
            recorder.record("lazy.hungProvider.readReturnedAfter", duration: read.elapsed)
            recorder.observe(
                "lazy.aHungProviderHoldsUpTheRead", read.elapsed > .seconds(1) ? .confirmed : .refuted,
                String(format: "The read came back after %.0f ms with %d bytes (-1 is nil), while the provider was still asleep.", read.elapsed.milliseconds, bytes)
            )
            fixture.kill()
            return
        }
        let killed = ContinuousClock.now
        fixture.kill()
        let released = read.wait(for: .seconds(5))
        recorder.observe(
            "lazy.aHungProviderHoldsUpTheRead", .confirmed,
            "data(forType:) was still blocked after \(Self.hungReadLimit.components.seconds) s. "
                + (released
                    ? String(format: "It returned %.0f ms after the provider's process was killed.", killed.duration(to: .now).milliseconds)
                    : "It stayed blocked for 5 s after the provider's process was killed.")
                + " A pasteboard read cannot be cancelled, so a snapshot has to run where it can be abandoned."
        )
    }

    // MARK: 7. The real clipboard, and pasteboard privacy

    private func generalPasteboard(recorder: RunRecorder) {
        nonisolated(unsafe) let pasteboard = NSPasteboard.general
        let preview = UserDefaults.standard.object(forKey: "EnablePasteboardPrivacyDeveloperPreview").map { "\($0)" } ?? "unset"
        recorder.setParameter("pasteboardPrivacyDeveloperPreview", preview)
        recorder.setParameter("accessBehavior.before", Self.accessBehavior(of: pasteboard))

        let first = Deadline.run(limit: Self.generalReadLimit) { BrokerSnapshot(pasteboard) }
        recorder.setParameter("accessBehavior.after", Self.accessBehavior(of: pasteboard))
        guard let snapshot = first.value else {
            recorder.observe(
                "privacy.aProgrammaticReadIsHeldUp", .confirmed,
                "Reading the clipboard did not return in \(Self.generalReadLimit.components.seconds) s, with access behaviour "
                    + "\(Self.accessBehavior(of: pasteboard)). The system is presumably asking the user. Nothing was written."
            )
            return
        }
        recorder.record("general.snapshot", duration: first.elapsed)
        recorder.observe(
            "privacy.aProgrammaticReadIsHeldUp", first.elapsed > .milliseconds(500) ? .confirmed : .refuted,
            String(format: "Reading what another app had copied took %.1f ms: %d items, %d representations, %d bytes, %d unreadable. "
                + "Access behaviour %@ before and %@ after; developer preview key %@.",
                first.elapsed.milliseconds, snapshot.items.count, snapshot.representationCount, snapshot.bytes, snapshot.unreadable,
                recorder.finish().parameters["accessBehavior.before"] ?? "?", Self.accessBehavior(of: pasteboard), preview)
        )
        guard snapshot.isRestorable else {
            recorder.observe(
                "general.putBackAsFound", .inconclusive,
                "What is on the clipboard cannot be put back faithfully (\(snapshot.unreadable) unreadable, promise: \(snapshot.holdsPromise)), "
                    + "which is the broker's Skipped state. Nothing was written."
            )
            return
        }

        // Another program's write, with no input event anywhere near it.
        let probe = "PappuClip spike 6 probe \(UUID().uuidString.prefix(8))"
        let before = pasteboard.changeCount
        let copy = Process()
        let pipe = Pipe()
        copy.executableURL = URL(filePath: "/usr/bin/pbcopy")
        copy.standardInput = pipe
        guard (try? copy.run()) != nil else { return }
        pipe.fileHandleForWriting.write(Data(probe.utf8))
        try? pipe.fileHandleForWriting.close()
        copy.waitUntilExit()
        let delta = pasteboard.changeCount - before
        recorder.record("general.countDelta", unit: "count", labels: ["writer": "pbcopy"], value: Double(delta))
        let second = Deadline.run(limit: Self.generalReadLimit) { pasteboard.string(forType: .string) }
        recorder.observe(
            "privacy.pbcopyTextIsReadable", second.value.flatMap { $0 } == probe ? .confirmed : .refuted,
            String(format: "Read back after %.1f ms; the count moved by %d.", second.elapsed.milliseconds, delta)
        )

        guard pasteboard.changeCount == before + delta else {
            recorder.observe("general.putBackAsFound", .info, "Someone copied during the probe, so the clipboard was left alone.")
            return
        }
        let counts = recorder.measure("general.restore") { snapshot.restore(to: pasteboard, marked: true) }
        let after = BrokerSnapshot(pasteboard)
        recorder.record("general.countDelta", unit: "count", labels: ["writer": "restore"], value: Double(counts.final - (before + delta)))
        recorder.observe(
            "general.putBackAsFound", after.fingerprint == snapshot.fingerprint ? .confirmed : .refuted,
            "Same types in the same order with the same bytes, the two markers aside: \(after.fingerprint == snapshot.fingerprint). "
                + "The restore was alone: \(counts.cleared == before + delta + 1)."
        )
    }

    private static func accessBehavior(of pasteboard: NSPasteboard) -> String {
        guard #available(macOS 15.4, *) else { return "not on this macOS" }
        return switch pasteboard.accessBehavior {
        case .default: "default"
        case .ask: "ask"
        case .alwaysAllow: "alwaysAllow"
        case .alwaysDeny: "alwaysDeny"
        @unknown default: "unknown"
        }
    }

    // MARK: 8. InputEpoch

    private static let countedTypes: [(String, CGEventType)] = [
        ("leftMouseDown", .leftMouseDown), ("rightMouseDown", .rightMouseDown), ("otherMouseDown", .otherMouseDown),
        ("keyDown", .keyDown), ("scrollWheel", .scrollWheel),
    ]

    fileprivate static let noticeTypes: [CGEventType] = [.tapDisabledByTimeout, .tapDisabledByUserInput]

    private static func sessionCounts() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: countedTypes.map { ($0.0, Int(CGEventSource.counterForEventType(.combinedSessionState, eventType: $0.1))) })
    }

    /// The window server's own count of input events, which needs no permission. It cannot say whose
    /// an event was, so it cannot be `InputEpoch`, but it can say whether a tap missed something.
    private func sessionCounters(recorder: RunRecorder) {
        for _ in 0..<200 {
            recorder.measure("epoch.sessionCountersRead") { _ = Self.sessionCounts() }
        }
        let counts = Self.sessionCounts()
        recorder.observe(
            "epoch.sessionCountersNeedNoPermission", counts.values.contains { $0 > 0 } ? .confirmed : .inconclusive,
            "Read with \(PermissionSnapshot.current().summary): " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        )
    }

    private func inputEpoch(permissions: PermissionSnapshot, recorder: RunRecorder) {
        let thread = TapThread(name: "spike6.taps")
        defer { thread.stop() }
        let epoch = EpochCounter()
        let strayBefore = EventTap.callsAfterTheTapWentAway
        var tapKind = "active"
        var tap = EventTap(events: Self.countedTypes.map(\.1), option: .defaultTap, on: thread, handler: epoch.handler)
        if tap == nil {
            tapKind = "listenOnly"
            tap = EventTap(events: Self.countedTypes.map(\.1), option: .listenOnly, on: thread, handler: epoch.handler)
        }
        guard let tap else {
            recorder.observe("epoch.countsRealInput", .inconclusive, "No tap could be created: \(permissions.summary).")
            return
        }
        defer { tap.invalidate() }
        recorder.setParameter("epoch.tap", tapKind)

        if tapKind == "active", permissions.postEvent {
            // The tap swallows both kinds, so no app sees a key nobody pressed.
            let before = epoch.total
            for _ in 0..<20 { EpochCounter.postF13(tag: EpochCounter.oursTag); Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.2)
            let afterOurs = epoch.total
            for _ in 0..<20 { EpochCounter.postF13(tag: EpochCounter.strangerTag); Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.2)
            let afterStrangers = epoch.total
            recorder.observe(
                "epoch.leavesOutOurOwnEvents", afterOurs == before ? .confirmed : .refuted,
                "20 key-downs posted with our tag moved the epoch by \(afterOurs - before)."
            )
            recorder.observe(
                "epoch.countsPostedInput", afterStrangers - afterOurs == 20 ? .confirmed : .refuted,
                "20 key-downs posted without it moved the epoch by \(afterStrangers - afterOurs)."
            )
        } else {
            recorder.observe("epoch.leavesOutOurOwnEvents", .inconclusive, "Needs an active tap and permission to post: tap \(tapKind), \(permissions.summary).")
        }

        let tapBefore = epoch.counts
        let sessionBefore = Self.sessionCounts()
        for remaining in stride(from: Self.operatorSeconds, to: 0, by: -2) {
            recorder.log("Type, click and scroll in another app. \(remaining) s left.")
            Thread.sleep(forTimeInterval: 2)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let tapAfter = epoch.counts
        let sessionAfter = Self.sessionCounts()
        var lines: [String] = []
        var total = 0
        var agree = true
        for (name, type) in Self.countedTypes {
            let seen = (tapAfter[type.rawValue] ?? 0) - (tapBefore[type.rawValue] ?? 0)
            let counted = (sessionAfter[name] ?? 0) - (sessionBefore[name] ?? 0)
            total += counted
            agree = agree && seen == counted
            lines.append("\(name) tap \(seen) / session \(counted)")
        }
        // An earlier run died in the tap's callback: a `tapDisabledByUserInput` notice came with a context
        // that had been freed. Whether it was meant for the refused tap or the live one is not known.
        let stray = EventTap.callsAfterTheTapWentAway.merging(strayBefore) { $0 - $1 }.filter { $0.value > 0 }
        let notices = Self.noticeTypes.map { (tapAfter[$0.rawValue] ?? 0) - (tapBefore[$0.rawValue] ?? 0) }.reduce(0, +)
        recorder.observe(
            "epoch.callbacksComeOnlyForALiveTap", stray.isEmpty ? .info : .refuted,
            "Callbacks for a tap that was gone, by event type: \(stray.isEmpty ? "none" : String(describing: stray)). "
                + "Tap-disabled notices for the live tap: \(notices). Input in the window: \(total) events. "
                + "None in one window does not show that it cannot happen."
        )
        recorder.observe(
            "epoch.countsRealInput", total == 0 ? .inconclusive : (agree ? .confirmed : .refuted),
            (total == 0 ? "Nobody typed or clicked. " : "") + lines.joined(separator: ", ") + ". Tap: \(tapKind)."
        )
    }

    // MARK: 9. A real app

    private func liveTransactions(permissions: PermissionSnapshot, recorder: RunRecorder) {
        guard permissions.postEvent else {
            recorder.observe("live.transaction", .inconclusive, "No post-event access, so ⌘C cannot be sent.")
            return
        }
        for remaining in stride(from: Self.countdownSeconds, to: 0, by: -2) {
            recorder.log("Switch to the app under test and select a sentence. Starting in \(remaining) s.")
            Thread.sleep(forTimeInterval: 2)
        }
        guard let source = onMain({ SourceApp.frontmost() }) else {
            recorder.observe("live.transaction", .inconclusive, "SpikeLab itself is frontmost, so there is no app to copy from.")
            return
        }
        recorder.setParameter("app", source.name)
        recorder.setParameter("bundleID", source.bundleID)
        let labels = source.labels
        let pasteboard = NSPasteboard.general
        var texts = 0
        var restored = 0
        var deltas: Set<Int> = []
        for _ in 0..<Self.liveRounds {
            let snapshot = recorder.measure("live.snapshot", labels: labels) { BrokerSnapshot(pasteboard) }
            guard snapshot.isRestorable else {
                recorder.observe("live.transaction", .info, "The clipboard cannot be put back faithfully, so the transaction is Skipped.", labels: labels)
                return
            }
            let start = ContinuousClock.now
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyC, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.setIntegerValueField(.eventSourceUserData, value: EpochCounter.oursTag)
                event?.post(tap: .cghidEventTap)
            }
            while pasteboard.changeCount == snapshot.changeCount, start.duration(to: .now) < Self.liveCopyLimit {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard pasteboard.changeCount != snapshot.changeCount else {
                recorder.record("live.countDelta", unit: "count", labels: labels.merging(["when": "first"]) { $1 }, value: 0)
                continue
            }
            let moved = ContinuousClock.now
            recorder.record("live.untilCount", labels: labels, duration: start.duration(to: moved))
            recorder.record("live.countDelta", unit: "count", labels: labels.merging(["when": "first"]) { $1 }, value: Double(pasteboard.changeCount - snapshot.changeCount))
            while pasteboard.string(forType: .string) == nil, moved.duration(to: .now) < Self.liveSettle {
                Thread.sleep(forTimeInterval: 0.001)
            }
            if pasteboard.string(forType: .string)?.isEmpty == false {
                texts += 1
                recorder.record("live.textAfterCount", labels: labels, duration: moved.duration(to: .now))
            }
            // An app that writes twice shows here, and not in the first delta.
            Thread.sleep(forTimeInterval: Self.liveSettle.milliseconds / 1_000)
            let settled = pasteboard.changeCount
            deltas.insert(settled - snapshot.changeCount)
            recorder.record("live.countDelta", unit: "count", labels: labels.merging(["when": "settled"]) { $1 }, value: Double(settled - snapshot.changeCount))
            if pasteboard.changeCount == settled {
                let counts = recorder.measure("live.restore", labels: labels) { snapshot.restore(to: pasteboard, marked: true) }
                if counts.cleared == settled + 1, BrokerSnapshot(pasteboard).fingerprint == snapshot.fingerprint { restored += 1 }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        recorder.observe(
            "live.transaction", texts == Self.liveRounds && restored == Self.liveRounds ? .confirmed : .refuted,
            "\(texts)/\(Self.liveRounds) copies produced text; \(restored)/\(Self.liveRounds) restores were alone and faithful; "
                + "settled count deltas seen: \(deltas.sorted().map(String.init).joined(separator: ", ")).",
            labels: labels
        )
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        (Double(end) - Double(start)) / 1_000_000
    }
}

// MARK: - The transaction of architecture §5, as written

/// A prototype with the pieces a private pasteboard can exercise: the window, the drain, the count rules.
/// The frontmost-app and `InputEpoch` checks have nothing to look at here and are left out, which is
/// the point of the foreign-write scenarios: they show what is left when those checks have nothing to say.
private struct Transaction {
    enum End: String {
        case skipped, restored, restoredFromDrain, closed, abandoned
    }

    struct Outcome {
        var end: End
        /// What would have been handed on as the selection.
        var text: String?
        var capturedAfter: Duration?
        /// The count had moved and the first read found no string.
        var textWasLate = false
    }

    var window: Duration = .milliseconds(250)
    var drain: Duration = .milliseconds(500)
    var pollInterval: TimeInterval = 0.001
    /// The fixture's writers move the count by one.
    var expectedDelta = 1...1

    func run(on pasteboard: NSPasteboard, hold: Duration, watchAfterRestore: Bool, trigger: () -> Void) -> Outcome {
        let snapshot = BrokerSnapshot(pasteboard)
        guard snapshot.isRestorable else { return Outcome(end: .skipped) }
        let start = ContinuousClock.now
        trigger()

        guard let first = waitForChange(on: pasteboard, from: snapshot.changeCount, until: start + window + drain) else {
            return Outcome(end: .closed)
        }
        let draining = first.at > start + window
        let textWasLate = pasteboard.string(forType: .string) == nil
        guard expectedDelta.contains(first.count - snapshot.changeCount),
              let text = waitForText(on: pasteboard, at: first.count, until: first.at + .milliseconds(50))
        else { return Outcome(end: .abandoned) }
        // A copy that lands while draining is put back and never handed on: its attempt is over (ACT-16b).
        var outcome = Outcome(end: draining ? .restoredFromDrain : .restored, text: draining ? nil : text, capturedAfter: start.duration(to: first.at), textWasLate: textWasLate)

        Thread.sleep(forTimeInterval: hold.milliseconds / 1_000)
        guard pasteboard.changeCount == first.count else {
            outcome.end = .abandoned
            return outcome
        }
        var ours = snapshot.restore(to: pasteboard, marked: true).final

        // Not in the architecture: stay open after a restore, and treat one more attributable change as the app's late copy.
        if watchAfterRestore, let late = waitForChange(on: pasteboard, from: ours, until: .now + drain),
           expectedDelta.contains(late.count - ours), waitForText(on: pasteboard, at: late.count, until: late.at + .milliseconds(50)) != nil,
           pasteboard.changeCount == late.count {
            ours = snapshot.restore(to: pasteboard, marked: true).final
        }
        return outcome
    }

    private func waitForChange(on pasteboard: NSPasteboard, from count: Int, until deadline: ContinuousClock.Instant) -> (count: Int, at: ContinuousClock.Instant)? {
        while ContinuousClock.now < deadline {
            let now = pasteboard.changeCount
            if now != count { return (now, .now) }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }

    /// Nil when the count moves again first, or no text arrives.
    private func waitForText(on pasteboard: NSPasteboard, at count: Int, until deadline: ContinuousClock.Instant) -> String? {
        while ContinuousClock.now < deadline, pasteboard.changeCount == count {
            if let text = pasteboard.string(forType: .string) { return pasteboard.changeCount == count ? text : nil }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }
}

// MARK: - Supporting types

/// Every item and every representation (ACT-10a). Unlike spike 3's snapshot it keeps the order of the
/// types and the representations it could not read, and knows a file promise when it sees one.
struct BrokerSnapshot: Sendable {
    struct Representation: Sendable {
        var type: String
        var data: Data?
    }

    let changeCount: Int
    let items: [[Representation]]

    init(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.map { Representation(type: $0.rawValue, data: item.data(forType: $0)) }
        }
    }

    private static let markers = [PasteboardFixture.transientType.rawValue, PasteboardFixture.concealedType.rawValue]

    var representationCount: Int { items.reduce(0) { $0 + $1.count } }
    var unreadable: Int { items.reduce(0) { $0 + $1.filter { $0.data == nil }.count } }
    var bytes: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + ($1.data?.count ?? 0) } } }
    var holdsPromise: Bool { items.contains { $0.contains { $0.type.localizedCaseInsensitiveContains("promise") } } }
    var isRestorable: Bool { unreadable == 0 && !holdsPromise }

    /// Types in order with a digest of each one's bytes, the broker's own markers left out.
    var fingerprint: String {
        items.map { item in
            item.filter { !Self.markers.contains($0.type) }.map { representation in
                let digest = representation.data.map { SHA256.hash(data: $0).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "nil"
                return "\(representation.type)=\(digest)"
            }.joined(separator: ",")
        }.joined(separator: "|")
    }

    /// - Returns: The count straight after clearing, which is one more than before when nobody else wrote, and the count at the end.
    @discardableResult
    func restore(to pasteboard: NSPasteboard, marked: Bool) -> (cleared: Int, final: Int) {
        let cleared = pasteboard.clearContents()
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            representations.forEach { item.setData($0.data ?? Data(), forType: NSPasteboard.PasteboardType($0.type)) }
            if marked {
                Self.markers.filter { marker in !representations.contains { $0.type == marker } }
                    .forEach { item.setData(Data(), forType: NSPasteboard.PasteboardType($0)) }
            }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return (cleared, pasteboard.changeCount)
    }
}

/// Work that may never return, run where it can be given up on. The thread is left behind when it does not.
final class Deadline<Value: Sendable>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Value?
    private(set) var elapsed: Duration = .zero

    var value: Value? { lock.withLock { result } }

    static func run(limit: Duration, _ body: @escaping @Sendable () -> Value) -> Deadline {
        let deadline = Deadline()
        let start = ContinuousClock.now
        Thread.detachNewThread {
            let value = body()
            deadline.lock.withLock {
                deadline.result = value
                deadline.elapsed = start.duration(to: .now)
            }
            deadline.done.signal()
        }
        if !deadline.wait(for: limit) { deadline.lock.withLock { deadline.elapsed = start.duration(to: .now) } }
        return deadline
    }

    /// - Returns: Whether the work has finished.
    func wait(for limit: Duration) -> Bool {
        guard done.wait(timeout: .now() + .nanoseconds(Int(limit.milliseconds * 1_000_000))) == .success else { return false }
        done.signal()
        return true
    }
}

/// `InputEpoch` as architecture §3.4 describes it: every mouse-down, key-down and scroll, except ours.
private final class EpochCounter: Sendable {
    static let oursTag: Int64 = 0x5041_5036_0000_0001
    static let strangerTag: Int64 = 0x5041_5036_0000_0002
    private static let f13: CGKeyCode = 105

    private let state = Mutex([UInt32: Int]())

    var counts: [UInt32: Int] { state.withLock { $0 } }
    var total: Int { counts.filter { key, _ in !ClipboardSpike.noticeTypes.contains { $0.rawValue == key } }.values.reduce(0, +) }

    var handler: EventTap.Handler {
        { [self] type, event in
            // A notice that the tap was switched off is not input, and its event is not one to read.
            guard !ClipboardSpike.noticeTypes.contains(type) else {
                state.withLock { $0[type.rawValue, default: 0] += 1 }
                return .pass
            }
            let tag = event.getIntegerValueField(.eventSourceUserData)
            if tag != Self.oursTag { state.withLock { $0[type.rawValue, default: 0] += 1 } }
            return tag == Self.oursTag || tag == Self.strangerTag ? .swallow : .pass
        }
    }

    static func postF13(tag: Int64) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: f13, keyDown: true) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.post(tap: .cghidEventTap)
    }
}
