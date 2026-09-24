import Foundation
import PappuAnalysis
import PappuAX
import PappuCore
import PappuExtensions
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

private let selectedRange = AXTextRange(location: 10, length: 5)
private let held = "the user's own clipboard"
private let matching = settled(range: selectedRange, text: "selected")

// MARK: Fakes

/// The key-press poster, as a list of what it was asked to press and where.
final class FakeKeyPresses: SyntheticKeyPressPosting {
    private let posted = Mutex<[(KeyCombo, KeyPressDelivery)]>([])
    private let refuses: Bool

    init(refuses: Bool = false) {
        self.refuses = refuses
    }

    var combos: [KeyCombo] { posted.withLock { $0.map(\.0) } }
    var deliveries: [KeyPressDelivery] { posted.withLock { $0.map(\.1) } }

    func post(_ combo: KeyCombo, to delivery: KeyPressDelivery) -> Bool {
        guard !refuses else { return false }
        posted.withLock { $0.append((combo, delivery)) }
        return true
    }
}

/// A sleep that does something in the middle of a `wait` step — cancelling, in the test that needs
/// a user to press Escape between two combos.
final class SteppingSleep: InvocationSleeping {
    private let slept = Mutex<[Duration]>([])
    private let during: @Sendable () async -> Void

    init(during: @escaping @Sendable () async -> Void = {}) {
        self.during = during
    }

    var durations: [Duration] { slept.withLock { $0 } }

    func sleep(for duration: Duration) async {
        slept.withLock { $0.append(duration) }
        await during()
    }
}

/// Shortcuts, answering what the test says, optionally only once a gate opens.
final class FakeShortcuts: ShortcutRunning {
    final class Run: ShortcutRun {
        let ownership = WorkOwnership.delegated
        private let answer: ShortcutResult
        private let gate: Gate?
        private let asked = Atomic<Int>(0)

        init(answer: ShortcutResult, gate: Gate?) {
            self.answer = answer
            self.gate = gate
        }

        var timesCancelled: Int { asked.load(ordering: .relaxed) }

        func cancel() async -> WorkCancellation {
            asked.wrappingAdd(1, ordering: .relaxed)
            return .askedToStop
        }

        func result() async -> ShortcutResult {
            await gate?.wait()
            return answer
        }
    }

    let run: Run
    private let starts: Bool
    private let started = Mutex<[(name: String, input: String)]>([])

    init(_ answer: ShortcutResult = .returned(nil), starts: Bool = true, gate: Gate? = nil) {
        run = Run(answer: answer, gate: gate)
        self.starts = starts
    }

    var calls: [(name: String, input: String)] { started.withLock { $0 } }

    func start(_ name: String, input: String) -> (any ShortcutRun)? {
        started.withLock { $0.append((name, input)) }
        return starts ? run : nil
    }
}

/// Shell scripts, AppleScripts and Services in one fake: each start is recorded, and every run
/// answers what the test says, optionally only once a gate opens.
final class FakeScripts: ShellScriptRunning, AppleScriptRunning, ServiceRunning {
    enum Started: Sendable, Equatable {
        case shell(ShellScriptAction, directory: URL?, variables: ScriptVariables)
        case appleScript(AppleScriptRunRequest)
        case service(name: String, text: String)
    }

    final class Run: ScriptRun {
        let ownership: WorkOwnership
        private let answer: ScriptResult
        private let gate: Gate?
        private let asked = Atomic<Int>(0)

        init(answer: ScriptResult, gate: Gate?, ownership: WorkOwnership) {
            self.answer = answer
            self.gate = gate
            self.ownership = ownership
        }

        var timesCancelled: Int { asked.load(ordering: .relaxed) }

        func cancel() async -> WorkCancellation {
            asked.wrappingAdd(1, ordering: .relaxed)
            return ownership == .owned ? .stopped : .askedToStop
        }

        func result() async -> ScriptResult {
            await gate?.wait()
            return answer
        }
    }

    let run: Run
    private let starts: Bool
    private let started = Mutex<[Started]>([])

    init(_ answer: ScriptResult = .returned(nil), starts: Bool = true, gate: Gate? = nil, ownership: WorkOwnership = .owned) {
        run = Run(answer: answer, gate: gate, ownership: ownership)
        self.starts = starts
    }

    var calls: [Started] { started.withLock { $0 } }

