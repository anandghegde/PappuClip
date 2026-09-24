import Foundation
import PappuAnalysis
import PappuApp
import PappuAX
import PappuCore
@testable import PappuExtensions
import PappuRuntime
import PappuSelection
import PappuSurfaces
import PappuTestSupport
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.example.Editor")
private typealias Node = FakeAXWorld.Node

// MARK: The scene
//
// Assembled the way the app assembles it: the real manifests off disk, the real gate, the real context
// probe, the real resolver, the real `InvocationManager` and the real `ClipboardBroker`. The fakes are
// the Accessibility tree, the pasteboard, `NSWorkspace` and the two clocks — the four things a test
// machine does not have.

private func editItem(_ character: String, enabled: Bool) -> Node {
    Node(role: "AXMenuItem", enabled: enabled, cmdChar: character, cmdModifiers: EditMenuProbe.commandAlone)
}

private func menuBar(cut: Bool, copy: Bool, paste: Bool) -> Node {
    Node(role: "AXMenuBar", children: [
        Node(role: "AXMenuBarItem", children: [Node(role: "AXMenu", children: [
            editItem("x", enabled: cut),
            editItem("c", enabled: copy),
            editItem("v", enabled: paste),
        ])]),
    ])
}

/// The five built-ins as they ship, found by walking up from this file. There is no app bundle yet.
private func builtinCatalog() throws -> ActionCatalog {
    var candidate = URL(filePath: #filePath).standardizedFileURL
    while candidate.path != "/" {
        candidate = candidate.deletingLastPathComponent()
        let resources = candidate.appending(path: "Resources/" + BuiltinExtensions.directoryName)
        if FileManager.default.fileExists(atPath: resources.path) {
            return ActionCatalog(entries: try BuiltinExtensions.entries(from: resources))
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

/// Everything one bridge is built from, kept together so a test can reach the edges it wants to watch.
private struct Scene {
    let bridge: SelectionBridge
    let bar: RecordingBar
    let pasteboard: ScriptedPasteboard
    let manager: InvocationManager
    let opener: RecordingURLOpener
    let sleeper: InstantSleep
    let keys: CountingKeyPresses
    let attention: RecordingAttention
    let installer: RecordingInstaller

    static func make(
        rules: PrivacyRules = PrivacyRules(),
        editable: Bool = false,
        clipboardHasText: Bool = false,
        clipboard: String? = "the user's own clipboard",
        shortcuts: AnsweringShortcuts = AnsweringShortcuts(),
        scripts: AnsweringScripts = AnsweringScripts(),
        approvals: @escaping ActionResolver.Approvals = ExecutionApproval.bundled,
        runtimeOptions: @escaping @Sendable (CatalogAction) -> [String: String] = { _ in [:] },
        installs: Bool = true,
        catalog: ActionCatalog
    ) async throws -> Scene {
        let focused = Node(role: editable ? "AXTextArea" : "AXStaticText")
        if editable { focused.allowWriting(.selectedText) }
        let world = FakeAXWorld()
        world.setApplication(
            Node(role: "AXApplication", menuBar: menuBar(cut: editable, copy: true, paste: editable)),
            in: target.pid
        )
        world.setFocused(focused, in: target.pid)

        let pasteboard = ScriptedPasteboard(text: clipboard)
        let clock = ManualTimeSource()
        let policies = DetectionPolicyStore(
            DetectionPolicies(default: DetectionPolicy(
                strategies: [.ax],
                autoAppear: true,
                autoSyntheticCopy: true,
                hotkeySyntheticCopy: true,
                quiescence: true
            )),
            ceilings: .none
        )
        let destination = AbsentDestination()
        let gate = PrivacyGate(rules)
        let manager = InvocationManager(
            verifier: DestinationVerifier(
                gate: gate,
                probe: destination,
                policies: policies,
                epochs: pasteboard,
                frontmost: { target },
                secureInputIsActive: { false },
                timing: .initial,
                now: clock.reader
            ),
            probe: destination,
            epochs: pasteboard,
            timing: .initial,
            sleeper: InstantSleep(),
            now: clock.reader
        )
        let broker = ClipboardBroker(
            pasteboard: pasteboard,
            input: pasteboard,
            copy: pasteboard,
            pasting: pasteboard,
            scheduling: pasteboard,
            timing: .initial
        )
        let opener = RecordingURLOpener()
        let sleeper = InstantSleep()
        let keys = CountingKeyPresses()
        let editor = SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager)
        let mutator = TextMutator(clipboard: broker, manager: manager)
        let bar = await RecordingBar()
        let bridge = SelectionBridge(
            catalog: { catalog },
            gate: gate,
            probe: await ContextProbe(world: world, names: FakeAppNames([target.pid: "Editor"])),
            analyzer: ContentAnalyzer(files: ScriptedFileProbe()),
            manager: manager,
            runner: BuiltinRunner(
                manager: manager,
                editor: editor,
                mutator: mutator,
                clipboard: broker,
                urls: opener
            ),
            extensions: ExtensionRunner(
                manager: manager,
                editor: editor,
                mutator: mutator,
                presser: KeyPresser(poster: keys, manager: manager, sleep: sleeper),
                clipboard: broker,
                urls: opener,
                shortcuts: shortcuts,
                shell: scripts,
                appleScripts: scripts,
                services: scripts
            ),
            conditions: { BuiltinConditions(clipboardHasText: clipboardHasText) },
            secureInput: { .clear },
            resolver: ActionResolver(approvals: approvals),
            runtimeOptions: runtimeOptions,
            locale: { Locale(identifier: "en_US") },
            sleeper: sleeper,
            timing: BridgeTiming(confirmation: .milliseconds(700))
        )
        let attention = await RecordingAttention(bar: bar)
        await bridge.attach(bar)
        await bridge.attach(attention: attention)
        let installer = await RecordingInstaller(bar: bar)
        if installs { await bridge.attach(installer: installer) }
        return Scene(
            bridge: bridge,
            bar: bar,
            pasteboard: pasteboard,
            manager: manager,
            opener: opener,
            sleeper: sleeper,
            keys: keys,
            attention: attention,
            installer: installer
        )
    }
}

private func presentation(
    attempt: UInt64 = 1,
    text: String? = "some words",
    route: ActivationRoute = .automatic
) -> AttemptPresentation {
    AttemptPresentation(
        attempt: AttemptID(rawValue: attempt),
        route: route,
        target: target,
        verdict: text == nil ? .caret : .selection,
        text: text,
        range: AXTextRange(location: 10, length: 10),
        strategy: .ax
    )
}

/// **FLT-1 and BAR-6 from the app's side: what the bar holds for a real selection in a real app.**
///
/// `ActionResolverTests` covers the resolve over facts. This covers the stage the bridge owns: the gate,
/// the probe, the analysis and the remembering, run in the order one appearance runs them.
@Suite struct SelectionBridgeContentTests {
    static let catalog = try! builtinCatalog()

    private func names(_ content: BarContent) -> [String] {
        content.items.map(\.name)
    }

    /// A web page: text, nothing editable, nothing on the clipboard worth pasting.
    @Test func aReadOnlySelectionOffersCopyAndSearchAndNothingElse() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation())
        #expect(names(content) == ["Copy", "Search"])
    }

    /// FLT-6: Cut and Paste arrive with the app's own answer about whether they can work.
    @Test func anEditableFieldWithAFullClipboardOffersAllFour() async throws {
        let scene = try await Scene.make(editable: true, clipboardHasText: true, catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation())
        #expect(Set(names(content)) == ["Cut", "Copy", "Paste", "Search"])
    }

    /// PRD §7.4: Paste is shown only when there is something to paste, and the answer is read per
    /// attempt rather than once (ACT-10).
    @Test func anEmptyClipboardTakesPasteAwayFromAnEditableField() async throws {
        let scene = try await Scene.make(editable: true, clipboardHasText: false, catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation())
        #expect(!names(content).contains("Paste"))
    }

    /// ACT-3's caret bar: a long press in a field with nothing selected. Paste is the one built-in that
    /// can be offered there, and it reaches the bar through the same resolve as everything else.
    @Test func aCaretInAFieldOffersPasteAlone() async throws {
        let scene = try await Scene.make(editable: true, clipboardHasText: true, catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation(text: nil))
        #expect(names(content) == ["Paste"])
    }

    /// The other half of it, and the reason the caret is not answered by a shortcut inside the bridge:
    /// what a caret bar holds is whatever the resolve says it holds, which on an empty clipboard is
    /// nothing at all.
    @Test func aCaretWithNothingToPasteHasNoBar() async throws {
        let scene = try await Scene.make(editable: true, clipboardHasText: false, catalog: Self.catalog)
        #expect(await scene.bridge.content(for: presentation(text: nil)).isEmpty)
    }

    /// A verdict that shows no bar is answered without a probe, whatever came back with it.
    @Test func aVerdictThatShowsNoBarIsNotResolvedAtAll() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        var unreadable = presentation()
        unreadable.verdict = .unreadable
        #expect(await scene.bridge.content(for: unreadable).isEmpty)
    }

    /// ACT-17a. The gate is asked again here because the context probe is a second read, and this is
    /// what a refusal looks like from the bar's side: no items, which `BarController` turns into no bar.
    @Test func aHardBlockedAppGetsNoBarEvenAfterTheSelectionWasRead() async throws {
        let scene = try await Scene.make(
            rules: PrivacyRules(hardBlockedApps: [target.bundleID!]),
            catalog: Self.catalog
        )
        #expect(await scene.bridge.content(for: presentation()).isEmpty)
    }

    /// ACT-18, through the same second evaluation: a pause that began while the selection was being read
    /// takes the bar away before it appears.
    @Test func aPauseThatBeganSinceTheReadGetsNoBar() async throws {
        let scene = try await Scene.make(rules: PrivacyRules(pause: .untilResumed), catalog: Self.catalog)
        #expect(await scene.bridge.content(for: presentation()).isEmpty)
    }

    /// The locale is the bridge's to apply, once, so that a test asserts the same words on every
    /// machine (BAR-6).
    @Test func theButtonsAreNamedInTheLocaleTheBridgeWasGiven() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation())
        #expect(content.items.allSatisfy { !$0.name.isEmpty })
        #expect(content.items.first?.id == BarItemID("app.pappuclip.builtin.copy#copy"))
    }
}

