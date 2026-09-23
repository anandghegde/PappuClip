import Foundation
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Testing

private let selectedRange = AXTextRange(location: 10, length: 5)
private let selection = "the selected words"
private let held = "the user's own clipboard"
private let matching = settled(range: selectedRange, text: selection)

// MARK: The scene

private func manager(
    _ probe: FakeDestinationProbe,
    input: FakeInput = FakeInput(),
    frontmost: TargetApp? = editor,
    clock: ManualTimeSource = ManualTimeSource()
) -> InvocationManager {
    InvocationManager(
        verifier: DestinationVerifier(
            gate: PrivacyGate(PrivacyRules()),
            probe: probe,
            policies: policies(),
            epochs: input,
            frontmost: { frontmost },
            secureInputIsActive: { false },
            timing: .initial,
            now: clock.reader
        ),
        probe: probe,
        epochs: input,
        timing: .initial,
        sleeper: FakeSleep(),
        now: clock.reader
    )
}

private func request(mayMutate: Bool = true) -> InvocationRequest {
    InvocationRequest(
        attempt: AttemptID(rawValue: 3),
        route: .automatic,
        target: editor,
        action: "com.pappuclip.builtin.uppercase",
        mayMutate: mayMutate,
        text: selection,
        range: selectedRange,
        strategy: .ax
    )
}

/// The real broker over the scripted pasteboard, because the thing being tested is that an action's
/// result reaches the destination the way a user's ⌘V would, and a fake clipboard cannot show that.
private func clipboard(_ pasteboard: ScriptedPasteboard) -> ClipboardBroker {
    ClipboardBroker(
        pasteboard: pasteboard,
        input: pasteboard,
        copy: pasteboard,
        pasting: pasteboard,
        scheduling: pasteboard,
        timing: .initial
    )
}

/// The whole path, as the coordinator will walk it: begin the run, verify the destination, and spend
/// the permit on a paste. Nil when the verification granted none — which is the case that matters
/// most, because then there is nothing to spend and no way to write.
@discardableResult
private func replace(
    _ text: String,
    through runtime: InvocationManager,
    on pasteboard: ScriptedPasteboard,
    invocation: InvocationID
) async -> MutationReport? {
    let mutator = TextMutator(clipboard: clipboard(pasteboard), manager: runtime)
    guard let permit = await runtime.verifyDestination(of: invocation).permit() else { return nil }
    return await mutator.replaceSelection(with: text, using: permit)
}

/// RUN-2d and RUN-4: what happens to an action's result, and what happens to the user's clipboard on
/// the way.
@Suite struct TextMutatorTests {
    // MARK: One paste, one undo (RUN-4)

    @Test func putsTheResultWhereTheSelectionWasAndGivesTheClipboardBack() async {
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())

        let report = await replace("THE SELECTED WORDS", through: runtime, on: pasteboard, invocation: invocation)

