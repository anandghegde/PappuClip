import Foundation
import PappuAnalysis
import PappuAX
import PappuCore
import PappuDiagnostics
import PappuExtensions
import PappuJSBridge
@testable import PappuRuntime
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

/// A prompt that answers as scripted: at once, never (until the run is cancelled), or late, ignoring
/// the cancel, as a panel whose answer raced the Escape key would.
final class FakePrompter: TextPrompting {
    enum Script: Sendable {
        case answer(TextPromptAnswer)
        case waitForCancel
        case late(String)
    }

    private struct State {
        var script: Script
        var asked: [TextPromptRequest] = []
        var closedByCancel = 0
    }

    private let state: Mutex<State>

    init(_ script: Script) {
        state = Mutex(State(script: script))
    }

    var asked: [TextPromptRequest] { state.withLock { $0.asked } }
    var closedByCancel: Int { state.withLock { $0.closedByCancel } }

    func prompt(_ request: TextPromptRequest, for invocation: InvocationID) async -> TextPromptAnswer {
        let script = state.withLock { state -> Script in
            state.asked.append(request)
            return state.script
        }
        switch script {
        case .answer(let answer):
            return answer
        case .waitForCancel:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            state.withLock { $0.closedByCancel += 1 }
            return .cancelled
        case .late(let text):
            // Not a Task.sleep, which a cancel would cut short: this answer is late on purpose.
            let until = ContinuousClock.now + .milliseconds(150)
            while ContinuousClock.now < until { await Task.yield() }
            return .submitted(text)
        }
    }
}

/// JS-17, JS-18, RUN-2e end to end: a JavaScript action in a real helper, its host calls through the
/// real dispatcher, the real manager, verifier, broker and mutator, and fakes only at the edges.
private struct PanelScene {
    let manager: InvocationManager
    let probe: FakeDestinationProbe
    let pasteboard: ScriptedPasteboard
    let prompter: FakePrompter
    let console = DebugConsole()
    let runner: ExtensionRunner
    let effects: HostAPIDispatcher.Effects
    let package: URL