/// **RUN-1 and BAR-12a from the app's side: what a press turns into.**
@Suite struct SelectionBridgeInvocationTests {
    static let catalog = try! builtinCatalog()

    private func copyClick() -> BarClick {
        BarClick(item: BarItemID("app.pappuclip.builtin.copy#copy"))
    }

    /// The whole path, once: content, press, run, report, dismiss.
    @Test func copyingLeavesTheSelectionOnTheClipboardAndSaysSo() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation())
        await scene.bridge.invoke(copyClick(), for: presentation())

        #expect(scene.pasteboard.currentText == "some words")
        #expect(await scene.bar.states == [.copied])
        #expect(await scene.bar.dismissals == [.actionRun])
    }

    /// BAR-12a: the confirmation is on screen for a moment before the bar goes. A dismissal in the same
    /// turn as the report would report it to nobody.
    @Test func theConfirmationIsHeldBeforeTheBarGoes() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation())
        await scene.bridge.invoke(copyClick(), for: presentation())
        #expect(scene.sleeper.durations == [.milliseconds(700)])
    }

    /// The invocation is begun with what the bar was built from, not with what is selected now (RUN-1b).
    @Test func theRunIsRecordedAgainstItsAttemptAndItsAction() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation())
        await scene.bridge.invoke(copyClick(), for: presentation())

        let record = try #require(await scene.manager.lastRecord)
        #expect(record.attempt == AttemptID(rawValue: 1))
        #expect(record.action == "app.pappuclip.builtin.copy#copy")
        #expect(record.characters == "some words".count)
        #expect(record.outcome == .completed)
        // RUN-2a: Copy sends nothing into the other process, so it holds no key tap and asks for no
        // permit (`BuiltinRunner`'s "Why Copy is not a ⌘C").
        #expect(!record.mayMutate)
    }

    /// ACT-16a: there is one bar at a time, and a click carrying an older attempt is a click on a bar
    /// that is already gone.
    @Test func aClickFromARetiredAttemptRunsNothing() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation(attempt: 1))
        await scene.bridge.invoke(copyClick(), for: presentation(attempt: 2))

        #expect(await scene.manager.lastRecord == nil)
        #expect(await scene.bar.states == [.failed])
        #expect(scene.pasteboard.currentText == "the user's own clipboard")
    }

    /// A button that is not in the resolution — a bar built for another selection, a manifest disabled
    /// between the appearance and the press.
    @Test func aClickOnSomethingThatWasNotOfferedRunsNothing() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation())
        await scene.bridge.invoke(BarClick(item: BarItemID("app.pappuclip.builtin.paste#paste")), for: presentation())

        #expect(await scene.manager.lastRecord == nil)
        #expect(await scene.bar.states == [.failed])
    }

    /// PRD §7.4: ⌥ on Open Link copies the addresses as a list rather than opening them. The modifiers
    /// travel with the click, because by the time the action runs the user has let go (BAR-11).
    @Test func theModifiersHeldAtTheClickReachTheBuiltin() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        let link = presentation(text: "https://example.com")
        let content = await scene.bridge.content(for: link)
        try #require(content.items.contains { $0.id == BarItemID("app.pappuclip.builtin.open-link#open-link") })

        await scene.bridge.invoke(
            BarClick(item: BarItemID("app.pappuclip.builtin.open-link#open-link"), modifiers: [.option]),
            for: link
        )
        #expect(scene.opener.urls.isEmpty)
        #expect(scene.pasteboard.currentText == "https://example.com")
    }

    /// RUN-3: a press while something is running is "stop", and the bar has already gone back to idle by
    /// the time this is called, so there is nothing further to report.
    @Test func cancellingEndsWhateverTheBarStarted() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation())
        await scene.bridge.cancelRunningAction()
        #expect(await scene.manager.runningInvocations.isEmpty)
    }
}

