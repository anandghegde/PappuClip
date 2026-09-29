import Foundation
import PappuCore
import PappuJSBridge
import Synchronization

// JS-17, JS-18, RUN-2e: the two things a run can put on screen beyond the bar — the rich result panel
// and the text prompt — as the runtime sees them. The panels themselves are `PappuSurfaces`'; the app
// joins the two (architecture §6.3). Neither is polished here: M4 week 2 gives the result panel its
// TextKit 2 view and its safe Markdown renderer (DIF-1a, DIF-3).

/// What `pappuAfter: rich-result` and `showResult` show (JS-17). The whole result, not the bar's 160
/// characters.
public struct RichResult: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable, Decodable, CaseIterable {
        case text, markdown
    }

    public var text: String
    public var format: Format

    public init(text: String, format: Format = .text) {
        self.text = text
        self.format = format
    }
}

/// One rich result on screen, with the invocation it came from still live so that Replace and Insert
/// can verify the destination when they are clicked (RUN-2e, BAR-17).
///
/// **Why the invocation stays live.** `InvocationManager.verifyDestination` answers only for a live
/// invocation, and a Replace clicked a minute after the action ran must be checked against the
/// selection as it was when the action was clicked — the snapshot the manager holds. So the runner does
/// not finish the invocation when it opens a session; the session finishes it when it is closed, with
/// `completed`. While it is open, Escape on the bar, pause and revocation cancel it exactly as they
/// would a running script (RUN-3f), and the panel hears so through `onEnd` and goes away.
///
/// **Nothing is written implicitly.** Opening a session touches neither the clipboard nor the
/// destination. Copy, Replace and Insert are each one explicit click; Replace and Insert each verify
/// the destination again, consume the permit they get, and write nothing when there is none — Copy
/// stays available whatever the destination says.
///
/// **Insert, for now.** Insert puts the result after the selection without deleting it. Collapsing the
/// selection to its end needs an Accessibility write that `AXWorld` does not have yet (M4, DIF-1a), so
/// this build pastes the verified original selection followed by the result, under the same permit:
/// the same text ends up in the field, in one undoable ⌘V.
public final class RichResultSession: Sendable, Equatable {
    /// Whether Replace and Insert can be offered, as far as can be known before they are clicked.
    public enum Destination: Sendable, Equatable {
        case available
        /// Every rule that failed. `notEditable` alone when Paste was not available at the click.
        case unavailable([DestinationFailure])
        /// The invocation is over: closed, cancelled, paused out or revoked.
        case ended
    }

    /// What a click on Replace or Insert did.
    public enum Written: Sendable, Equatable {
        case written
        /// The destination did not verify; nothing was written.
        case refused([DestinationFailure])
        /// The invocation ended first; nothing was written.
        case ended
        /// The clipboard transaction would not open; nothing was written.
        case failed
    }

    public let invocation: InvocationID
    public let result: RichResult
    /// Whether Paste was available when the action was clicked. Without it, Replace and Insert are
    /// never offered, as `paste-result` copies instead (§8.6).
    public let canWrite: Bool
    private let manager: InvocationManager
    private let mutator: TextMutator
    private let clipboard: any ClipboardKeeping
    private let target: TargetApp
    /// The selection the action was run on, which Insert keeps.
    private let original: String
    private let signal: EndSignal

    init(
        invocation: InvocationID,
        result: RichResult,
        canWrite: Bool,
        manager: InvocationManager,
        mutator: TextMutator,
        clipboard: any ClipboardKeeping,
        target: TargetApp,
        original: String,
        signal: EndSignal
    ) {
        self.invocation = invocation
        self.result = result
        self.canWrite = canWrite
        self.manager = manager
        self.mutator = mutator
        self.clipboard = clipboard
        self.target = target
        self.original = original
        self.signal = signal
    }

    /// Opens a session on a live invocation, or nil when it has already ended. The invocation is left
    /// running; `close()` ends it.
    public static func open(
        _ result: RichResult,
        for invocation: InvocationID,
        canWrite: Bool,
        original: String,
        target: TargetApp,
        manager: InvocationManager,
        mutator: TextMutator,
        clipboard: any ClipboardKeeping
    ) async -> RichResultSession? {
        let signal = EndSignal()
        guard await manager.attach(SessionWork(signal: signal), to: invocation) else { return nil }
        return RichResultSession(
            invocation: invocation,
            result: result,
            canWrite: canWrite,
            manager: manager,
            mutator: mutator,
            clipboard: clipboard,
            target: target,
            original: original,
            signal: signal
        )
    }

