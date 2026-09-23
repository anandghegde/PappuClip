import Foundation
import PappuAnalysis
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Testing

private let selectedRange = AXTextRange(location: 10, length: 5)
private let held = "the user's own clipboard"
private let matching = settled(range: selectedRange, text: "selected")

// MARK: The scene
//
// The built-ins are run the way the app will run them: the real manifests off disk, through the real
// `ActionResolver`, into the real `InvocationManager` and the real `ClipboardBroker`. Only the four
// edges of the process are fakes — the Accessibility look, the pasteboard, the keystrokes and
// `NSWorkspace` — because those are the four things a test machine does not have.

private func manager(
    _ probe: FakeDestinationProbe,
    frontmost: TargetApp? = editor,
    clock: ManualTimeSource = ManualTimeSource()
) -> InvocationManager {
    InvocationManager(
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
}

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

private func runner(
    _ manager: InvocationManager,
    pasteboard: ScriptedPasteboard,
    opener: FakeURLOpener = FakeURLOpener(),
    engines: SearchEngines = .fallback,
    search: SearchPreference = SearchPreference()
) -> BuiltinRunner {
    let clipboard = broker(pasteboard)
    return BuiltinRunner(
        manager: manager,
        editor: SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager),
        mutator: TextMutator(clipboard: clipboard, manager: manager),
        clipboard: clipboard,
        urls: opener,
        engines: engines,
        search: search
    )
}

private func app(_ bundleID: String? = editor.bundleID) -> AppIdentity {
    AppIdentity(pid: editor.pid, bundleID: bundleID, name: "Editor")
}

private func context(
    canCut: Bool = false,
    canPaste: Bool = false,
    browser: BrowserPage? = nil,
    bundleID: String? = editor.bundleID
) -> SelectionContext {
    SelectionContext(
        app: app(bundleID),
        editability: Editability(isEditable: canCut || canPaste, source: .settableSelectedText),
        canCut: canCut,
        canCopy: true,
        canPaste: canPaste,
        browser: browser
    )
}

private func url(_ value: String, at location: Int = 0) -> Detection {
    Detection(kind: .url, span: TextSpan(location: location, length: value.utf16.count), value: value)
}

/// What the bar would hand the runner: the real manifest's match for this selection, or nothing when
/// the action would not have been on the bar at all.
private func match(
    _ builtin: BuiltinAction,
    _ selection: AnalyzedSelection,
    _ selectionContext: SelectionContext,
    clipboardHasText: Bool = true
) throws -> ActionMatching.Match {
    let catalog = ActionCatalog(entries: try BuiltinExtensions.entries(from: ActionResolverTests.builtinsDirectory()))
    let resolution = ActionResolver().resolve(
        catalog,
        selection: selection,
        context: selectionContext,
        conditions: BuiltinConditions(clipboardHasText: clipboardHasText)
    )
    let resolved = try #require(
        resolution.actions.first { $0.action.builtin == builtin },
        "\(builtin.rawValue) was not offered for this selection"
    )
    return resolved.match
}

private func begin(
    _ manager: InvocationManager,
    _ builtin: BuiltinAction,
    text: String,
    mayMutate: Bool
) async -> InvocationID {
    await manager.begin(
        InvocationRequest(
            attempt: AttemptID(rawValue: 1),
            route: .automatic,
            target: editor,
            action: "app.pappuclip.builtin.\(builtin.rawValue)#\(builtin.rawValue)",
            mayMutate: mayMutate,
            text: text,
            range: selectedRange,
            strategy: .ax
        )
    )
}

/// **PRD §7.4: the five built-ins — Cut, Copy, Paste, Search and Open Link.**
///
/// The `builtin` executor is the only one M1 has, and these are what stands behind it. Every test here
/// goes through the real manifest and the real resolver, so a built-in that stopped matching its own
/// file fails here before it fails in the bar.
@Suite struct BuiltinRunnerTests {
    // MARK: Cut — the app's own ⌘X (RUN-2a, RUN-4)