/// **§8.6 and BAR-12b from the app's side: an extension's action, pressed on a real bar.**
///
/// `ExtensionRunnerTests` covers every `after` value against the runner. This covers what the bridge
/// adds: that a non-built-in reaches that runner at all, and what the bar is told when it ends.
@Suite struct SelectionBridgeExtensionTests {
    /// One extension per snippet, each with the one action a test presses.
    private func catalog(_ bodies: [String: String]) throws -> ActionCatalog {
        ActionCatalog(entries: try bodies.sorted { $0.key < $1.key }.map { name, body in
            let snippet = "#popclip\nname: \(name)\nidentifier: com.example.\(name.lowercased())\n\(body)"
            return .init(manifest: try ExtensionLoader.loadSnippet(snippet).manifest, origin: .installed)
        })
    }

    /// What the store would mint for an extension approved with every gate it asks for. These tests are
    /// about running; `ExecutionApprovalTests` and `ExtensionHostTests` are about approving.
    private static let approveAll: ActionResolver.Approvals = { action in
        ExecutionApproval.bundled(action)
            ?? ExecutionApproval(identity: action.owner.flatMap(LocalIdentity.init), digest: nil, gates: action.gates)
    }

    private func approvedScene(
        shortcuts: AnsweringShortcuts = AnsweringShortcuts(),
        scripts: AnsweringScripts = AnsweringScripts(),
        runtimeOptions: @escaping @Sendable (CatalogAction) -> [String: String] = { _ in [:] },
        _ bodies: [String: String]
    ) async throws -> Scene {
        try await Scene.make(
            shortcuts: shortcuts,
            scripts: scripts,
            approvals: Self.approveAll,
            runtimeOptions: runtimeOptions,
            catalog: catalog(bodies)
        )
    }