    deinit {
        // A session let go of without being closed must not leave its invocation live for ever.
        guard !signal.hasEnded else { return }
        let manager = manager
        let invocation = invocation
        Task { await manager.finish(invocation, outcome: .completed) }
    }

    public static func == (lhs: RichResultSession, rhs: RichResultSession) -> Bool { lhs === rhs }

    /// Whether the session is over. Once true, it stays true.
    public var hasEnded: Bool { signal.hasEnded }

    /// Called once, on whatever thread ends the session: `close()`, or a cancel, pause or revocation
    /// of the invocation. Called at once when the session has already ended.
    public func onEnd(_ handler: @escaping @Sendable () -> Void) {
        signal.add(handler)
    }

    /// RUN-2e's disabled state: whether Replace and Insert would verify now. The permit the check gets
    /// is dropped unspent; the click verifies again.
    public func destination() async -> Destination {
        guard canWrite else { return .unavailable([.notEditable]) }
        guard !signal.hasEnded, await manager.accepts(invocation) else { return .ended }
        let verification = await manager.verifyDestination(of: invocation)
        switch consume verification {
        case .blocked(let block):
            return block.failures == [.invocationNotRunning] ? .ended : .unavailable(block.failures)
        case .verified:
            return .available
        }
    }

    /// Copy: the whole result, to the clipboard, kept. Available whatever the destination says.
    public func copy() async -> Bool {
        guard !result.text.isEmpty else { return false }
        return await clipboard.write(result.text, for: invocation, into: target).written
    }

    /// Replace: the verified original selection becomes the result (BAR-17).
    public func replace() async -> Written {
        await write(result.text)
    }

    /// Insert: the result after the verified original selection, which stays (BAR-17).
    public func insert() async -> Written {
        await write(original + result.text)
    }

    private func write(_ text: String) async -> Written {
        guard canWrite else { return .refused([.notEditable]) }
        guard !signal.hasEnded else { return .ended }
        // RUN-2e: verified at the click, whatever was known when the panel opened.
        let verification = await manager.verifyDestination(of: invocation)
        switch consume verification {
        case .blocked(let block):
            return block.failures == [.invocationNotRunning] ? .ended : .refused(block.failures)
        case .verified(let permit):
            return switch await mutator.replaceSelection(with: text, using: permit).outcome {
            case .mutated, .clipboardContested: .written
            case .notRunning: .ended
            case .clipboardRefused: .failed
            }
        }
    }

    /// Close: the panel went away. The invocation is finished as completed, since the action did run;
    /// a session already ended by a cancel stays cancelled.
    public func close() async {
        guard signal.end() else { return }
        await manager.finish(invocation, outcome: .completed)
    }
}

/// The session's end, told once to whoever listens.
final class EndSignal: Sendable {
    private struct State {
        var ended = false
        var handlers: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    var hasEnded: Bool { state.withLock { $0.ended } }

    func add(_ handler: @escaping @Sendable () -> Void) {
        let now = state.withLock { state -> Bool in
            if state.ended { return true }
            state.handlers.append(handler)
            return false
        }
        if now { handler() }
    }

    /// True for the call that ended it.
    @discardableResult
    func end() -> Bool {
        let handlers = state.withLock { state -> [@Sendable () -> Void]? in
            guard !state.ended else { return nil }
            state.ended = true
            defer { state.handlers = [] }
            return state.handlers
        }
        guard let handlers else { return false }
        for handler in handlers { handler() }
        return true
    }
}

/// What the manager holds for an open session, so that cancelling the invocation closes the panel.
private struct SessionWork: CancellableWork {
    let signal: EndSignal
    var ownership: WorkOwnership { .owned }

