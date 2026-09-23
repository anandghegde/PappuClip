import Foundation
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

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

/// A permit from a policy that allows strategy 5 on the hotkey route — the only way to open a read
/// transaction, and here only so that there is one open to be refused alongside.
private func readPermit() -> SyntheticCopyPermit {
    let policies = DetectionPolicies(
        default: DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: true,
            hotkeySyntheticCopy: true,
            quiescence: true
        )
    )
    guard let permit = DetectionPolicyStore(policies).syntheticCopyPermit(
        attempt: AttemptID(rawValue: 1),
        route: .hotkey,
        target: target,
        coexistence: .none
    ) else {
        preconditionFailure("this policy allows strategy 5 on the hotkey route")
    }
    return permit
}

/// Every string anywhere inside a value, for the DIA-4 walk.
private func strings(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    let mirror = Mirror(reflecting: value)
    guard !mirror.children.isEmpty else { return ["\(value)"] }
    return mirror.children.flatMap { strings(in: $0.value) }
}

/// **ACT-10's third path: the write the user asked for (PRD §7.4, Copy and ⌥ Open Link).**
///
/// The other two borrow the user's clipboard and promise to give it back. This one replaces it, on
/// purpose, and so inverts three of the transaction rules — no markers, no access check, no restore.
/// What it keeps is the one rule that is about the *broker* rather than about the clipboard: one
/// operation at a time.
@Suite struct ClipboardWriteTests {
    @Test func replacesTheClipboardAndLeavesItThere() async {
        let pasteboard = ScriptedPasteboard(text: held)

        let result = await broker(pasteboard).write("copied text", for: invocation, into: target)

        #expect(result.outcome == .written)
        #expect(pasteboard.currentText == "copied text")
        // One clear and one write, and no second pair: there is no restore, because the user asked for
        // their clipboard to be replaced.
        #expect(pasteboard.clears == 1)
        #expect(pasteboard.brokerWrites.count == 1)
        #expect(result.record.characters == 11)
    }

    /// ACT-10h holds the other way round here. The paste path marks its text `transient` and `concealed`
    /// because the user never asked for it and a clipboard manager recording it would be a leak; Copy is
    /// the user asking for it, and a clipboard manager that misses it is broken.
    @Test func doesNotHideTheTextFromClipboardManagers() async {
        let pasteboard = ScriptedPasteboard(text: held)

        _ = await broker(pasteboard).write("copied text", for: invocation, into: target)

        #expect(pasteboard.lastWriteWasMarked == false)
        #expect(pasteboard.currentTypes == [[PasteboardRepresentation.plainText]])
    }

    /// The access rules govern *reading* somebody else's clipboard (architecture §19 item 3). A write
    /// reads nothing, so a pasteboard that would prompt on read is written to anyway.
    @Test func writesEvenWhereAReadWouldPrompt() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(access: .ask)

        let result = await broker(pasteboard).write("copied text", for: invocation, into: target)

        #expect(result.written)
        #expect(pasteboard.currentText == "copied text")
    }

    /// ACT-10c: a write landing on top of a snapshot that is about to be restored over it would be lost
    /// without anybody noticing. It is refused instead, which costs the user a Copy they can repeat.
    @Test func refusesWhileATransactionIsOpen() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.copy("read", at: .milliseconds(20))])
        let broker = broker(pasteboard)

        async let read = broker.read(
            readPermit(),
            clock: AttemptClock(start: pasteboard.now, now: pasteboard.reader)
        )
        var opened = false
        for _ in 0..<1000 where !opened {
            opened = await broker.isBusy
            if !opened { await Task.yield() }
        }
        guard opened else {
            Issue.record("the read transaction never opened")
            return
        }

        let result = await broker.write("copied text", for: invocation, into: target)

        #expect(result.outcome == .skipped(.brokerBusy))
        _ = await read
        // Its snapshot went back up, as it always does. A write admitted a moment ago would have been
        // written over by that restore, and neither the user nor the record would ever have known.
        #expect(pasteboard.currentText == held)
    }

    /// ACT-10f's gap is as real for a write the user asked for as for a restore: something that landed
    /// between the count check and `clear()` is destroyed by it. It cannot be closed, so it is recorded.
    @Test func noticesAWriteTheClearDestroyed() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.writeInRestoreGap("something else, a moment ago")

        let result = await broker(pasteboard).write("copied text", for: invocation, into: target)

        #expect(result.written)
        #expect(result.record.safety == [.destroyedANewerWrite])
    }

    // MARK: Reading what is there

    @Test func readsThePlainTextOnTheClipboard() async {
        #expect(await broker(ScriptedPasteboard(text: held)).plainText() == held)
        #expect(await broker(ScriptedPasteboard(text: nil)).plainText() == nil)
    }

    /// Reading another app's clipboard is what the access rules are about, so this one does check.
    @Test func doesNotReadWhereItWouldPrompt() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(access: .ask)

        #expect(await broker(pasteboard).plainText() == nil)
    }

    /// The inspector shows these records (DIA-2), so one that could hold a character of what was copied
    /// would be a leak with a user interface on it.
    @Test func noRecordCanHoldWhatWasWritten() async {
        let secret = "shibboleth quick brown fox"

        let result = await broker(ScriptedPasteboard(text: held)).write(secret, for: invocation, into: target)

        let found = strings(in: result.record)
        #expect(!found.contains { $0.contains("shibboleth") })
        #expect(found.contains("com.example.editor"))
        #expect(result.record.characters == secret.count)
    }
}