    private func record(_ start: Started) -> (any ScriptRun)? {
        started.withLock { $0.append(start) }
        return starts ? run : nil
    }

    func start(_ job: ShellScriptJob) async -> (any ScriptRun)? {
        record(.shell(job.action, directory: job.directory, variables: job.variables))
    }

    func start(_ job: AppleScriptRunRequest) async -> (any ScriptRun)? {
        record(.appleScript(job))
    }

    func start(service name: String, text: String) async -> (any ScriptRun)? {
        record(.service(name: name, text: text))
    }
}

// MARK: The scene
//
// As in `BuiltinRunnerTests`: the real manager, verifier, broker, editor and mutator, with fakes only
// at the edges of the process.

private struct Scene {
    let manager: InvocationManager
    let pasteboard: ScriptedPasteboard
    let opener = FakeURLOpener()
    let keys: FakeKeyPresses
    let shortcuts: FakeShortcuts
    let scripts: FakeScripts
    let runner: ExtensionRunner

    init(
        probe: FakeDestinationProbe = FakeDestinationProbe(matching),
        frontmost: TargetApp? = editor,
        clipboard: String? = held,
        keys: FakeKeyPresses = FakeKeyPresses(),
        shortcuts: FakeShortcuts = FakeShortcuts(),
        scripts: FakeScripts = FakeScripts(),
        sleep: (any InvocationSleeping)? = nil,
        manager: InvocationManager? = nil
    ) {
        let clock = ManualTimeSource()
        let manager = manager ?? InvocationManager(
            verifier: DestinationVerifier(
                gate: PrivacyGate(PrivacyRules()),
                probe: probe,
                policies: policies(),
                epochs: FakeInput(),
                frontmost: { frontmost },
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
        let pasteboard = ScriptedPasteboard(text: clipboard)
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
        self.keys = keys
        self.shortcuts = shortcuts
        self.scripts = scripts
        runner = ExtensionRunner(
            manager: manager,
            editor: SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager),
            mutator: TextMutator(clipboard: broker, manager: manager),
            presser: KeyPresser(poster: keys, manager: manager, sleep: sleep ?? SteppingSleep()),
            clipboard: broker,
            urls: opener,
            shortcuts: shortcuts,
            shell: scripts,
            appleScripts: scripts,
            services: scripts
        )
    }

    /// The first action of a snippet, as the catalog would hold it.
    static func action(_ body: String) throws -> CatalogAction {
        let manifest = try ExtensionLoader.loadSnippet("#popclip\nname: Test\nidentifier: com.example.test\n\(body)").manifest
        return ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)]).actions[0]
    }

    func begin(_ action: CatalogAction, text: String = "selected") async -> InvocationID {
        await manager.begin(InvocationRequest(
            attempt: AttemptID(rawValue: 1),
            route: .automatic,
            target: editor,
            action: action.key.description,
            mayMutate: action.manifest.mayMutateTheDestination,
            text: text,
            range: selectedRange,
            strategy: .ax,
            owner: action.owner
        ))
    }

    func run(
        _ body: String,
        value: String = "selected",
        fullText: String? = nil,
        canPaste: Bool = true,
        browser: BrowserPage? = nil,
        modifiers: PointerEvent.Modifiers = [],
        options: [String: String] = [:],
        selection: AnalyzedSelection? = nil,
        directory: URL? = nil,
        // A snippet cannot name a file (FMT-3), so a file-based executor is put in afterwards.
        executor: ActionExecutor? = nil,
        whileBegun: @Sendable (InvocationID) async -> Void = { _ in }
    ) async throws -> (ExtensionRunner.Report, InvocationID) {
        var action = try Self.action(body)
        action.directory = directory
        if let executor { action.manifest.executor = executor }
        let invocation = await begin(action)
        await whileBegun(invocation)
        let report = await runner.run(ExtensionRunner.Request(
            invocation: invocation,
            action: action,
            approval: .approving(action),
            match: ActionMatching.Match(narrowing: nil, span: nil, value: value, fullText: fullText ?? value),
            context: SelectionContext(
                app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                editability: Editability(isEditable: true, source: .settableSelectedText),
                canCut: true,
                canCopy: true,
                canPaste: canPaste,
                browser: browser
            ),
            target: editor,
            modifiers: modifiers,
            options: options,
            selection: selection
        ))
        return (report, invocation)
    }

    /// Every text PappuClip wrote to the clipboard, in order.
    var writtenTexts: [String] {
        pasteboard.brokerWrites.compactMap { items in
            items.first?.first { $0.type == PasteboardRepresentation.plainText }
                .map { String(decoding: $0.data, as: UTF8.self) }
        }
    }
}