    @Test func cutPostsTheAppsOwnKeystrokeAndNothingElse() async throws {
        let selection = AnalyzedSelection(text: "selected")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .cut, text: selection.text, mayMutate: true)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .cut,
                match: try match(.cut, selection, context(canCut: true)),
                selection: selection,
                context: context(canCut: true),
                target: editor
            )
        )

        #expect(report.outcome == .done)
        #expect(report.edit?.command == .cut)
        #expect(report.edit?.tier == .accessibility)
        #expect(pasteboard.cutPosts == 1)
        // The app puts its own flavours on the clipboard in response to ⌘X. PappuClip writes nothing,
        // clears nothing and restores nothing — which is the whole reason Cut is a keystroke.
        #expect(pasteboard.brokerWrites.isEmpty)
        #expect(pasteboard.clears == 0)
        #expect(pasteboard.currentText == held)
        #expect(await runtime.record(of: invocation)?.mutated == true)
        #expect(await runtime.record(of: invocation)?.outcome == .completed)
    }

    /// RUN-2a in the form the user meets it: they clicked Cut, then clicked into another app. No
    /// keystroke goes anywhere, because a ⌘X delivered to the wrong window deletes the wrong text.
    @Test func cutIntoAnUnverifiableDestinationPostsNothing() async throws {
        let selection = AnalyzedSelection(text: "selected")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(
            FakeDestinationProbe(DestinationEvidence(isFrontmost: false)),
            frontmost: terminal
        )
        let invocation = await begin(runtime, .cut, text: selection.text, mayMutate: true)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .cut,
                match: try match(.cut, selection, context(canCut: true)),
                selection: selection,
                context: context(canCut: true),
                target: editor
            )
        )

        #expect(report.block?.primary == .notFrontmost)
        #expect(report.edit == nil)
        #expect(pasteboard.cutPosts == 0)
        #expect(await runtime.record(of: invocation)?.outcome == .blocked)
    }

    // MARK: Copy — a kept write, and no permit at all

    /// The case that decided Copy's shape: read-only prose in a web page. Nothing there is editable, so
    /// RUN-2 grants no permit and never will — and Copy still has to work, because that is where people
    /// copy from. It works by writing the text PappuClip already read.
    @Test func copyWritesTheSelectionWhereNoPermitCouldEverBeMinted() async throws {
        let selection = AnalyzedSelection(text: "some prose")
        let page = BrowserPage(url: URL(string: "https://example.com/article"), title: "Article", source: .accessibility)
        let pasteboard = ScriptedPasteboard(text: held)
        // Read-only web content: the verifier would answer `.notEditable` at both tiers.
        let runtime = manager(FakeDestinationProbe(DestinationEvidence(
            isFrontmost: true,
            sameWindow: true,
            sameElement: true,
            isEditable: false
        )))
        let invocation = await begin(runtime, .copy, text: selection.text, mayMutate: false)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .copy,
                match: try match(.copy, selection, context(browser: page)),
                selection: selection,
                context: context(browser: page),
                target: editor
            )
        )

        #expect(report.outcome == .done)
        #expect(pasteboard.currentText == "some prose")
        #expect(pasteboard.copyPosts == 0, "Copy sends no synthetic keystroke into the other process")
        #expect(pasteboard.clears == 1)
        #expect(pasteboard.brokerWrites.count == 1, "one write, and no restore: the user asked for it")
        #expect(await runtime.record(of: invocation)?.outcome == .completed)
    }

    /// ACT-10h is inverted here on purpose: the paste path hides its text from clipboard managers
    /// because the user never asked for it. Copy is the user asking for it.
    @Test func copyIsNotHiddenFromClipboardManagers() async throws {
        let selection = AnalyzedSelection(text: "keep me")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .copy, text: selection.text, mayMutate: false)

        _ = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .copy,
                match: try match(.copy, selection, context()),
                selection: selection,
                context: context(),
                target: editor
            )
        )

        #expect(pasteboard.lastWriteWasMarked == false)
    }

    // MARK: Paste — the app's own ⌘V, and the clipboard left alone

    /// PRD §7.4: "Pasted text stays on the clipboard by default." So there is no transaction here at
    /// all — no snapshot, no hold, no restore, nothing to lose.
    @Test func pastePostsTheKeystrokeAndLeavesTheClipboardWhereItWas() async throws {
        let selection = AnalyzedSelection(text: "selected")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .paste, text: selection.text, mayMutate: true)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .paste,
                match: try match(.paste, selection, context(canPaste: true)),
                selection: selection,
                context: context(canPaste: true),
                target: editor
            )
        )

        #expect(report.outcome == .done)
        #expect(report.edit?.command == .paste)
        #expect(pasteboard.pastePosts == 1)
        #expect(pasteboard.brokerWrites.isEmpty)
        #expect(pasteboard.currentText == held)
    }

    /// ⇧ Paste is the one built-in that writes text rather than asking the app to, because pasting
    /// *as plain* means leaving the clipboard's other flavours behind. It borrows the clipboard through
    /// the broker and gives it back.
    @Test func shiftPasteHoldsThePlainTextAndGivesTheClipboardBack() async throws {
        let selection = AnalyzedSelection(text: "selected")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .paste, text: selection.text, mayMutate: true)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .paste,
                match: try match(.paste, selection, context(canPaste: true)),
                selection: selection,
                context: context(canPaste: true),
                target: editor,
                modifiers: [.shift]
            )
        )

        #expect(report.outcome == .done)
        #expect(report.mutation?.outcome == .mutated)
        #expect(report.mutation?.characters == held.count)
        #expect(pasteboard.pastePosts == 1)
        // Our plain text up, the user's clipboard back down.
        #expect(pasteboard.brokerWrites.count == 2)
        #expect(pasteboard.currentText == held)
    }

    /// The clipboard emptied between the bar appearing and the click. `BuiltinConditions` is what
    /// normally keeps Paste off the bar; this is the same answer one moment later, and it is not a
    /// failure of anything.
    @Test func shiftPasteWithAnEmptyClipboardDoesNothing() async throws {
        let selection = AnalyzedSelection(text: "selected")
        let pasteboard = ScriptedPasteboard(text: nil)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .paste, text: selection.text, mayMutate: true)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .paste,
                match: try match(.paste, selection, context(canPaste: true)),
                selection: selection,
                context: context(canPaste: true),
                target: editor,
                modifiers: [.shift]
            )
        )

        #expect(report.outcome == .nothingToDo)
        #expect(pasteboard.pastePosts == 0)
        #expect(pasteboard.brokerWrites.isEmpty)
    }

    // MARK: Search — the engine, the modifiers and the browser rule

    @Test func searchOpensThePreferredEngineWithTheTermEncoded() async throws {
        let selection = AnalyzedSelection(text: "swift & concurrency")
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .search, text: selection.text, mayMutate: false)

        let report = await runner(runtime, pasteboard: pasteboard, opener: opener).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .search,
                match: try match(.search, selection, context()),
                selection: selection,
                context: context(),
                target: editor
            )
        )

        #expect(report.outcome == .done)
        #expect(report.opened == 1)
        // The `&` is data inside the query, not another parameter.
        #expect(opener.urls.map(\.absoluteString) == ["https://www.google.com/search?q=swift%20%26%20concurrency"])
        #expect(opener.requests.first?.activates == true)
        #expect(opener.requests.first?.browserBundleID == nil)
    }

    /// PRD §7.4: ⇧ opens a background tab, ⌥ wraps the term in double quotes. Together they are one
    /// quoted search that does not steal the front.
    @Test func searchModifiersQuoteTheTermAndKeepTheBrowserBehind() async throws {
        let selection = AnalyzedSelection(text: "exact phrase")
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .search, text: selection.text, mayMutate: false)

        _ = await runner(runtime, pasteboard: pasteboard, opener: opener).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .search,
                match: try match(.search, selection, context()),
                selection: selection,
                context: context(),
                target: editor,
                modifiers: [.shift, .option]
            )
        )

        #expect(opener.urls.first?.absoluteString.contains("%22exact%20phrase%22") == true)
        #expect(opener.requests.first?.activates == false)
    }

    /// "Searches and links open in the current app if it is a known browser, otherwise in the default
    /// browser." A page is what a browser has, and nothing else does.
    @Test func searchFromABrowserOpensInThatBrowser() async throws {
        let selection = AnalyzedSelection(text: "a term")
        let page = BrowserPage(url: URL(string: "https://example.com"), title: "Example", source: .accessibility)
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .search, text: selection.text, mayMutate: false)

        _ = await runner(runtime, pasteboard: pasteboard, opener: opener).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .search,
                match: try match(.search, selection, context(browser: page)),
                selection: selection,
                context: context(browser: page),
                target: editor,
                modifiers: []
            )
        )

        #expect(opener.requests.first?.browserBundleID == editor.bundleID)
    }

    /// A custom URL the user typed wins over the preset they may never have changed.
    @Test func searchUsesTheUsersOwnTemplateWhenItHasThePlaceholder() async throws {
        let selection = AnalyzedSelection(text: "dune")
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .search, text: selection.text, mayMutate: false)

        _ = await runner(
            runtime,
            pasteboard: pasteboard,
            opener: opener,
            search: SearchPreference(engineID: "google", customTemplate: "https://example.org/find?q=***")
        ).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .search,
                match: try match(.search, selection, context()),
                selection: selection,
                context: context(),
                target: editor
            )
        )

        #expect(opener.urls.map(\.absoluteString) == ["https://example.org/find?q=dune"])
    }

    /// The browser refused the address. Nothing was pressed, nothing was written, and the run says so
    /// rather than reporting a tab nobody got.
    @Test func searchThatDoesNotOpenIsNotReportedAsDone() async throws {
        let selection = AnalyzedSelection(text: "a term")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .search, text: selection.text, mayMutate: false)

        let report = await runner(runtime, pasteboard: pasteboard, opener: FakeURLOpener(accepts: false)).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .search,
                match: try match(.search, selection, context()),
                selection: selection,
                context: context(),
                target: editor
            )
        )

        #expect(report.outcome == .notPerformed)
        #expect(await runtime.record(of: invocation)?.outcome == .failed)
    }

    // MARK: Open Link — every address, in the order they were written

    @Test func openLinkOpensEveryAddressInOrder() async throws {
        let text = "see example.com and https://two.example and omnifocus:///task/1"
        let selection = AnalyzedSelection(
            text: text,
            detections: [
                url("https://example.com", at: 4),
                url("https://two.example", at: 20),
                Detection(
                    kind: .nonHTTPURL,
                    span: TextSpan(location: 44, length: 19),
                    value: "omnifocus:///task/1"
                ),
            ]
        )
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .openLink, text: text, mayMutate: false)

        let report = await runner(runtime, pasteboard: pasteboard, opener: opener).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .openLink,
                match: try match(.openLink, selection, context()),
                selection: selection,
                context: context(),
                target: editor
            )
        )

        #expect(report.outcome == .done)
        #expect(report.opened == 3)
        #expect(opener.urls.map(\.absoluteString) == [
            "https://example.com",
            "https://two.example",
            "omnifocus:///task/1",
        ])
        #expect(pasteboard.brokerWrites.isEmpty)
    }

    /// PRD §7.4's ⌥: the addresses as a list, and no tabs. The list is the normalised values — the
    /// addresses the selection *means*, not the shorthand it was written with.
    @Test func optionOpenLinkCopiesTheAddressesAndOpensNothing() async throws {
        let text = "example.com and https://two.example"
        let selection = AnalyzedSelection(
            text: text,
            detections: [url("https://example.com"), url("https://two.example", at: 16)]
        )
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .openLink, text: text, mayMutate: false)

        let report = await runner(runtime, pasteboard: pasteboard, opener: opener).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .openLink,
                match: try match(.openLink, selection, context()),
                selection: selection,
                context: context(),
                target: editor,
                modifiers: [.option]
            )
        )

        #expect(report.outcome == .done)
        #expect(opener.requests.isEmpty)
        #expect(pasteboard.currentText == "https://example.com\nhttps://two.example")
        #expect(report.clipboard?.characters == 39)
    }

    /// PRD §7.4's ⇧ for links: the tabs open behind whatever the user is reading.
    @Test func shiftOpenLinkOpensBehind() async throws {
        let selection = AnalyzedSelection(text: "https://example.com", detections: [url("https://example.com")])
        let pasteboard = ScriptedPasteboard(text: held)
        let opener = FakeURLOpener()
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .openLink, text: selection.text, mayMutate: false)

        _ = await runner(runtime, pasteboard: pasteboard, opener: opener).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .openLink,
                match: try match(.openLink, selection, context()),
                selection: selection,
                context: context(),
                target: editor,
                modifiers: [.shift]
            )
        )

        #expect(opener.requests.map(\.activates) == [false])
    }

    // MARK: The lifecycle, which a built-in does not get to skip (RUN-3)

    /// Escape between the click and the keystroke. The manager let go of the run, so the editor posts
    /// nothing and the runner does not finish a run that was already invalidated.
    @Test func aCancelledRunPostsNothing() async throws {
        let selection = AnalyzedSelection(text: "selected")
        let pasteboard = ScriptedPasteboard(text: held)
        let runtime = manager(FakeDestinationProbe(matching))
        let invocation = await begin(runtime, .cut, text: selection.text, mayMutate: true)
        await runtime.cancel(invocation)

        let report = await runner(runtime, pasteboard: pasteboard).run(
            BuiltinRunner.Request(
                invocation: invocation,
                builtin: .cut,
                match: try match(.cut, selection, context(canCut: true)),
                selection: selection,
                context: context(canCut: true),
                target: editor
            )
        )

        #expect(report.block?.failures.contains(.invocationNotRunning) == true)
        #expect(pasteboard.cutPosts == 0)
        #expect(await runtime.record(of: invocation)?.invalidation == .cancelled)
    }
}