        #expect(report?.outcome == .mutated)
        #expect(report?.tier == .accessibility)
        #expect(report?.characters == 18)
        #expect(report?.bundleID == editor.bundleID)
        #expect(pasteboard.currentText == held)
        #expect(await runtime.record(of: invocation)?.mutated == true)
    }

    /// The requirement in one line: one action's result is **one** keystroke, so the user's ⌘Z puts
    /// back what they had. Nothing here writes `AXSelectedText` — the Accessibility seam has no setter
    /// at all, which is why this holds for every app rather than for the ones we tested.
    @Test func oneMutationIsOneKeystrokeAndTwoWrites() async {
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())

        await replace("once", through: runtime, on: pasteboard, invocation: invocation)

        #expect(pasteboard.pastePosts == 1)
        #expect(pasteboard.copyPosts == 0, "the mutator reads nothing; it was handed the text")
        // Our result up, the user's clipboard back down. Nothing else touches the pasteboard.
        #expect(pasteboard.brokerWrites.count == 2)
        #expect(pasteboard.clears == 2)
    }

    // MARK: Nothing is written without a permit (RUN-2a, RUN-2c, RUN-2d)

    /// A destination that cannot be verified grants no permit, a mutation cannot be called without
    /// one, and so the pasteboard is never touched. The requirement is that there is no second path:
    /// no "paste failed, so copy it for them instead" that would put the result over a clipboard value
    /// the user may have set since.
    @Test func aBlockedVerificationWritesNothingAtAll() async {
        let pasteboard = ScriptedPasteboard(text: held)
        // The user switched away, so the text would land in somebody else's window.
        let runtime = manager(FakeDestinationProbe(DestinationEvidence(isFrontmost: false)), frontmost: terminal)
        let invocation = await runtime.begin(request())

        let report = await replace("THE SELECTED WORDS", through: runtime, on: pasteboard, invocation: invocation)

        #expect(report == nil, "there was no permit, so there was nothing to call")
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.brokerWrites.isEmpty)
        #expect(pasteboard.pastePosts == 0)
        #expect(pasteboard.currentText == held, "their clipboard is theirs, whatever the action produced")
        #expect(await runtime.record(of: invocation)?.mutated == false)
    }

    /// The same, one layer down: the tier itself says no mutation may happen, and there is no way to
    /// make a permit that says otherwise.
    @Test func theUnverifiableTierPermitsNoMutation() {
        #expect(DestinationTier.unverifiable.permitsMutation == false)
        #expect(DestinationTier.quiescence.permitsMutation)
        #expect(DestinationTier.accessibility.permitsMutation)
    }

    // MARK: The run has to still be live (RUN-3b)

    /// A permit is minted before the clipboard work and spent after it, and Escape does not wait its
    /// turn. The check in front of the transaction is what stops a cancelled run from writing.
    @Test func aCancelledRunPastesNothingEvenHoldingAPermit() async {
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())
        let mutator = TextMutator(clipboard: clipboard(pasteboard), manager: runtime)
        guard let permit = await runtime.verifyDestination(of: invocation).permit() else {
            Issue.record("nothing has moved, so the destination verifies")
            return
        }

        await runtime.cancel(invocation, reason: .cancelled)
        let report = await mutator.replaceSelection(with: "too late", using: permit)

        #expect(report.outcome == .notRunning)
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.brokerWrites.isEmpty)
        #expect(await runtime.record(of: invocation)?.mutated == false)
    }

    // MARK: What the clipboard could not do (RUN-2c)

    /// A clipboard that cannot be put back means no paste, and the record says which of the two it was
    /// so that the bar can offer the result for explicit copy instead.
    @Test func aRefusedTransactionIsReportedAndNotRetriedAnotherWay() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(access: .ask)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())

        let report = await replace("result", through: runtime, on: pasteboard, invocation: invocation)

        #expect(report?.outcome == .clipboardRefused(.accessNotAllowed))
        #expect(report?.mutated == false)
        #expect(pasteboard.brokerWrites.isEmpty)
        #expect(pasteboard.currentText == held)
        #expect(await runtime.record(of: invocation)?.mutated == false)
    }

    /// A stranger writing while our result is up is not a mutation that failed — the ⌘V went out and
    /// may well have landed. It is a mutation whose clipboard could not be put back, and the run is
    /// marked as having written, because it probably did.
    @Test func aContestedClipboardIsStillAMutation() async {
        let pasteboard = ScriptedPasteboard(text: held, script: [.foreignWrite("theirs", at: .milliseconds(10))])
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())

        let report = await replace("result", through: runtime, on: pasteboard, invocation: invocation)

        #expect(report?.outcome == .clipboardContested(.foreignWriteWhileHeld))
        #expect(report?.clipboard?.safety == [.foreignWriteBeforeRestore])
        #expect(pasteboard.currentText == "theirs")
        #expect(await runtime.record(of: invocation)?.mutated == true)
    }

    /// A ⌘V that never went out is not a mutation, and the run is not marked as one.
    @Test func anUnpostedKeystrokeIsNotAMutation() async {
        let pasteboard = ScriptedPasteboard(text: held)
        pasteboard.set(pasteCanBePosted: false)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())

        let report = await replace("result", through: runtime, on: pasteboard, invocation: invocation)

        #expect(report?.outcome == .clipboardRefused(.pasteNotPosted))
        #expect(report?.clipboard?.restored == true)
        #expect(pasteboard.currentText == held)
        #expect(await runtime.record(of: invocation)?.mutated == false)
    }

    // MARK: DIA-2

    @Test func noReportCanHoldTheResultOrTheSelection() async {
        let pasteboard = ScriptedPasteboard(text: "her passphrase")
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await runtime.begin(request())

        let report = try! #require(await replace(
            "shibboleth quick brown fox",
            through: runtime,
            on: pasteboard,
            invocation: invocation
        ))

        let found = strings(in: report)
        #expect(!found.contains { $0.contains("shibboleth") || $0.contains("passphrase") })
        #expect(!found.contains { $0.contains("selected words") })
        #expect(found.contains(editor.bundleID!))
        #expect(report.characters == 26)
    }
}

private func strings(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    let mirror = Mirror(reflecting: value)
    guard !mirror.children.isEmpty else { return ["\(value)"] }
    return mirror.children.flatMap { strings(in: $0.value) }
}