// MARK: URL (§8.4)

@Suite struct ExtensionRunnerURLTests {
    @Test func theTemplateIsExpandedAndOpened() async throws {
        let scene = Scene()
        let (report, invocation) = try await scene.run(
            "url: https://{popclip option site}/s?k=***",
            value: " two words ",
            options: ["site": "example.com"]
        )
        #expect(report.outcome == .done)
        #expect(scene.opener.urls == [URL(string: "https://example.com/s?k=two%20words")!])
        #expect(scene.opener.requests.map(\.activates) == [true])
        #expect(scene.opener.requests.map(\.browserBundleID) == [nil])
        #expect(await scene.manager.record(of: invocation)?.outcome == .completed)
        #expect(await scene.manager.record(of: invocation)?.mayMutate == false)
    }

    @Test func shiftIsTheBackgroundAndOptionQuotes() async throws {
        let scene = Scene()
        _ = try await scene.run("url: https://x.test/?q=***", value: "a b", modifiers: [.shift, .option])
        #expect(scene.opener.urls == [URL(string: "https://x.test/?q=%22a%20b%22")!])
        #expect(scene.opener.requests.map(\.activates) == [false])
    }

    @Test func aBrowserPageOpensInTheSameBrowser() async throws {
        let scene = Scene()
        _ = try await scene.run("url: https://x.test/?q=***", browser: BrowserPage(url: URL(string: "https://example.com"), title: "Example", source: .accessibility))
        #expect(scene.opener.requests.map(\.browserBundleID) == [editor.bundleID])
    }

    @Test func anExpansionThatIsNotAURLFails() async throws {
        let scene = Scene()
        let (report, invocation) = try await scene.run(
            "url: https://{popclip option site}/?q=***",
            options: ["site": "not a host"]
        )
        #expect(report.outcome == .notPerformed)
        #expect(report.stage == .executor)
        #expect(scene.opener.requests.isEmpty)
        #expect(await scene.manager.record(of: invocation)?.outcome == .failed)
    }
}

// MARK: Key Press (§8.4)

@Suite struct ExtensionRunnerKeyPressTests {
    @Test func theSequenceIsPressedInOrderWithItsWaits() async throws {
        let sleep = SteppingSleep()
        let scene = Scene(sleep: sleep)
        let (report, invocation) = try await scene.run("keyCombos: [command a, wait 150, shift f5]")
        #expect(report.outcome == .done)
        #expect(report.keyPress?.pressed == 2)
        #expect(report.keyPress?.tier == .accessibility)
        #expect(scene.keys.combos == [
            KeyCombo(modifiers: .command, key: .character("a")),
            KeyCombo(modifiers: .shift, key: .code(0x60)),
        ])
        #expect(scene.keys.deliveries.map(\.target) == [.session, .session])
        #expect(sleep.durations == [.milliseconds(150)])
        #expect(await scene.manager.record(of: invocation)?.mayMutate == true)
        #expect(await scene.manager.record(of: invocation)?.mutated == true)
    }

    @Test func theAppTargetIsTheVerifiedProcess() async throws {
        let scene = Scene()
        _ = try await scene.run("keyCombo: return\nkeyComboTarget: app")
        #expect(scene.keys.deliveries == [KeyPressDelivery(target: .app, processID: editor.pid)])
    }

    /// RUN-2a: a key press is synthetic input, so a destination that moved gets nothing.
    @Test func anUnverifiableDestinationGetsNoKeys() async throws {
        let scene = Scene(probe: FakeDestinationProbe(DestinationEvidence(isFrontmost: false)), frontmost: terminal)
        let (report, invocation) = try await scene.run("keyCombo: command b")
        #expect(report.block?.primary == .notFrontmost)
        #expect(scene.keys.combos.isEmpty)
        #expect(await scene.manager.record(of: invocation)?.outcome == .blocked)
    }

    /// RUN-3b: Escape during a `wait` stops the rest of the sequence. What went out stays out.
    @Test func cancellingDuringAWaitStopsTheRest() async throws {
        let target = Box<InvocationID?>(nil)
        let managerBox = Box<InvocationManager?>(nil)
        let sleep = SteppingSleep {
            if let invocation = target.current { await managerBox.current?.cancel(invocation) }
        }
        let scene = Scene(sleep: sleep)
        managerBox.current = scene.manager
        let (report, invocation) = try await scene.run(
            "keyCombos: [command a, wait 50, command c]",
            whileBegun: { target.current = $0 }
        )
        #expect(report.outcome == .notRunning)
        #expect(report.keyPress?.pressed == 1)
        #expect(scene.keys.combos == [KeyCombo(modifiers: .command, key: .character("a"))])
        #expect(await scene.manager.record(of: invocation)?.invalidation == .cancelled)
    }

    @Test func aComboThatCannotBePostedFails() async throws {
        let scene = Scene(keys: FakeKeyPresses(refuses: true))
        let (report, invocation) = try await scene.run("keyCombo: command b")
        #expect(report.outcome == .notPerformed)
        #expect(await scene.manager.record(of: invocation)?.outcome == .failed)
    }
}

