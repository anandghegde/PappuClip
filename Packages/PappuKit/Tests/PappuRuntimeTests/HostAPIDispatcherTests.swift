import Foundation
import PappuAnalysis
import PappuAX
import PappuCore
import PappuJSBridge
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

/// The system's services, answering fixed things and noting what they were asked.
final class FakeHostServices: HostServices {
    private let asked = Mutex<[String]>([])

    var calls: [String] { asked.withLock { $0 } }

    private func note(_ call: String) {
        asked.withLock { $0.append(call) }
    }

    func reveal(_ url: URL) async -> Bool {
        note("reveal \(url.path)")
        return true
    }

    func share(_ items: [HostShareItem], with service: String) async -> String? {
        note("share \(service) \(items)")
        return service == "broken" ? "It did not work." : nil
    }

    func definition(of text: String) async -> String? { text == "cat" ? "a small animal" : nil }
    func spellingLanguages() async -> [SpellingLanguage] { [SpellingLanguage(code: "en", name: "English")] }
    func preferredSpellingLanguages() async -> [String] { ["en"] }
    func checkSpelling(_ text: String, language: String) async -> Bool? { language == "en" ? text != "teh" : nil }

    func spellingGuesses(for text: String, language: String, limit: Int?) async -> [String]? {
        language == "en" ? Array(["the", "ten"].prefix(limit ?? 9)) : nil
    }

    func convert(_ source: String, from format: RichTextFormat) async -> RichTextForms? {
        note("convert \(format.rawValue)")
        return RichTextForms(rtf: "{\\rtf1 \(source)}", html: "<p>\(source)</p>")
    }
}

/// The real manager, verifier, broker, editor, mutator and presser, with fakes only at the edges, as
/// `ExtensionRunnerTests` has them.
private struct HostScene {
    let manager: InvocationManager
    let pasteboard: ScriptedPasteboard
    let opener = FakeURLOpener()
    let keys = FakeKeyPresses()
    let scripts = FakeScripts()
    let system = FakeHostServices()
    let effects: HostAPIDispatcher.Effects

    init(probe: FakeDestinationProbe = FakeDestinationProbe(settled()), frontmost: TargetApp = editor, clipboard: String? = "held") {
        let clock = ManualTimeSource()
        let manager = InvocationManager(
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
        effects = HostAPIDispatcher.Effects(
            manager: manager,
            mutator: TextMutator(clipboard: broker, manager: manager),
            editor: SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager),
            presser: KeyPresser(poster: keys, manager: manager, sleep: SteppingSleep()),
            clipboard: broker,
            urls: opener,
            services: scripts,
            system: system
        )
    }

    /// A running invocation, and a dispatcher for it.
    func dispatcher(
        gates: Set<GatedCapability> = [.unboundedCode],
        phase: HostPhase = .action,
        canPaste: Bool = true,
        browser: BrowserPage? = nil
    ) async -> HostAPIDispatcher {
        let invocation = await manager.begin(InvocationRequest(
            attempt: AttemptID(rawValue: 1),
            route: .automatic,
            target: editor,
            action: "com.example.test#0",
            mayMutate: true,
            text: "selected",
            range: AXTextRange(location: 10, length: 5),
            strategy: .ax,
            owner: "owner"
        ))
        return HostAPIDispatcher(
            run: HostAPIDispatcher.Run(
                invocation: invocation,
                phase: phase,
                gates: gates,
                context: SelectionContext(
                    app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                    editability: Editability(isEditable: true, source: .settableSelectedText),
                    canCut: true,
                    canCopy: true,
                    canPaste: canPaste,
                    browser: browser
                ),
                target: editor,
                text: "selected"
            ),
            effects: effects
        )
    }

    /// The plain text of every write the broker made, a paste's hold and restore included.
    var written: [String] {
        pasteboard.brokerWrites.compactMap { items in
            items.first?.first { $0.type == PasteboardRepresentation.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
        }
    }
}

private func call(_ method: String, _ arguments: String = "{}") -> JSHostCall {
    JSHostCall(invocation: 1, extensionName: "owner", method: method, arguments: arguments)
}

// MARK: The checks, in order (architecture §10.4)

@Suite struct HostAPIDispatcherCheckTests {
    /// JS-15, RUN-3b: once the run is cancelled, a call it makes — a promise that resolved late — does
    /// nothing at all.
    @Test func aCallAfterCancellationHasNoEffect() async {
        let scene = HostScene()
        let host = await scene.dispatcher()
        await scene.manager.cancel(host.run.invocation)
        #expect(await host.perform(call("pasteText", #"{"text":"late","restore":false}"#)) == .refused("The action is no longer running."))
        #expect(await host.perform(call("copyText", #"{"text":"late","notify":true}"#)) == .refused("The action is no longer running."))
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(host.requests == HostRequests())
    }

