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

/// M3 week 3 end to end: a JavaScript action run by `ExtensionRunner`, in a real helper (in this
/// process), whose host calls come back through `JSHostClient` to a real `HostAPIDispatcher`.
///
/// The week's "done when" is two of these: a call outside the grants fails and is logged without
/// content, and a promise that resolves after cancel has no effect.
private struct JavaScriptScene {
    let manager: InvocationManager
    let pasteboard: ScriptedPasteboard
    let keys = FakeKeyPresses()
    let opener = FakeURLOpener()
    let console = DebugConsole()
    let runner: ExtensionRunner
    let package: URL

    init() throws {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())
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
        self.manager = manager
        self.pasteboard = pasteboard
        runner = ExtensionRunner(
            manager: manager,
            editor: SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager),
            mutator: TextMutator(clipboard: broker, manager: manager),
            presser: KeyPresser(poster: keys, manager: manager, sleep: SteppingSleep()),
            clipboard: broker,
            urls: opener,
            shortcuts: FakeShortcuts(),
            shell: FakeScripts(),
            appleScripts: FakeScripts(),
            services: FakeScripts(),
            javaScript: JSHostClient(transport: InProcessJSHost(), console: console),
            system: FakeHostServices()
        )
        package = FileManager.default.temporaryDirectory.appendingPathComponent("js-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    }

    /// A JavaScript action with this script, installed in its own package.
    func action(_ script: String) throws -> CatalogAction {
        let manifest = try ExtensionLoader.loadSnippet("#popclip\nname: Test\nidentifier: com.example.test\njavascript: return 1").manifest
        var action = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)]).actions[0]
        action.manifest.executor = .javaScript(JavaScriptAction(source: .inline(script)))
        action.owner = LocalIdentity().description
        action.directory = package
        action.booleanOptions = ["flag"]
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

    func request(
        _ action: CatalogAction,
        _ invocation: InvocationID,
        gates: Set<GatedCapability> = [.unboundedCode],
        modifiers: PointerEvent.Modifiers = [],
        selection: AnalyzedSelection? = nil
    ) -> ExtensionRunner.Request {
        ExtensionRunner.Request(
            invocation: invocation,
            action: action,
            approval: .approving(action, gates: gates, digest: "abc"),
            match: ActionMatching.Match(narrowing: nil, span: nil, value: "secret text", fullText: "secret text"),
            context: SelectionContext(
                app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                editability: Editability(isEditable: true, source: .settableSelectedText),
                canCut: true,
                canCopy: true,
                canPaste: true,
                hasFormatting: true,
                browser: BrowserPage(url: URL(string: "https://example.com/page"), title: "Page", source: .accessibility)
            ),
            target: editor,
            modifiers: modifiers,
            options: ["flag": "1", "name": "value"],
            selection: selection
        )
    }

    func run(
        _ script: String,
        gates: Set<GatedCapability> = [.unboundedCode],
        modifiers: PointerEvent.Modifiers = [],
        selection: AnalyzedSelection? = nil
    ) async throws -> ExtensionRunner.Report {
        let action = try action(script)
        let invocation = await begin(action)
        return await runner.run(request(action, invocation, gates: gates, modifiers: modifiers, selection: selection))
    }
}

@Suite struct JavaScriptHostTests {
    /// SEC-7b, the week's "done when": the call fails, the script hears why, and the Debug Console
    /// says which method and why — and nothing of the selection.
    @Test func aCallOutsideTheGrantsFailsAndIsLoggedWithoutContent() async throws {
        let scene = try JavaScriptScene()
        let report = try await scene.run("await popclip.pressKey('command b'); return 'pressed'")
        #expect(report.outcome == .notPerformed)
        #expect(scene.keys.combos.isEmpty)
        let refused = scene.console.entries.filter { $0.kind == .refused }
        #expect(refused.map(\.text) == ["pressKeys: pressKeys needs the synthetic-input permission, which this extension does not have."])
        #expect(!scene.console.entries.contains(where: { $0.text.contains("secret") }))

        let granted = try await scene.run("await popclip.pressKey('command b'); return 'pressed'", gates: [.unboundedCode, .syntheticInput])
        #expect(granted.outcome == .done)
        #expect(scene.keys.combos.count == 1)
    }

    /// JS-15, the week's "done when": the run is cancelled while its script waits, and when the script
    /// carries on and asks for a copy, nothing happens.
    @Test func aPromiseThatResolvesAfterCancelHasNoEffect() async throws {
        let scene = try JavaScriptScene()
        let action = try scene.action("await sleep(150); await popclip.copyText('late'); return 'late'")
        let invocation = await scene.begin(action)
        let running = Task { await scene.runner.run(scene.request(action, invocation)) }
        try await Task.sleep(for: .milliseconds(40))
        await scene.manager.cancel(invocation)
        #expect(await running.value.outcome == .notRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(scene.pasteboard.currentText == "held")
    }

    @Test func pasteTextPastesThroughTheWholePath() async throws {
        let scene = try JavaScriptScene()
        let report = try await scene.run("await popclip.pasteText(popclip.input.text.toUpperCase())")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.pasteboard.currentText == "SECRET TEXT")
    }

    @Test func whatTheScriptShowsIsWhatTheBarShows() async throws {
        let scene = try JavaScriptScene()
        #expect(try await scene.run("popclip.showText('hello')").display == .result("hello"))
        #expect(try await scene.run("await popclip.copyText('x')").display == .copied)
        #expect(try await scene.run("popclip.appear()").display == .reappear)
        #expect(try await scene.run("popclip.showFailure()").display == .failure)
        #expect(try await scene.run("popclip.showSettings()").attention == .settings)
    }

    /// JS-3: the state a script reads, as the runner fills it in.
    @Test func popclipDescribesTheSelectionAndWhereItCameFrom() async throws {
        let scene = try JavaScriptScene()
        let selection = AnalyzedSelection(text: "secret text", detections: [
            Detection(kind: .url, span: TextSpan(location: 0, length: 6), value: "https://secret"),
        ])
        let script = """
        return JSON.stringify([popclip.input.data.urls, popclip.input.data.urls.ranges, popclip.context, popclip.modifiers.option, popclip.options.flag, popclip.options.name])
        """
        let report = try await scene.run(script.replacingOccurrences(of: "\n", with: " "), modifiers: [.option], selection: selection)
        #expect(report.outcome == .done)
        let returned = try #require(scene.console.entries.first(where: { $0.kind == .returned })?.text)
        let expected = #"[["https://secret"],[{"location":0,"length":6}],{"hasFormatting":true,"canPaste":true,"canCopy":true,"canCut":true,"browserUrl":"https://example.com/page","browserTitle":"Page","appName":"Editor","appIdentifier":"com.example.editor"},true,true,"value"]"#
        #expect(returned == expected)
    }
}