// MARK: Shortcut (§8.4)

@Suite struct ExtensionRunnerShortcutTests {
    @Test func theSelectionGoesInAndTheResultGoesToAfter() async throws {
        let scene = Scene(shortcuts: FakeShortcuts(.returned("SHOUTED")))
        let (report, _) = try await scene.run("shortcutName: Shout\nafter: copy-result", value: "shouted")
        #expect(scene.shortcuts.calls.map(\.name) == ["Shout"])
        #expect(scene.shortcuts.calls.map(\.input) == ["shouted"])
        #expect(report.outcome == .done)
        #expect(report.returnedText)
        #expect(report.display == .copied)
        #expect(scene.pasteboard.currentText == "SHOUTED")
    }

    @Test func aShortcutThatFailsOrCannotStartFails() async throws {
        for shortcuts in [FakeShortcuts(.failed), FakeShortcuts(starts: false)] {
            let scene = Scene(shortcuts: shortcuts)
            let (report, invocation) = try await scene.run("shortcutName: Shout\nafter: copy-result")
            #expect(report.outcome == .notPerformed)
            #expect(scene.pasteboard.brokerWrites.isEmpty)
            #expect(await scene.manager.record(of: invocation)?.outcome == .failed)
        }
    }

    /// RUN-3c, RUN-3e: the run is attached, so cancelling asks the Shortcut to stop — and what it
    /// returns afterwards is dropped at the gate rather than copied.
    @Test func aResultThatArrivesAfterCancellationIsDropped() async throws {
        let gate = Gate()
        let shortcuts = FakeShortcuts(.returned("late"), gate: gate)
        let scene = Scene(shortcuts: shortcuts)
        let action = try Scene.action("shortcutName: Shout\nafter: copy-result")
        let invocation = await scene.begin(action)
        let running = Task {
            await scene.runner.run(ExtensionRunner.Request(
                invocation: invocation,
                action: action,
                approval: .approving(action),
                match: ActionMatching.Match(narrowing: nil, span: nil, value: "x", fullText: "x"),
                context: SelectionContext(
                    app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                    editability: Editability(isEditable: true, source: .settableSelectedText),
                    canCut: true, canCopy: true, canPaste: true
                ),
                target: editor
            ))
        }
        #expect(await eventually { !shortcuts.calls.isEmpty })
        // Whether this lands before or after the runner attaches the run, the run is asked to stop
        // exactly once: by the manager if it was attached, by the runner if attaching was refused.
        await scene.manager.cancel(invocation)
        await gate.open()
        let ended = await running.value
        #expect(ended.outcome == .notRunning)
        #expect(shortcuts.run.timesCancelled == 1)
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(await scene.manager.record(of: invocation)?.outcome == nil)
    }
}

// MARK: Approval (EXM-5, SEC-4b, SEC-7d)

/// The runner's half of "no extension code path is reachable without an `ExecutionApproval`": the
/// resolver never offers an unapproved action, and a request assembled some other way is refused here
/// before any stage runs.
@Suite struct ExtensionRunnerApprovalTests {
    private static func request(
        _ action: CatalogAction,
        _ approval: ExecutionApproval,
        invocation: InvocationID
    ) -> ExtensionRunner.Request {
        ExtensionRunner.Request(
            invocation: invocation,
            action: action,
            approval: approval,
            match: ActionMatching.Match(narrowing: nil, span: nil, value: "x", fullText: "x"),
            context: SelectionContext(
                app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                editability: Editability(isEditable: true, source: .settableSelectedText),
                canCut: true, canCopy: true, canPaste: true
            ),
            target: editor
        )
    }