    /// JS-13: a population function has no invocation to act for and may ask for nothing.
    @Test func populationMayAskForNothing() async {
        let scene = HostScene()
        let host = await scene.dispatcher(phase: .population)
        for method in HostMethod.allCases {
            guard case .refused = await host.perform(call(method.rawValue)) else {
                Issue.record("\(method) was not refused during population")
                continue
            }
        }
        #expect(scene.system.calls.isEmpty)
    }

    /// SEC-7b: pressing keys, a Service and sharing need the synthetic-input grant, checked at the call.
    @Test func aCallOutsideTheGrantsIsRefusedAndDoesNothing() async throws {
        let scene = HostScene()
        let host = await scene.dispatcher(gates: [.unboundedCode])
        let press = call("pressKeys", #"{"steps":[{"combo":"command b","modifiers":0}],"target":null}"#)
        guard case .refused(let why) = await host.perform(press) else { return Issue.record("pressKeys was not refused") }
        #expect(why.contains("synthetic-input"))
        #expect(scene.keys.combos.isEmpty)
        guard case .refused = await host.perform(call("performService", #"{"name":"S","content":{"public.utf8-plain-text":"x"}}"#)) else {
            return Issue.record("performService was not refused")
        }
        guard case .refused = await host.perform(call("share", #"{"service":"s","items":[{"text":"x"}]}"#)) else {
            return Issue.record("share was not refused")
        }
        #expect(scene.scripts.calls.isEmpty)
        #expect(scene.system.calls.isEmpty)

        let granted = await scene.dispatcher(gates: [.unboundedCode, .syntheticInput])
        #expect(await granted.perform(press) == .done)
        let pressed = try KeyCombo.parse("command b")
        #expect(scene.keys.combos == [pressed])
    }

    @Test func anUnknownMethodOrTheWrongArgumentsAreRefused() async {
        let host = await HostScene().dispatcher()
        #expect(await host.perform(call("formatDisk")) == .refused("There is no host method formatDisk."))
        #expect(await host.perform(call("copyText", #"{"text":3}"#)) == .refused("copyText was not given what it takes."))
        #expect(await host.perform(call("copyText", "not json")) == .refused("copyText was not given what it takes."))
    }

    @Test func eachMethodSaysWhatItNeeds() {
        #expect(HostMethod.allCases.filter { $0.gate != nil } == [.pressKeys, .performService, .share])
        #expect(HostMethod.allCases.filter(\.entersTheDestination) == [.pasteText, .pasteContent, .performCommand, .pressKeys])
    }
}

// MARK: The methods (JS-4, JS-6, JS-7)

@Suite struct HostAPIDispatcherMethodTests {
    /// RUN-2a: a paste verifies the destination first, then holds the text for one ⌘V. PopClip leaves it
    /// on the clipboard afterwards unless `restore`.
    @Test func pasteTextPastesOverTheVerifiedSelection() async {
        let scene = HostScene()
        let host = await scene.dispatcher()
        #expect(await host.perform(call("pasteText", #"{"text":"new","restore":false}"#)) == .done)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(scene.pasteboard.currentText == "new")
        #expect(await scene.manager.record(of: host.run.invocation)?.mutated == true)

        let restoring = await scene.dispatcher()
        #expect(await restoring.perform(call("pasteText", #"{"text":"again","restore":true}"#)) == .done)
        #expect(scene.pasteboard.pastePosts == 2)
        #expect(scene.pasteboard.currentText == "new")
    }

    @Test func pasteTextCopiesWherePasteWasNotAvailable() async {
        let scene = HostScene()
        let host = await scene.dispatcher(canPaste: false)
        #expect(await host.perform(call("pasteText", #"{"text":"new","restore":false}"#)) == .done)
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(scene.pasteboard.currentText == "new")
        #expect(host.requests.display == .copied)
    }

    /// RUN-2c: a destination that cannot be verified gets nothing, and nor does the clipboard.
    @Test func aDestinationThatMovedGetsNothing() async {
        let scene = HostScene(probe: FakeDestinationProbe(DestinationEvidence(isFrontmost: false)), frontmost: terminal)
        let host = await scene.dispatcher()
        guard case .failed = await host.perform(call("pasteText", #"{"text":"new","restore":false}"#)) else {
            return Issue.record("the paste was not refused")
        }
        guard case .failed = await host.perform(call("pressKeys", #"{"steps":[{"keyCode":36,"modifiers":0}]}"#)) else {
            return Issue.record("the key press was not refused")
        }
        #expect(scene.pasteboard.brokerWrites.isEmpty)
        #expect(scene.pasteboard.pastePosts == 0)
        #expect(scene.keys.combos.isEmpty)
    }

    @Test func pasteContentHoldsEveryTextType() async {
        let scene = HostScene()
        let host = await scene.dispatcher()
        let arguments = #"{"content":{"public.utf8-plain-text":"x","public.html":"<b>x</b>","image/png":"no"},"restore":true}"#
        #expect(await host.perform(call("pasteContent", arguments)) == .done)
        let held = scene.pasteboard.brokerWrites.first?.first?.map(\.type) ?? []
        #expect(Array(held.prefix(2)) == ["public.utf8-plain-text", "public.html"])
        #expect(!held.contains("image/png"))
    }

    @Test func copyTextAndCopyContentKeepWhatTheyAreGiven() async {
        let scene = HostScene()
        let host = await scene.dispatcher()
        #expect(await host.perform(call("copyText", #"{"text":"one","notify":false}"#)) == .done)
        #expect(host.requests.display == nil)
        #expect(await host.perform(call("copyContent", #"{"content":{"public.rtf":"{\\rtf1 x}"},"notify":true}"#)) == .done)
        #expect(scene.pasteboard.currentTypes == [["public.rtf"]])
        #expect(host.requests.display == .copied)
        #expect(await host.perform(call("copyContent", #"{"content":{"image/png":"no"},"notify":true}"#)) == .refused("The content has no plain text, HTML or RTF in it."))
    }

    @Test func performCommandCutsPastesAndCopies() async {
        let scene = HostScene()
        let host = await scene.dispatcher()
        #expect(await host.perform(call("performCommand", #"{"command":"cut","plain":false}"#)) == .done)
        #expect(scene.pasteboard.cutPosts == 1)
        #expect(await host.perform(call("performCommand", #"{"command":"paste","plain":false}"#)) == .done)
        #expect(scene.pasteboard.pastePosts == 1)
        #expect(await host.perform(call("performCommand", #"{"command":"copy","plain":false}"#)) == .done)
        #expect(scene.pasteboard.currentText == "selected")
        #expect(await host.perform(call("performCommand", #"{"command":"undo","plain":false}"#)) == .refused("performCommand takes cut, copy or paste."))
    }

    @Test func whatIsShownIsAskedOfTheBarAndTheLastWins() async {
        let host = await HostScene().dispatcher()
        #expect(await host.perform(call("showSuccess")) == .done)
        #expect(host.requests.display == .success)
        _ = await host.perform(call("showText", #"{"text":"\#(String(repeating: "a", count: 200))","style":"compact","preview":false}"#))
        #expect(host.requests.display == .text(String(repeating: "a", count: 159) + "…"))
        _ = await host.perform(call("appear"))
        #expect(host.requests.display == .appear)
        _ = await host.perform(call("showFailure"))
        _ = await host.perform(call("showSettings"))
        #expect(host.requests == HostRequests(display: .failure, settings: true))
    }

    @Test func keysAreReadAsAKeyPressActionReadsThem() async throws {
        let scene = HostScene()
        let host = await scene.dispatcher(gates: [.unboundedCode, .syntheticInput])
        let steps = #"[{"combo":"b","modifiers":1048576},{"wait":20},{"keyCode":121,"modifiers":524288}]"#
        #expect(await host.perform(call("pressKeys", #"{"steps":\#(steps),"target":"hid"}"#)) == .done)
        let expected = [try KeyCombo.parse("command b"), try KeyCombo.legacy(keyCode: 121, keyCharacter: nil, modifiers: 524_288)]
        #expect(scene.keys.combos == expected)
        #expect(scene.keys.deliveries.map(\.target) == [.hid, .hid])
        #expect(await host.perform(call("pressKeys", #"{"steps":[{"combo":"hyper q","modifiers":0}]}"#)) == .refused("pressKeys was given a key it cannot read."))
        #expect(scene.keys.combos.count == 2)
    }

    @Test func aServiceRunsInTheRunnerWithThePlainText() async {
        let scene = HostScene()
        let host = await scene.dispatcher(gates: [.unboundedCode, .syntheticInput])
        #expect(await host.perform(call("performService", #"{"name":"Make Sticky","content":{"public.utf8-plain-text":"note"}}"#)) == .done)
        #expect(scene.scripts.calls == [.service(name: "Make Sticky", text: "note")])
    }

    /// PRD §7.4's rule for web addresses, and no files: opening a file is running it.
    @Test func openUrlOpensInTheBrowserTheTextCameFrom() async {
        let scene = HostScene()
        let browser = BrowserPage(url: URL(string: "https://example.com"), title: "Example", source: .accessibility)
        let host = await scene.dispatcher(browser: browser)
        #expect(await host.perform(call("openUrl", #"{"url":"https://a.test/?q=1","app":null,"activate":true,"backgroundTab":false}"#)) == .done)
        #expect(await host.perform(call("openUrl", #"{"url":"mailto:a@b.test","app":null,"activate":true,"backgroundTab":true}"#)) == .done)
        #expect(await host.perform(call("openUrl", #"{"url":"https://c.test/","app":"com.brave.Browser","activate":true,"backgroundTab":false}"#)) == .done)
        #expect(scene.opener.requests.map(\.browserBundleID) == [editor.bundleID, nil, "com.brave.Browser"])
        #expect(scene.opener.requests.map(\.activates) == [true, false, true])
        #expect(await host.perform(call("openUrl", #"{"url":"file:///Applications/Calculator.app","app":null,"activate":true,"backgroundTab":false}"#)) == .refused("openUrl was not given an address it may open."))
        #expect(scene.opener.requests.count == 3)
    }

    @Test func openTemplateUrlIsAURLActionsExpansion() async {
        let scene = HostScene()
        let host = await scene.dispatcher()
        let arguments = #"{"template":"https://{popclip option site}/s?q=***","query":" two words ","clean":false,"plus":true,"verbatim":true,"copy":true,"options":{"site":"x.test"},"app":null,"activate":true,"backgroundTab":false}"#
        #expect(await host.perform(call("openTemplateUrl", arguments)) == .done)
        #expect(scene.opener.urls == [URL(string: "https://x.test/s?q=%22two+words%22")!])
        #expect(scene.pasteboard.currentText == "two words")
    }

    @Test func thePasteboardIsReadAndWrittenAsText() async {
        let scene = HostScene(clipboard: "on the clipboard")
        let host = await scene.dispatcher()
        #expect(await host.perform(call("pasteboard.read")) == .value(#"{"public.utf8-plain-text":"on the clipboard"}"#))
        #expect(await host.perform(call("pasteboard.write", #"{"content":{"public.utf8-plain-text":"set","public.html":"<i>set</i>"}}"#)) == .done)
        #expect(scene.pasteboard.currentTypes == [["public.utf8-plain-text", "public.html"]])
        scene.pasteboard.set(access: .ask)
        #expect(await host.perform(call("pasteboard.read")) == .failed("The clipboard cannot be read now."))
    }

    @Test func theSystemAnswersThroughItsSeam() async {
        let scene = HostScene()
        let host = await scene.dispatcher(gates: [.unboundedCode, .syntheticInput])
        #expect(await host.perform(call("dictionary.define", #"{"text":"cat"}"#)) == .value(#""a small animal""#))
        #expect(await host.perform(call("dictionary.define", #"{"text":"zzz"}"#)) == .value("null"))
        #expect(await host.perform(call("spelling.languages")) == .value(#"[{"code":"en","name":"English"}]"#))
        #expect(await host.perform(call("spelling.check", #"{"text":"teh","language":"en"}"#)) == .value("false"))
        #expect(await host.perform(call("spelling.guesses", #"{"text":"teh","language":"en","limit":1}"#)) == .value(#"["the"]"#))
        #expect(await host.perform(call("spelling.check", #"{"text":"x","language":"xx"}"#)) == .refused("The spell checker has no language xx."))
        #expect(await host.perform(call("richText.convert", #"{"source":"# T","format":"markdown"}"#)) == .value(#"{"html":"<p># T</p>","rtf":"{\\rtf1 # T}"}"#))
        #expect(await host.perform(call("share", #"{"service":"com.apple.share.Messages","items":[{"text":"t"},{"url":"https://a.test/"},{"rich":{"source":"<b>x</b>","format":"html"}}]}"#)) == .done)
        #expect(await host.perform(call("share", #"{"service":"broken","items":[{"text":"t"}]}"#)) == .failed("It did not work."))
        #expect(await host.perform(call("revealFile", #"{"path":"/"}"#)) == .done)
        #expect(await host.perform(call("revealFile", #"{"path":"/nothing/here/at/all"}"#)) == .failed("There is nothing at that path."))
        #expect(scene.system.calls.contains("reveal /"))
    }
}