    /// EXM-5: with no approval, an installed extension's action is not on the bar at all.
    @Test func anUnapprovedExtensionIsNotOnTheBar() async throws {
        let scene = try await Scene.make(catalog: catalog(["Look": "url: https://x.test/?q=***"]))
        let content = await scene.bridge.content(for: presentation())
        #expect(!content.items.contains { $0.name == "Look" })
    }

    /// §8.9: the run is handed the extension's option values, which the bridge asks for at the click.
    @Test func theRunIsHandedTheOptions() async throws {
        let scene = try await approvedScene(runtimeOptions: { _ in ["lang": "fr"] }, [
            "Look": "options:\n  - identifier: lang\n    type: string\n    label: Language\nurl: https://x.test/?q=***&l={popclip option lang}",
        ])
        try await press("Look", in: scene)
        #expect(scene.opener.urls == [URL(string: "https://x.test/?q=some%20words&l=fr")])
    }

    /// Shows the bar, then presses the button with that name.
    private func press(_ name: String, in scene: Scene) async throws {
        let content = await scene.bridge.content(for: presentation())
        let item = try #require(content.items.first { $0.name == name })
        await scene.bridge.invoke(BarClick(item: item.id), for: presentation())
    }

    @Test func aURLActionOpensItsAddressAndSaysDone() async throws {
        let scene = try await approvedScene(["Look": "url: https://x.test/?q=***"])
        try await press("Look", in: scene)

        #expect(scene.opener.urls == [URL(string: "https://x.test/?q=some%20words")])
        #expect(await scene.bar.states == [.succeeded])
        #expect(await scene.bar.dismissals == [.actionRun])
    }