    @Test func anApprovalForAnotherExtensionRunsNothing() async throws {
        let scene = Scene()
        var action = try Scene.action("shortcutName: Shout")
        action.owner = LocalIdentity().description
        let invocation = await scene.begin(action)
        let report = await scene.runner.run(Self.request(action, .approvingSomethingElse(than: action), invocation: invocation))
        #expect(report.outcome == .notRunning)
        #expect(scene.shortcuts.calls.isEmpty)
    }

    /// EXM-5d, SEC-7d: a shell script needs `script`, and an approval without it is not enough.
    @Test func aGateLeftAtDontAllowRunsNothing() async throws {
        let scene = Scene()
        var action = try Scene.action("shellScript: echo hi")
        action.owner = LocalIdentity().description
        #expect(action.gates == [.script])
        let invocation = await scene.begin(action)
        let report = await scene.runner.run(Self.request(action, .approving(action, gates: []), invocation: invocation))
        #expect(report.outcome == .notRunning)
        #expect(scene.scripts.calls.isEmpty)
    }

    /// SEC-4b, RUN-3f: revoking an extension invalidates its running invocation — the Shortcut is
    /// asked to stop, what it returns is dropped, and the record says why.
    @Test func revokingTheExtensionInvalidatesItsRunningInvocation() async throws {
        let gate = Gate()
        let shortcuts = FakeShortcuts(.returned("late"), gate: gate)
        let scene = Scene(shortcuts: shortcuts)
        var action = try Scene.action("shortcutName: Shout\nafter: copy-result")
        let owner = LocalIdentity().description
        action.owner = owner
        let invocation = await scene.begin(action)
        let running = Task { await scene.runner.run(Self.request(action, .approving(action), invocation: invocation)) }
        #expect(await eventually { !shortcuts.calls.isEmpty })

        #expect(await scene.manager.invalidate(ownedBy: LocalIdentity().description).isEmpty)
        let reports = await scene.manager.invalidate(ownedBy: owner)
        #expect(reports.map(\.invocation) == [invocation])
        await gate.open()
        let ended = await running.value
        #expect(ended.outcome == .notRunning)
        #expect(shortcuts.run.timesCancelled == 1)
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(await scene.manager.record(of: invocation)?.invalidation == .revoked)
    }
}

// MARK: Service, AppleScript and Shell Script (§8.4, §8.7)

@Suite struct ExtensionRunnerScriptTests {
    private static func shellVariables(_ scene: Scene) -> ScriptVariables? {
        guard case .shell(_, _, let variables) = scene.scripts.calls.first else { return nil }
        return variables
    }

    private static func package() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("pappu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return package
    }

    @Test func aShellScriptsResultGoesToAfter() async throws {
        let scene = Scene(scripts: FakeScripts(.returned("LOUD")))
        let (report, invocation) = try await scene.run("shellScript: tr a-z A-Z\nafter: copy-result", value: "loud")
        #expect(report.outcome == .done)
        #expect(report.returnedText)
        #expect(report.attention == nil)
        #expect(scene.writtenTexts == ["LOUD"])
        #expect(await scene.manager.record(of: invocation)?.outcome == .completed)
    }

    /// §8.7: the table a script is given is made from the run.
    @Test func aShellScriptIsToldAboutItsSelection() async throws {
        let scene = Scene()
        _ = try await scene.run(
            "shellScript: env",
            value: "https://example.com",
            fullText: "see https://example.com",
            browser: BrowserPage(url: URL(string: "https://example.com/page"), title: "Page", source: .accessibility),
            modifiers: [.shift, .command],
            options: ["apiKey": "k"],
            selection: AnalyzedSelection(text: "see https://example.com", detections: [
                Detection(kind: .url, span: TextSpan(location: 4, length: 19), value: "https://example.com"),
            ])
        )
        let variables = try #require(Self.shellVariables(scene))
        #expect(variables.values["TEXT"] == "https://example.com")
        #expect(variables.values["FULL_TEXT"] == "see https://example.com")
        #expect(variables.values["URLS"] == "https://example.com")
        #expect(variables.values["MODIFIER_FLAGS"] == String(131_072 + 1_048_576))
        #expect(variables.values["BUNDLE_IDENTIFIER"] == editor.bundleID)
        #expect(variables.values["APP_NAME"] == "Editor")
        #expect(variables.values["BROWSER_TITLE"] == "Page")
        #expect(variables.values["BROWSER_URL"] == "https://example.com/page")
        #expect(variables.values["EXTENSION_IDENTIFIER"] == "com.example.test")
        #expect(variables.values["OPTION_APIKEY"] == "k")
    }