    init(prompt: FakePrompter.Script = .answer(.cancelled)) throws {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled(text: "secret text"))
        let manager = InvocationManager(
            verifier: DestinationVerifier(
                gate: PrivacyGate(PrivacyRules()),
                probe: probe,
                policies: policies(),
                epochs: FakeInput(),
                frontmost: { editor },
                secureInputIsActive: { false },
                timing: .initial,
                now: clock.reader
            ),
            probe: probe,
            epochs: FakeInput(),
            timing: .initial,
            sleeper: FakeSleep(),
            now: clock.reader
        )
        let pasteboard = ScriptedPasteboard(text: "held")
        let broker = ClipboardBroker(
            pasteboard: pasteboard,
            input: pasteboard,
            copy: pasteboard,
            pasting: pasteboard,
            scheduling: pasteboard,
            timing: .initial
        )
        let prompter = FakePrompter(prompt)
        self.manager = manager
        self.probe = probe
        self.pasteboard = pasteboard
        self.prompter = prompter
        let mutator = TextMutator(clipboard: broker, manager: manager)
        let selectionEditor = SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager)
        let presser = KeyPresser(poster: FakeKeyPresses(), manager: manager, sleep: SteppingSleep())
        let groups: [any HostCallHandling] = [PromptHostCalls(manager: manager, prompter: prompter)]
        runner = ExtensionRunner(
            manager: manager,
            editor: selectionEditor,
            mutator: mutator,
            presser: presser,
            clipboard: broker,
            urls: FakeURLOpener(),
            shortcuts: FakeShortcuts(),
            shell: FakeScripts(),
            appleScripts: FakeScripts(),
            services: FakeScripts(),
            javaScript: JSHostClient(transport: InProcessJSHost(), console: console),
            system: FakeHostServices(),
            hostCalls: groups
        )
        effects = HostAPIDispatcher.Effects(
            manager: manager,
            mutator: mutator,
            editor: selectionEditor,
            presser: presser,
            clipboard: broker,
            urls: FakeURLOpener(),
            services: FakeScripts(),
            system: FakeHostServices(),
            groups: groups
        )
        package = FileManager.default.temporaryDirectory.appendingPathComponent("panels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    }

    func action(_ script: String, pappuAfter: PappuAfter? = nil) throws -> CatalogAction {
        let manifest = try ExtensionLoader.loadSnippet("#popclip\nname: Test\nidentifier: com.example.test\njavascript: return 1").manifest
        var action = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)]).actions[0]
        action.manifest.executor = .javaScript(JavaScriptAction(source: .inline(script)))
        action.manifest.pappuAfter = pappuAfter
        action.owner = LocalIdentity().description
        action.directory = package
        return action
    }

    func begin(_ action: CatalogAction) async -> InvocationID {
        await manager.begin(InvocationRequest(
            attempt: AttemptID(rawValue: 1),
            route: .automatic,
            target: editor,
            action: action.key.description,
            mayMutate: action.manifest.mayMutateTheDestination,
            text: "secret text",
            range: AXTextRange(location: 10, length: 5),
            strategy: .ax,
            owner: action.owner
        ))
    }

    func request(_ action: CatalogAction, _ invocation: InvocationID, canPaste: Bool = true) -> ExtensionRunner.Request {
        ExtensionRunner.Request(
            invocation: invocation,
            action: action,
            approval: .approving(action, gates: [.unboundedCode], digest: "abc"),
            match: ActionMatching.Match(narrowing: nil, span: nil, value: "secret text", fullText: "secret text"),
            context: SelectionContext(
                app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                editability: Editability(isEditable: true, source: .settableSelectedText),
                canCut: true,
                canCopy: true,
                canPaste: canPaste,
                hasFormatting: false
            ),
            target: editor
        )
    }

    func run(_ script: String, pappuAfter: PappuAfter? = nil, canPaste: Bool = true) async throws -> ExtensionRunner.Report {
        let action = try action(script, pappuAfter: pappuAfter)
        let invocation = await begin(action)
        return await runner.run(request(action, invocation, canPaste: canPaste))
    }

    /// A dispatcher for a run in `phase`, with the prompt group, outside any script.
    func dispatcher(phase: HostPhase) async throws -> HostAPIDispatcher {
        let action = try action("return 1")
        let invocation = await begin(action)
        return HostAPIDispatcher(
            run: HostAPIDispatcher.Run(
                invocation: invocation,
                phase: phase,
                gates: [.unboundedCode],
                context: request(action, invocation).context,
                target: editor,
                text: "secret text",
                action: action
            ),
            effects: effects
        )
    }

    /// The plain text of every set of items the broker wrote, in order.
    var written: [String] {
        pasteboard.brokerWrites.compactMap { items in
            items.first?.first { $0.type == PasteboardRepresentation.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
        }
    }
}

@Suite struct RichResultAndPromptTests {
    // MARK: JS-17: the rich result

    /// `pappuAfter: rich-result`: the whole result goes to the panel, and nothing is copied or pasted
    /// until a button says so. The invocation stays live for the panel; closing it finishes it.
    @Test func pappuAfterRichResultOpensAPanelAndWritesNothing() async throws {
        let scene = try PanelScene()
        let long = String(repeating: "x", count: 300)
        let report = try await scene.run("return '\(long)'", pappuAfter: .richResult)
        #expect(report.outcome == .done)
        #expect(report.display == .richResult(RichResult(text: long, format: .text)))
        let session = try #require(report.session)
        #expect(session.result.text.count == 300)
        #expect(await scene.manager.accepts(report.invocation))
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(scene.pasteboard.currentText == "held")

        await session.close()
        #expect(session.hasEnded)
        #expect(await scene.manager.state(of: report.invocation) == .finished(.completed))
    }

    @Test func showResultOpensThePanelWithItsFormat() async throws {
        let scene = try PanelScene()
        let report = try await scene.run("popclip.showResult('**bold**', { format: 'markdown' })")
        #expect(report.display == .richResult(RichResult(text: "**bold**", format: .markdown)))
        let session = try #require(report.session)
        await session.close()
    }

