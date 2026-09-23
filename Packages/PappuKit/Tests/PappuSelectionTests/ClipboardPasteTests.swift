import Foundation
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

// MARK: The scene

private let target = TargetApp(pid: 501, bundleID: "com.example.editor")
private let held = "the user's own clipboard"
private let invocation = InvocationID(rawValue: 7)

private func broker(_ pasteboard: ScriptedPasteboard) -> ClipboardBroker {
    ClipboardBroker(
        pasteboard: pasteboard,
        input: pasteboard,
        copy: pasteboard,
        pasting: pasteboard,
        scheduling: pasteboard,
        timing: .initial
    )
}

/// The text of the first thing the broker wrote — our result going up, before any restore.
private func textPutUp(_ pasteboard: ScriptedPasteboard) -> String? {
    guard let item = pasteboard.brokerWrites.first?.first else { return nil }
    guard let text = item.first(where: { $0.type == ScriptedPasteboard.textType }) else { return nil }
    return String(decoding: text.data, as: UTF8.self)
}

/// Whether that write asked clipboard managers to leave it alone (ACT-10h).
private func putUpWasMarked(_ pasteboard: ScriptedPasteboard) -> Bool {
    guard let items = pasteboard.brokerWrites.first, !items.isEmpty else { return false }
    return items.allSatisfy { item in
        PasteboardMarker.all.allSatisfy { marker in item.contains { $0.type == marker } }
    }
}

private func strings(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    let mirror = Mirror(reflecting: value)
    guard !mirror.children.isEmpty else { return ["\(value)"] }
    return mirror.children.flatMap { strings(in: $0.value) }
}

// MARK: - The write path (RUN-4, architecture §8.3)

@Suite struct ClipboardPasteTests {
    /// The whole promise in one test: the result goes up, the ⌘V goes out, the user's clipboard comes
    /// back, and the thing we held was marked so no clipboard manager keeps a copy of it.
    @Test func putsTheResultUpPostsTheKeystrokeAndTakesItBackDown() async {
        let pasteboard = ScriptedPasteboard(text: held)

        let result = await broker(pasteboard).paste("SHOUTING", for: invocation, into: target)

        #expect(result.outcome == .pasted)
        #expect(result.posted)
        #expect(pasteboard.pastePosts == 1)
        #expect(textPutUp(pasteboard) == "SHOUTING")
        #expect(putUpWasMarked(pasteboard))
        #expect(pasteboard.currentText == held)
        #expect(result.record.restored)
        #expect(result.record.safety.isEmpty)
        // It waited for the app to take the text, because nothing tells it when that happened.
        #expect(result.record.held == ClipboardTiming.initial.hold)
        #expect(result.record.characters == 8)
    }

    /// The count moving while our text is up means somebody else owns the pasteboard. Theirs is newest,
    /// so it is left alone — and the user's clipboard is therefore *not* put back, which is a thing the
    /// record has to say out loud rather than a thing that quietly happens.
    @Test func leavesAStrangersWriteAloneAndSaysSo() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.foreignWrite("theirs", at: .milliseconds(10))])

        let result = await broker(pasteboard).paste("ours", for: invocation, into: target)

        #expect(result.outcome == .abandoned(.foreignWriteWhileHeld))
        #expect(result.posted, "the ⌘V went out before the stranger wrote, and may well have landed")
        #expect(result.record.safety == [.foreignWriteBeforeRestore])
        #expect(result.record.restored == false)
        #expect(pasteboard.currentText == "theirs")
    }

    /// Holding the user's clipboard for a paste nobody was ever asked for is the one shape this must
    /// never take, so a refused keystroke does not serve out the hold — it gives the clipboard back on
    /// the spot.
    @Test func takesTheTextDownAtOnceWhenTheKeystrokeCannotBePosted() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(pasteCanBePosted: false)

        let result = await broker(pasteboard).paste("ours", for: invocation, into: target)

        #expect(result.outcome == .skipped(.pasteNotPosted))
        #expect(result.posted == false)
        #expect(pasteboard.pastePosts == 0)
        #expect(result.record.restored)
        #expect(result.record.held == .zero)
        #expect(pasteboard.currentText == held)
    }

    /// No snapshot, no transaction. A clipboard that cannot be read faithfully cannot be put back, and
    /// an action whose result cannot be pasted is offered for explicit copy instead (RUN-2c) — which
    /// costs a click, where this would cost the clipboard.
    @Test func writesNothingWhenTheClipboardCannotBeReadBack() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(access: .ask)

        let result = await broker(pasteboard).paste("ours", for: invocation, into: target)

        #expect(result.outcome == .skipped(.accessNotAllowed))
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.brokerWrites.isEmpty)
        #expect(pasteboard.pastePosts == 0)
        #expect(pasteboard.currentText == held)
    }

    @Test func writesNothingWhenTheSnapshotCannotBeTakenInTime() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(readCost: .milliseconds(200))

        let result = await broker(pasteboard).paste("ours", for: invocation, into: target)

        #expect(result.outcome == .skipped(.snapshotAbandoned))
        #expect(result.record.safety == [.readAbandoned])
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.brokerWrites.isEmpty)
    }

    /// Putting our text up is a clear, and a clear has the same 0.13–0.36 ms gap in front of it as the
    /// restore does (ACT-10f). It cannot be closed; it can only be noticed, and never claimed when it
    /// did not happen.
    @Test func noticesAWriteItDestroyedByPuttingTheResultUp() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.writeInRestoreGap("a write nobody will see again")

        let result = await broker(pasteboard).paste("ours", for: invocation, into: target)

        #expect(result.outcome == .pasted)
        #expect(result.record.safety == [.destroyedANewerWrite])
        #expect(pasteboard.currentText == held, "the user's own clipboard still goes back")
    }

    /// One transaction at a time, in both directions: a read and a write hold two snapshots of the same
    /// pasteboard, and the second restore would undo the first (ACT-10c).
    @Test func refusesASecondWriteWhileATransactionIsOpen() async {
        let pasteboard = ScriptedPasteboard(text: held)
        let broker = broker(pasteboard)

        async let first = broker.paste("one", for: InvocationID(rawValue: 1), into: target)
        async let second = broker.paste("two", for: InvocationID(rawValue: 2), into: target)
        let outcomes = await [first.outcome, second.outcome]

        #expect(outcomes.filter { $0 == .skipped(.brokerBusy) }.count == 1)
        #expect(outcomes.contains(.pasted))
        #expect(pasteboard.pastePosts == 1)
    }

    /// DIA-2, on the way out as well as on the way in. The inspector shows these records, and an action's
    /// result is as much the user's text as their selection is.
    @Test func noRecordCanHoldTheResult() async {
        let pasteboard = ScriptedPasteboard(text: "her passphrase")

        let result = await broker(pasteboard).paste("shibboleth quick brown fox", for: invocation, into: target)

        let found = strings(in: result.record)
        #expect(!found.contains { $0.contains("shibboleth") || $0.contains("passphrase") })
        #expect(found.contains("com.example.editor"))
        #expect(result.record.characters == 26)
    }
}