    func cancel() async -> WorkCancellation {
        signal.end()
        return .stopped
    }
}

// MARK: - The prompt (JS-18)

/// What `pappuclip.promptText` asks the user.
public struct TextPromptRequest: Sendable, Equatable {
    /// Required, and never empty: a field with no label is a field nobody can name (VoiceOver included).
    public var label: String
    public var placeholder: String
    public var defaultValue: String
    /// The extension that asked, by name, so that a prompt is never anonymous. Empty when unknown.
    public var source: String

    public init(label: String, placeholder: String = "", defaultValue: String = "", source: String = "") {
        self.label = label
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.source = source
    }
}

/// How the prompt ended.
public enum TextPromptAnswer: Sendable, Equatable {
    /// Submit, with what was in the field, which may be empty.
    case submitted(String)
    /// Cancel, Escape, closing the panel, or the invocation ending under it.
    case cancelled
    /// No prompt could be shown: one is already up, or there is nowhere to show it.
    case unavailable
}

/// Shows the prompt and waits for it (the app's panel; a fake in tests).
///
/// Cancelling the calling task means the invocation ended: the panel must close, and the answer is
/// `cancelled`.
public protocol TextPrompting: Sendable {
    func prompt(_ request: TextPromptRequest, for invocation: InvocationID) async -> TextPromptAnswer
}

/// `pappuclip.promptText({label, placeholder, defaultValue})` (JS-18), as a host call group.
///
/// **Only while an explicitly invoked action runs.** The dispatcher has already refused a population
/// function (JS-13) and a run that is over (RUN-3b) by the time `perform` is called.
///
/// **Cancel cancels the invocation** (RUN-3): Cancel, Escape and closing the panel each end the whole
/// run, not only the prompt, and the script's promise is refused. The other way round, a run cancelled
/// while its prompt is up closes the prompt, because the prompt is attached to the invocation as work
/// of its own. A prompt answered after the run ended has no effect.
public struct PromptHostCalls: HostCallHandling {
    public static let method = "promptText"
    /// Long enough for a sentence; a label is not a document.
    public static let labelLimit = 200

    private let manager: InvocationManager
    private let prompter: any TextPrompting

    public init(manager: InvocationManager, prompter: any TextPrompting) {
        self.manager = manager
        self.prompter = prompter
    }

    public var methods: Set<String> { [Self.method] }

    /// Asking the user is what running the extension was approved to do.
    public func gate(for method: String, in run: HostAPIDispatcher.Run) -> GatedCapability? { nil }

    public func perform(_ method: String, arguments: Data, for run: HostAPIDispatcher.Run) async throws -> JSHostAnswer {
        let given = try JSONDecoder().decode(Given.self, from: arguments)
        let label = given.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw HostCallRefusal("promptText needs a label.") }
        guard label.count <= Self.labelLimit else { throw HostCallRefusal("promptText's label is longer than \(Self.labelLimit) characters.") }
        let request = TextPromptRequest(
            label: label,
            placeholder: given.placeholder ?? "",
            defaultValue: given.defaultValue ?? "",
            source: run.action?.extensionName.text(for: .current) ?? ""
        )

        let invocation = run.invocation
        let prompter = prompter
        let asking = Task { await prompter.prompt(request, for: invocation) }
        guard await manager.attach(PromptWork(task: asking), to: invocation) else {
            asking.cancel()
            return .refused("The action is no longer running.")
        }
        let answer = await asking.value
        // RUN-3c: an answer that arrives after the run ended is thrown away.
        guard await manager.accepts(invocation) else { return .refused("The action is no longer running.") }
        switch answer {
        case .submitted(let text):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return .value(String(decoding: try encoder.encode(text), as: UTF8.self))
        case .cancelled:
            await manager.cancel(invocation, reason: .cancelled)
            return .refused("The action is no longer running.")
        case .unavailable:
            throw HostCallRefusal("promptText could not show a prompt now.")
        }
    }

    private struct Given: Decodable {
        var label: String
        var placeholder: String?
        var defaultValue: String?
    }
}

/// The open prompt, as the manager holds it: cancelling the invocation cancels the task, which closes
/// the panel.
private struct PromptWork: CancellableWork {
    let task: Task<TextPromptAnswer, Never>
    var ownership: WorkOwnership { .owned }

    func cancel() async -> WorkCancellation {
        task.cancel()
        return .stopped
    }
}