    /// An action that returns nothing has nothing to show, and its invocation ends as any other.
    @Test func anEmptyResultOpensNoPanel() async throws {
        let scene = try PanelScene()
        let report = try await scene.run("return ''", pappuAfter: .richResult)
        #expect(report.outcome == .done)
        #expect(report.session == nil)
        #expect(await scene.manager.state(of: report.invocation) == .finished(.completed))
    }

    /// `showResult` is recorded as the dispatcher's request, like `showText`, and refused during
    /// population with every other method.
    @Test func showResultIsARequestOfTheRunAndNothingElse() async throws {
        let scene = try PanelScene()
        let host = try await scene.dispatcher(phase: .action)
        #expect(await host.perform(JSHostCall(invocation: 1, extensionName: "a", method: "showResult", arguments: #"{"text":"hi"}"#)) == .done)
        #expect(host.requests.display == .rich(RichResult(text: "hi", format: .text)))
        let refused = await host.perform(JSHostCall(invocation: 1, extensionName: "a", method: "showResult", arguments: #"{"text":"hi","format":"html"}"#))
        #expect(refused == .refused("showResult was not given what it takes."))
        #expect(scene.pasteboard.brokerWrites.isEmpty)
    }

    // MARK: RUN-2e: Replace and Insert verify at the click

    @Test func replaceVerifiesAtTheClickAndCopyStaysAvailable() async throws {
        let scene = try PanelScene()
        let report = try await scene.run("return 'RESULT'", pappuAfter: .richResult)
        let session = try #require(report.session)
        #expect(await session.destination() == .available)

        // The user clicked elsewhere in the field after the panel opened.
        scene.probe.evidence = settled(range: AXTextRange(location: 3, length: 5), text: "secret text")
        #expect(await session.destination() == .unavailable([.selectionMoved]))
        #expect(await session.replace() == .refused([.selectionMoved]))
        #expect(await session.insert() == .refused([.selectionMoved]))
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(scene.pasteboard.brokerWrites.isEmpty)

        // Copy does not care where the text came from.
        #expect(await session.copy())
        #expect(scene.pasteboard.currentText == "RESULT")

        // Back where it was, and the click is checked again: this time it verifies.
        scene.probe.evidence = settled(text: "secret text")
        #expect(await session.replace() == .written)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.written.last == "RESULT")
        await session.close()
    }

    /// BAR-17: Insert keeps the selection and puts the result after it (in this build, as one paste of
    /// both under one permit).
    @Test func insertKeepsTheSelectionAndPutsTheResultAfterIt() async throws {
        let scene = try PanelScene()
        let report = try await scene.run("return ' and more'", pappuAfter: .richResult)
        let session = try #require(report.session)
        #expect(await session.insert() == .written)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.written.contains("secret text and more"))
        await session.close()
    }

    /// Paste was not available at the click: Replace and Insert are never offered, and Copy is.
    @Test func withoutPasteOnlyCopyIsOffered() async throws {
        let scene = try PanelScene()
        let report = try await scene.run("return 'RESULT'", pappuAfter: .richResult, canPaste: false)
        let session = try #require(report.session)
        #expect(await session.destination() == .unavailable([.notEditable]))
        #expect(await session.replace() == .refused([.notEditable]))
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(await session.copy())
        await session.close()
    }

    /// RUN-3f: cancelling, pausing or revoking the invocation closes the panel, and a click that
    /// arrives afterwards writes nothing.
    @Test func cancellingOrPausingTheInvocationClosesThePanel() async throws {
        for reason in [InvocationInvalidation.cancelled, .paused, .revoked] {
            let scene = try PanelScene()
            let report = try await scene.run("return 'RESULT'", pappuAfter: .richResult)
            let session = try #require(report.session)
            let heard = Mutex(0)
            session.onEnd { heard.withLock { $0 += 1 } }
            if reason == .paused {
                await scene.manager.invalidateAll(.paused)
            } else {
                await scene.manager.cancel(report.invocation, reason: reason)
            }
            #expect(heard.withLock { $0 } == 1)
            #expect(session.hasEnded)
            #expect(await session.replace() == .ended)
            #expect(await session.destination() == .ended)
            #expect(scene.pasteboard.pastePosts == 0)
            // Closing afterwards does not turn a cancelled run into a completed one.
            await session.close()
            #expect(await scene.manager.state(of: report.invocation) == .invalidated(reason))
        }
    }

    // MARK: JS-18: the prompt

    @Test func promptTextResolvesToWhatWasSubmittedEvenEmpty() async throws {
        let scene = try PanelScene(prompt: .answer(.submitted("")))
        let report = try await scene.run("const v = await pappuclip.promptText({ label: 'Name', placeholder: 'you' }); await popclip.copyText('got:' + v)")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.currentText == "got:")
        #expect(scene.prompter.asked == [TextPromptRequest(label: "Name", placeholder: "you", defaultValue: "", source: "Test")])
    }

    /// RUN-3: Cancel, Escape or closing the prompt cancels the invocation, not only the prompt.
    @Test func cancellingThePromptCancelsTheInvocation() async throws {
        let scene = try PanelScene(prompt: .answer(.cancelled))
        let report = try await scene.run("const v = await popclip.promptText({ label: 'Name' }); await popclip.copyText(v)")
        #expect(report.outcome == .notRunning)
        #expect(await scene.manager.state(of: report.invocation) == .invalidated(.cancelled))
        #expect(scene.pasteboard.brokerWrites.isEmpty)
    }

    /// The other way round: the run is cancelled while the prompt is up, and the prompt closes.
    @Test func cancellingTheInvocationClosesThePrompt() async throws {
        let scene = try PanelScene(prompt: .waitForCancel)
        let action = try scene.action("const v = await popclip.promptText({ label: 'Name' }); await popclip.copyText(v)")
        let invocation = await scene.begin(action)
        let running = Task { await scene.runner.run(scene.request(action, invocation)) }
        #expect(await patiently { scene.prompter.asked.count == 1 })
        await scene.manager.cancel(invocation)
        #expect(await running.value.outcome == .notRunning)
        #expect(await patiently { scene.prompter.closedByCancel == 1 })
        #expect(scene.pasteboard.brokerWrites.isEmpty)
    }

    /// JS-15 for the prompt: an answer that arrives after the cancel has no effect.
    @Test func aPromptAnsweredAfterCancelHasNoEffect() async throws {
        let scene = try PanelScene(prompt: .late("late"))
        let action = try scene.action("const v = await popclip.promptText({ label: 'Name' }); await popclip.copyText(v); return v")
        let invocation = await scene.begin(action)
        let running = Task { await scene.runner.run(scene.request(action, invocation)) }
        #expect(await patiently { scene.prompter.asked.count == 1 })
        await scene.manager.cancel(invocation)
        #expect(await running.value.outcome == .notRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(scene.pasteboard.currentText == "held")
    }

    /// JS-13: never during population. And a label is required.
    @Test func promptTextIsRefusedDuringPopulationAndWithoutALabel() async throws {
        let scene = try PanelScene(prompt: .answer(.submitted("x")))
        let population = try await scene.dispatcher(phase: .population)
        let call = JSHostCall(invocation: 1, extensionName: "a", method: "promptText", arguments: #"{"label":"Name"}"#)
        guard case .refused = await population.perform(call) else {
            Issue.record("promptText was not refused during population")
            return
        }
        let action = try await scene.dispatcher(phase: .action)
        #expect(await action.perform(JSHostCall(invocation: 1, extensionName: "a", method: "promptText", arguments: #"{"label":"  "}"#)) == .refused("promptText needs a label."))
        #expect(await action.perform(JSHostCall(invocation: 1, extensionName: "a", method: "promptText", arguments: #"{}"#)) == .refused("promptText was not given what it takes."))
        #expect(scene.prompter.asked.isEmpty)
        #expect(await action.perform(call) == .value(#""x""#))
    }
}

/// `eventually`, with room for a JavaScript helper to start while the rest of the suite runs.
private func patiently(_ condition: @Sendable () -> Bool) async -> Bool {
    let until = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < until {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