    /// BAR-12b, BAR-10: a result stays until the user dismisses it the way any bar is dismissed. A
    /// clock under something being read is a clock the reader loses to.
    @Test func aResultReplacesTheButtonsAndStays() async throws {
        let scene = try await approvedScene(["Ask": "shortcutName: Ask\nafter: show-result"])
        try await press("Ask", in: scene)

        #expect(await scene.bar.states == [.result("the answer")])
        #expect(await scene.bar.dismissals.isEmpty)
        #expect(scene.sleeper.durations.isEmpty)
    }

    /// §8.6 `popclip-appear`: the buttons come back rather than the bar going away.
    @Test func popclipAppearPutsTheButtonsBack() async throws {
        let scene = try await approvedScene(["Look": "url: https://x.test/?q=***\nafter: popclip-appear"])
        try await press("Look", in: scene)

        #expect(await scene.bar.states == [.idle])
        #expect(await scene.bar.dismissals.isEmpty)
    }

    /// `stay visible`: the tick for its moment, then the buttons again.
    @Test func stayVisibleReturnsToTheButtonsAfterTheConfirmation() async throws {
        let scene = try await approvedScene(["Look": "url: https://x.test/?q=***\nstay visible: true"])
        try await press("Look", in: scene)

        #expect(await scene.bar.states == [.succeeded, .idle])
        #expect(await scene.bar.dismissals.isEmpty)
        #expect(scene.sleeper.durations == [.milliseconds(700)])
    }

    @Test func copyResultSaysCopied() async throws {
        let scene = try await approvedScene(["Ask": "shortcutName: Ask\nafter: copy-result"])
        try await press("Ask", in: scene)

        #expect(scene.pasteboard.currentText == "the answer")
        #expect(await scene.bar.states == [.copied])
    }

    @Test func aShortcutThatFailsShowsTheFailure() async throws {
        let scene = try await approvedScene(
            shortcuts: AnsweringShortcuts(answer: .failed),
            ["Ask": "shortcutName: Ask\nafter: show-result"]
        )
        try await press("Ask", in: scene)

        #expect(await scene.bar.states == [.failed])
        #expect(await scene.bar.dismissals == [.actionRun])
    }

    /// **Done when: exit code 2 opens settings.** The X first, then the settings, named for the action.
    @Test func aScriptThatNeedsSettingsFailsAndAsksForThem() async throws {
        let scene = try await approvedScene(
            scripts: AnsweringScripts(answer: .needsSettings),
            ["Translate": "shellScript: exit 2\nafter: copy-result"]
        )
        try await press("Translate", in: scene)

        #expect(await scene.bar.states == [.failed])
        #expect(await scene.attention.presented.map(\.attention) == [.settings])
        #expect(await scene.attention.presented.map(\.action) == ["Translate"])
        #expect(await scene.attention.barStatesBefore == [[.failed]])
    }