    /// **Done when: exit code 2 opens settings.** The run fails, and says what it wants.
    @Test func needingSettingsFailsAndAsksForThem() async throws {
        let scene = Scene(scripts: FakeScripts(.needsSettings))
        let (report, invocation) = try await scene.run("shellScript: exit 2\nafter: copy-result")
        #expect(report.outcome == .notPerformed)
        #expect(report.stage == .executor)
        #expect(report.attention == .settings)
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(await scene.manager.record(of: invocation)?.outcome == .failed)
    }

    /// ONB-5.
    @Test func automationDenialAsksForThePermission() async throws {
        let scene = Scene(scripts: FakeScripts(.automationDenied, ownership: .delegated))
        let (report, _) = try await scene.run(#"applescript: tell application "Notes" to activate"#)
        #expect(report.outcome == .notPerformed)
        #expect(report.attention == .automationPermission)
    }

    @Test func aScriptThatFailsOrCannotStartFails() async throws {
        for scripts in [FakeScripts(.failed), FakeScripts(starts: false)] {
            let scene = Scene(scripts: scripts)
            let (report, invocation) = try await scene.run("shellScript: exit 1")
            #expect(report.outcome == .notPerformed)
            #expect(report.attention == nil)
            #expect(await scene.manager.record(of: invocation)?.outcome == .failed)
        }
    }

    /// §8.4 AppleScript: placeholders are filled in, escaped for the string they sit in.
    @Test func anAppleScriptHasItsPlaceholdersFilledIn() async throws {
        let scene = Scene(scripts: FakeScripts(.returned(nil), ownership: .delegated))
        _ = try await scene.run(#"applescript: return "{popclip text}""#, value: #"say "hi""#)
        #expect(scene.scripts.calls == [.appleScript(AppleScriptRunRequest(source: .text(#"return "say \"hi\"""#)))])
    }

    /// `appleScriptCall`: a file inside the package, and the handler's parameters looked up.
    @Test func aHandlerCallGetsItsParameters() async throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        try "on go(a, b)\nend go\n".write(to: package.appendingPathComponent("s.applescript"), atomically: true, encoding: .utf8)

        let scene = Scene(scripts: FakeScripts(.returned(nil), ownership: .delegated))
        _ = try await scene.run(
            "applescript: x",
            value: "v",
            options: ["site": "s"],
            directory: package,
            executor: .appleScript(AppleScriptAction(
                source: .file("s.applescript"),
                call: AppleScriptAction.Call(handler: "go", parameters: ["popclip text", "popclip option site"])
            ))
        )
        guard case .appleScript(let job) = scene.scripts.calls.first else {
            Issue.record("Expected an AppleScript, got \(scene.scripts.calls)")
            return
        }
        #expect(job.source == .file(package.appendingPathComponent("s.applescript").resolvingSymlinksInPath().standardizedFileURL))
        #expect(job.handler == "go")
        #expect(job.arguments == ["v", "s"])
    }

    /// A link out of the package is refused where the file is used, not only where it was staged.
    @Test func aScriptFileOutsideItsPackageIsNotRun() async throws {
        let package = try Self.package()
        let outside = try Self.package()
        defer {
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: outside)
        }
        try "return 1".write(to: outside.appendingPathComponent("s.applescript"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("s.applescript"),
            withDestinationURL: outside.appendingPathComponent("s.applescript")
        )
        let scene = Scene(scripts: FakeScripts(.returned(nil), ownership: .delegated))
        let (report, _) = try await scene.run(
            "applescript: x",
            directory: package,
            executor: .appleScript(AppleScriptAction(source: .file("s.applescript")))
        )
        #expect(report.outcome == .notPerformed)
        #expect(scene.scripts.calls.isEmpty)
    }

    @Test func aServiceIsGivenTheText() async throws {
        let scene = Scene(scripts: FakeScripts(.returned(nil), ownership: .delegated))
        let (report, _) = try await scene.run("serviceName: Make Sticky", value: "note this")
        #expect(report.outcome == .done)
        #expect(scene.scripts.calls == [.service(name: "Make Sticky", text: "note this")])
    }

    /// RUN-3c, RUN-3d: the run is attached, so Escape reaches a script that hangs, and whatever it
    /// says afterwards is dropped rather than copied.
    @Test func aHungScriptIsCancelledAndItsLateResultDropped() async throws {
        let gate = Gate()
        let scripts = FakeScripts(.returned("late"), gate: gate, ownership: .delegated)
        let scene = Scene(scripts: scripts)
        let action = try Scene.action("applescript: delay 600\nafter: copy-result")
        let invocation = await scene.begin(action)
        let running = Task {
            await scene.runner.run(ExtensionRunner.Request(
                invocation: invocation,
                action: action,
                approval: .approving(action),
                match: ActionMatching.Match(narrowing: nil, span: nil, value: "x", fullText: "x"),
                context: SelectionContext(
                    app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                    editability: Editability(isEditable: true, source: .settableSelectedText),
                    canCut: true, canCopy: true, canPaste: true
                ),
                target: editor
            ))
        }
        #expect(await eventually { !scripts.calls.isEmpty })
        await scene.manager.cancel(invocation)
        await gate.open()
        let ended = await running.value
        #expect(ended.outcome == .notRunning)
        #expect(scripts.run.timesCancelled == 1)
        #expect(scene.pasteboard.brokerWrites.isEmpty)
    }
}

// MARK: before and after (§8.6)

/// **Done when: each `after` value has a test, including the stale-destination branch of
/// `paste-result`.**
@Suite struct ExtensionRunnerStepTests {
    private static let returning = "shortcutName: Transform\n"

