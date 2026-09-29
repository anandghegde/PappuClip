import Foundation
@testable import PappuSurfaces
import Synchronization
import Testing

/// What the result panel's buttons asked for, and what they were told.
private final class PanelScript: Sendable {
    private struct State {
        var destination: ResultPanelActions.Destination = .available
        var written: ResultPanelActions.Written = .written
        var calls: [String] = []
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }

    func set(destination: ResultPanelActions.Destination) { state.withLock { $0.destination = destination } }
    func set(written: ResultPanelActions.Written) { state.withLock { $0.written = written } }

    var actions: ResultPanelActions {
        ResultPanelActions(
            destination: { self.state.withLock { $0.calls.append("destination"); return $0.destination } },
            copy: { self.state.withLock { $0.calls.append("copy") }; return true },
            replace: { self.state.withLock { $0.calls.append("replace"); return $0.written } },
            insert: { self.state.withLock { $0.calls.append("insert"); return $0.written } },
            close: { self.state.withLock { $0.calls.append("close") } }
        )
    }
}

@MainActor
@Suite struct NativePanelTests {
    // MARK: Strings (§1.3)

    @Test func everyStringThePanelsSayIsInTheCatalogue() {
        for key in PanelStrings.all {
            let missing = "\u{1}missing\u{1}"
            let value = PanelStrings.bundle.localizedString(forKey: key, value: missing, table: nil)
            #expect(value != missing, "\(key) has no entry in Localizable.strings")
        }
        #expect(PanelStrings.replace == "Replace Selection")
        #expect(PanelStrings.promptSource("Test") == "Asked by Test")
    }

    // MARK: JS-17, RUN-2e: the result panel

    @Test func copyStaysAvailableWhenReplaceAndInsertAreNot() async {
        let script = PanelScript()
        script.set(destination: .unavailable("The selection has changed since the action ran"))
        let model = ResultPanelModel(title: "Result", text: "RESULT", format: .text, actions: script.actions)
        #expect(!model.canWrite)
        #expect(model.explanation == PanelStrings.checking)

        await model.refresh()
        #expect(!model.canWrite)
        #expect(model.canCopy)
        #expect(model.explanation == PanelStrings.unavailable("The selection has changed since the action ran"))

        // A disabled button does nothing even if something calls it.
        await model.replace()
        await model.insert()
        #expect(!script.calls.contains("replace"))
        #expect(!script.calls.contains("insert"))

        await model.copy()
        #expect(model.status == PanelStrings.copied)
        #expect(!model.isClosed)
    }

    /// The check when the panel opened enabled Replace; the click checks again and is refused.
    @Test func aRefusedClickDisablesReplaceAndInsertAndSaysWhy() async {
        let script = PanelScript()
        let model = ResultPanelModel(title: "Result", text: "RESULT", format: .text, actions: script.actions)
        await model.refresh()
        #expect(model.canWrite)
        #expect(model.explanation == nil)

        script.set(written: .refused("Focus has moved to a different window or field"))
        await model.replace()
        #expect(!model.canWrite)
        #expect(model.canCopy)
        #expect(model.explanation == PanelStrings.unavailable("Focus has moved to a different window or field"))
        #expect(!model.isClosed)
    }

    @Test func aWriteThatLandsClosesThePanelOnce() async {
        let script = PanelScript()
        let model = ResultPanelModel(title: "Result", text: "RESULT", format: .markdown, actions: script.actions)
        var closes = 0
        model.onClose = { closes += 1 }
        await model.refresh()
        await model.insert()
        #expect(model.isClosed)
        #expect(closes == 1)
        #expect(script.calls == ["destination", "insert", "close"])

        await model.close()
        model.ended()
        #expect(closes == 1)
        #expect(script.calls.filter { $0 == "close" }.count == 1)
        #expect(!model.canCopy)
    }

    /// The invocation ended under the panel (cancel, pause, revoke): it closes without calling back.
    @Test func theInvocationEndingClosesThePanelWithoutClosingItAgain() async {
        let script = PanelScript()
        let model = ResultPanelModel(title: "Result", text: "RESULT", format: .text, actions: script.actions)
        var closes = 0
        model.onClose = { closes += 1 }
        model.ended()
        #expect(model.isClosed)
        #expect(closes == 1)
        await model.refresh()
        await model.copy()
        #expect(script.calls.isEmpty)
    }

    @Test func aClickThatFindsTheRunOverClosesThePanel() async {
        let script = PanelScript()
        let model = ResultPanelModel(title: "Result", text: "RESULT", format: .text, actions: script.actions)
        await model.refresh()
        script.set(written: .ended)
        await model.replace()
        #expect(model.isClosed)
    }

    // MARK: JS-17: Markdown that cannot reach out

    @Test func markdownKeepsEmphasisAndLosesEveryWayOut() {
        let rendered = SafeMarkdown.render("**bold** [site](https://example.com) ![img](https://example.com/a.png) <script>x()</script>")
        #expect(!SafeMarkdown.reachesOut(rendered))
        let text = String(rendered.characters)
        #expect(text.contains("bold"))
        #expect(!text.contains("**"))
        #expect(text.contains("site"))
        #expect(text.contains("<script>x()</script>"))
        #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func plainTextIsShownAsWritten() {
        let shown = ResultPanelController.attributed("**not bold**\n  two", format: .text)
        #expect(shown.string == "**not bold**\n  two")
    }

    // MARK: JS-18: the prompt

    @Test func submitAnswersWithTheFieldEvenEmpty() {
        var answers: [PromptPanelAnswer] = []
        let model = PromptPanelModel(label: "Name", placeholder: "you", defaultValue: "me", source: "Test") { answers.append($0) }
        #expect(model.value == "me")
        model.value = ""
        var closes = 0
        model.onClose = { closes += 1 }
        model.submit()
        model.cancel()
        #expect(answers == [.submitted("")])
        #expect(closes == 1)
    }

    @Test func cancelEscapeAndCloseAnswerCancelledOnce() {
        var answers: [PromptPanelAnswer] = []
        let model = PromptPanelModel(label: "Name", placeholder: "", defaultValue: "", source: "Test") { answers.append($0) }
        model.cancel()
        model.cancel()
        model.submit()
        #expect(answers == [.cancelled])
    }

    /// The invocation ended first: the prompt closes, and nothing is answered back into a run that is
    /// already over.
    @Test func theInvocationEndingClosesThePromptWithoutAnAnswer() {
        var answers: [PromptPanelAnswer] = []
        let model = PromptPanelModel(label: "Name", placeholder: "", defaultValue: "", source: "Test") { answers.append($0) }
        var closes = 0
        model.onClose = { closes += 1 }
        model.ended()
        model.submit()
        #expect(answers.isEmpty)
        #expect(closes == 1)
        #expect(model.isAnswered)
    }
}