    /// ONB-5.
    @Test func anAppleScriptRefusedAutomationAsksForThePermission() async throws {
        let scene = try await approvedScene(
            scripts: AnsweringScripts(answer: .automationDenied),
            ["Note": #"applescript: tell application "Notes" to activate"#]
        )
        try await press("Note", in: scene)

        #expect(await scene.bar.states == [.failed])
        #expect(await scene.attention.presented.map(\.attention) == [.automationPermission])
    }

    @Test func aScriptThatSucceedsAsksNothing() async throws {
        let scene = try await approvedScene(["Shout": "shellScript: tr a-z A-Z\nafter: copy-result"])
        try await press("Shout", in: scene)

        #expect(scene.pasteboard.currentText == "the answer")
        #expect(await scene.attention.presented.isEmpty)
    }

    /// RUN-2a: a Key Press is synthetic input, so the invocation is begun as one that may mutate — which
    /// is what holds the key tap and asks for a permit. Here the destination cannot be verified, so
    /// nothing is pressed.
    @Test func aKeyPressIsBegunAsAMutationAndRefusedWithoutADestination() async throws {
        let scene = try await approvedScene(["Bold": "keyCombo: command b"])
        try await press("Bold", in: scene)

        let record = try #require(await scene.manager.lastRecord)
        #expect(record.mayMutate)
        #expect(scene.keys.count == 0)
        #expect(await scene.bar.states == [.failed])
    }
}

/// EXM-2 from the bar's side: a selection that is an extension offers to install itself, and pressing
/// the offer hands the text to the one review every install route goes through.
@Suite struct SelectionBridgeInstallOfferTests {
    static let catalog = try! builtinCatalog()
    static let snippet = "#popclip\nname: Shout\nkeyCombo: command b"

    @Test func aSnippetIsOfferedFirstByItsName() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation(text: Self.snippet))
        let offer = try #require(content.items.first)
        #expect(offer.id == .installExtension)
        #expect(offer.name == "Install Extension \u{201C}Shout\u{201D}")
        #expect(offer.isEnabled)
        #expect(content.items.dropFirst().map(\.name) == ["Copy", "Search"])
    }

    @Test func ordinaryTextIsNotOffered() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation())
        #expect(!content.items.contains { $0.id == .installExtension })
    }

    /// PRD EXM-2: "over the limit the bar says so" — dimmed, with the reason in the tooltip.
    @Test func overTheLimitTheOfferIsDimmedAndSaysWhy() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        let long = Self.snippet + "\n# " + String(repeating: "x", count: SnippetDetector.maximumSelectionLength)
        let content = await scene.bridge.content(for: presentation(text: long))
        let offer = try #require(content.items.first)
        #expect(offer.id == .installExtension && !offer.isEnabled)
        #expect(offer.tooltip.contains("5,000"))
    }

    /// An app with no library to install into draws no button that could not work.
    @Test func withNowhereToInstallNothingIsOffered() async throws {
        let scene = try await Scene.make(installs: false, catalog: Self.catalog)
        let content = await scene.bridge.content(for: presentation(text: Self.snippet))
        #expect(!content.items.contains { $0.id == .installExtension })
    }

    @Test func pressingTheOfferPutsTheBarAwayAndHandsOnTheText() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation(text: Self.snippet))
        await scene.bridge.invoke(BarClick(item: .installExtension), for: presentation(text: Self.snippet))
        #expect(await scene.installer.installed == [Self.snippet])
        #expect(await scene.installer.barEventsBefore == [[.dismissed(.actionRun)]])
        // Not an invocation: nothing began that the manager would have to hold.
        #expect(await scene.manager.runningInvocations.isEmpty)
    }

    /// A press on the offer of a bar whose attempt has been retired installs nothing.
    @Test func anOfferFromAnOlderAttemptInstallsNothing() async throws {
        let scene = try await Scene.make(catalog: Self.catalog)
        _ = await scene.bridge.content(for: presentation(attempt: 1, text: Self.snippet))
        await scene.bridge.invoke(BarClick(item: .installExtension), for: presentation(attempt: 2, text: Self.snippet))
        #expect(await scene.installer.installed.isEmpty)
        #expect(await scene.bar.states == [.failed])
    }
}