/// **RUN-2a and RUN-2g: which built-ins can put host-controlled input into somebody else's process.**
///
/// The answer decides two things before anything runs — whether the key tap is held for the length of
/// the invocation, and whether a `MutationPermit` will be asked for — so it is asserted on its own
/// rather than only through the runs that depend on it.
@Suite struct BuiltinMutationTests {
    @Test func onlyTheTwoThatPressAKeyCanReachTheDestination() {
        let mutating = BuiltinAction.allCases.filter(\.mayMutateTheDestination)
        #expect(Set(mutating) == [.cut, .paste])
    }

    /// Copy says false on purpose: it writes text PappuClip already read and sends nothing into the
    /// other process (`BuiltinRunner`'s "Why Copy is not a ⌘C"). A permit-shaped Copy would be
    /// permanently broken in a web page, which is where people copy from most.
    @Test func copyIsNotAKeystroke() {
        #expect(!BuiltinAction.copy.mayMutateTheDestination)
    }

    /// Both of these leave the process entirely: a browser opens the address, and nothing is typed.
    @Test func theTwoThatLeaveTheProcessTouchNothingInside() {
        #expect(!BuiltinAction.search.mayMutateTheDestination)
        #expect(!BuiltinAction.openLink.mayMutateTheDestination)
    }
}