    private func scene(result: String? = "RESULT", _ probe: FakeDestinationProbe = FakeDestinationProbe(matching),
                       frontmost: TargetApp? = editor) -> Scene {
        Scene(probe: probe, frontmost: frontmost, shortcuts: FakeShortcuts(.returned(result)))
    }

    // after: the four edit commands

    @Test func afterCutPostsTheAppsCut() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: cut")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.cutPosts == 1)
    }

    @Test func afterCopyKeepsTheSelection() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: copy", value: "selected")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.currentText == "selected")
    }

    @Test func afterPastePostsTheAppsPaste() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: paste")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.pasteboard.brokerWrites.isEmpty)
    }

    @Test func afterPastePlainHoldsTheClipboardsTextForOnePaste() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: paste-plain")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.writtenTexts.first == held)
        #expect(scene.pasteboard.currentText == held)
    }

    // after: the result

    @Test func copyResultCopiesAndSaysCopied() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: copy-result")
        #expect(report.display == .copied)
        #expect(scene.pasteboard.currentText == "RESULT")
        #expect(scene.pasteboard.pastePosts == 0)
    }

    @Test func pasteResultPastesAndLeavesTheResultOnTheClipboard() async throws {
        let scene = scene()
        let (report, invocation) = try await scene.run(Self.returning + "after: paste-result")
        #expect(report.outcome == .done)
        #expect(report.display == .status)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.writtenTexts.first == "RESULT")
        #expect(scene.pasteboard.currentText == "RESULT")
        #expect(await scene.manager.record(of: invocation)?.mutated == true)
    }

    @Test func pasteResultWithRestorePasteboardPutsTheClipboardBack() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: paste-result\nrestorePasteboard: true")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.pasteboard.currentText == held)
    }

    /// §8.6: "if Paste was unavailable at invocation, copies as in PopClip".
    @Test func pasteResultWithoutPasteCopies() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(Self.returning + "after: paste-result", canPaste: false)
        #expect(report.outcome == .done)
        #expect(report.display == .copied)
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(scene.pasteboard.currentText == "RESULT")
    }

    /// §8.6, RUN-2c: "A stale/unsafe destination follows RUN-2 instead of silently pasting or
    /// copying." The user clicked into another app while the Shortcut ran: nothing is pasted there,
    /// and the clipboard they had is still the clipboard they have.
    @Test func pasteResultIntoAStaleDestinationNeitherPastesNorCopies() async throws {
        let scene = scene(FakeDestinationProbe(DestinationEvidence(isFrontmost: false)), frontmost: terminal)
        let (report, invocation) = try await scene.run(Self.returning + "after: paste-result")
        #expect(report.block?.primary == .notFrontmost)
        #expect(report.stage == .after)
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(scene.pasteboard.currentText == held)
        #expect(await scene.manager.record(of: invocation)?.outcome == .blocked)
        #expect(await scene.manager.record(of: invocation)?.mutated == false)
    }

    @Test func previewResultCopiesAndShowsTheFirst160Characters() async throws {
        let long = String(repeating: "x", count: 400)
        let scene = scene(result: long)
        let (report, _) = try await scene.run(Self.returning + "after: preview-result")
        #expect(scene.pasteboard.currentText == long)
        guard case .result(let shown) = report.display else {
            Issue.record("expected a result display, got \(report.display)")
            return
        }
        #expect(shown.count == ExtensionRunner.previewLimit)
        #expect(shown.hasSuffix("…"))
    }

    @Test func showResultCopiesAndShowsIt() async throws {
        let scene = scene(result: "short")
        let (report, _) = try await scene.run(Self.returning + "after: show-result")
        #expect(report.display == .result("short"))
        #expect(scene.pasteboard.currentText == "short")
    }

    @Test func showStatusIsATickOrAnX() async throws {
        let done = try await scene().run(Self.returning + "after: show-status").0
        #expect(done.outcome == .done)
        #expect(done.display == .status)

        let failing = Scene(shortcuts: FakeShortcuts(.failed))
        let failed = try await failing.run(Self.returning + "after: show-status").0
        #expect(failed.outcome == .notPerformed)
        #expect(failed.display == .status)
    }

    @Test func popclipAppearBringsTheBarBack() async throws {
        let (report, _) = try await scene().run(Self.returning + "after: popclip-appear")
        #expect(report.outcome == .done)
        #expect(report.display == .reappear)
    }

    @Test func copySelectionCopiesTheWholeSelectionNotTheMatch() async throws {
        let scene = scene()
        let (report, _) = try await scene.run(
            Self.returning + "after: copy-selection",
            value: "example.com",
            fullText: "see example.com today"
        )
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.currentText == "see example.com today")
    }

    @Test func anEmptyResultSkipsTheResultStep() async throws {
        for result in [nil, ""] as [String?] {
            let scene = scene(result: result)
            let (report, _) = try await scene.run(Self.returning + "after: paste-result")
            #expect(report.outcome == .done)
            #expect(report.returnedText == false)
            #expect(scene.pasteboard.pastePosts == 0)
            #expect(scene.pasteboard.brokerWrites.isEmpty)
        }
    }

    // before

    @Test func beforeCopyRunsBeforeTheExecutor() async throws {
        let scene = scene()
        let (report, _) = try await scene.run("before: copy\nurl: https://x.test/?q=***", value: "selected")
        #expect(report.outcome == .done)
        #expect(scene.pasteboard.currentText == "selected")
        #expect(scene.opener.requests.count == 1)
    }

    @Test func aBlockedBeforeStopsTheRun() async throws {
        let scene = scene(FakeDestinationProbe(DestinationEvidence(isFrontmost: false)), frontmost: terminal)
        let (report, _) = try await scene.run("before: cut\nurl: https://x.test/?q=***")
        #expect(report.stage == .before)
        #expect(report.block != nil)
        #expect(scene.pasteboard.cutPosts == 0)
        #expect(scene.opener.requests.isEmpty)
    }

    // mayMutate

    @Test func whatMayMutate() throws {
        #expect(try Scene.action("keyCombo: command b").manifest.mayMutateTheDestination)
        #expect(try Scene.action(Self.returning + "after: paste-result").manifest.mayMutateTheDestination)
        #expect(try Scene.action(Self.returning + "after: preview-result").manifest.mayMutateTheDestination)
        #expect(try Scene.action("before: paste-plain\nurl: https://x.test/***").manifest.mayMutateTheDestination)
        #expect(try Scene.action("url: https://x.test/***").manifest.mayMutateTheDestination == false)
        #expect(try Scene.action(Self.returning + "after: copy-result").manifest.mayMutateTheDestination == false)
        #expect(try Scene.action(Self.returning + "after: show-result").manifest.mayMutateTheDestination == false)
    }
}
