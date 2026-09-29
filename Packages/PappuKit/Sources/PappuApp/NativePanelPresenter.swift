import AppKit
import Foundation
import PappuCore
import PappuRuntime
import PappuSurfaces

/// Where the bridge hands a rich result once its run is over (JS-17).
@MainActor
public protocol ResultPresenting: AnyObject, Sendable {
    func present(_ session: RichResultSession, title: String)
}

/// The join between the runtime's rich result sessions and prompts and `PappuSurfaces`' panels
/// (JS-17, JS-18, RUN-2e). `PappuRuntime` and `PappuSurfaces` may not see each other, so this is where a
/// `DestinationFailure` becomes words and a `RichResultSession` becomes buttons.
///
/// **The bar goes first.** Its key tap takes the keys it knows (BAR-9), so a prompt that wants typing
/// dismisses the bar before it takes the keyboard, and a result panel replaces the bar rather than
/// sitting beside it.
///
/// **Focus.** While the prompt has the keyboard the manager is told that focus is in PappuClip's own
/// surface (RUN-1c), so the move is recorded as ours and not as a new destination.
@MainActor
public final class NativePanelPresenter: ResultPresenting, TextPrompting {
    private let manager: InvocationManager
    private weak var bar: (any InvocationReporting)?
    /// The one prompt up, if any, and how to answer it.
    private var prompt: (call: PromptCall, model: PromptPanelModel)?

    public init(manager: InvocationManager) {
        self.manager = manager
    }

    /// The bar, to dismiss before a panel appears. Attached after, like the bridge's.
    public func attach(bar: any InvocationReporting) {
        self.bar = bar
    }

    // MARK: ResultPresenting

    public func present(_ session: RichResultSession, title: String) {
        bar?.dismiss(.actionRun)
        let model = ResultPanelModel(
            title: title.isEmpty ? PanelStrings.resultTitle : title,
            text: session.result.text,
            format: session.result.format == .markdown ? .markdown : .text,
            actions: Self.actions(for: session)
        )
        let controller = ResultPanelController(model: model)
        // A cancel, pause or revocation of the invocation closes the panel (RUN-3f).
        session.onEnd { Task { @MainActor in model.ended() } }
        controller.show()
    }

    /// The panel's buttons, over the session.
    public nonisolated static func actions(for session: RichResultSession) -> ResultPanelActions {
        ResultPanelActions(
            destination: {
                switch await session.destination() {
                case .available: .available
                case .unavailable(let failures): .unavailable(explanation(for: failures))
                case .ended: .ended
                }
            },
            copy: { await session.copy() },
            replace: { written(await session.replace()) },
            insert: { written(await session.insert()) },
            close: { await session.close() }
        )
    }

    nonisolated static func written(_ written: RichResultSession.Written) -> ResultPanelActions.Written {
        switch written {
        case .written: .written
        case .refused(let failures): .refused(explanation(for: failures))
        case .ended: .ended
        case .failed: .failed
        }
    }

    /// RUN-2e's explanation: the first failure the user can do something about, in words.
    public nonisolated static func explanation(for failures: [DestinationFailure]) -> String {
        guard let first = failures.first else { return PanelStrings.destinationUnknown }
        return switch first {
        case .privacyRefused: PanelStrings.destinationPrivacy
        case .invocationNotRunning: PanelStrings.destinationEnded
        case .notFrontmost: PanelStrings.destinationNotFrontmost
        case .windowChanged, .elementChanged: PanelStrings.destinationMoved
        case .notEditable: PanelStrings.destinationNotEditable
        case .selectionMoved, .selectionChanged: PanelStrings.destinationSelectionChanged
        case .inputSinceSnapshot, .windowExpired: PanelStrings.destinationInput
        case .accessibilityUnanswered, .notReadThroughAccessibility, .inputUnwatchable, .quiescenceNotAllowed:
            PanelStrings.destinationUnknown
        }
    }

    // MARK: TextPrompting

    public nonisolated func prompt(_ request: TextPromptRequest, for invocation: InvocationID) async -> TextPromptAnswer {
        // The call's own state, shared by the show and the cancel and gone with them: nothing about a
        // call outlives it, whichever of the two reaches the main actor first.
        let call = PromptCall()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TextPromptAnswer, Never>) in
                Task { @MainActor in self.show(request, call: call, answer: continuation) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelPrompt(call) }
        }
    }

    private func show(_ request: TextPromptRequest, call: PromptCall, answer: CheckedContinuation<TextPromptAnswer, Never>) {
        guard call.begin() else { return answer.resume(returning: .cancelled) }
        // One prompt at a time: a second one while the first is up is refused, not stacked.
        guard prompt == nil else {
            call.finish()
            return answer.resume(returning: .unavailable)
        }
        bar?.dismiss(.actionRun)
        let manager = manager
        let model = PromptPanelModel(
            label: request.label,
            placeholder: request.placeholder,
            defaultValue: request.defaultValue,
            source: request.source
        ) { [weak self] given in
            call.finish()
            self?.prompt = nil
            Task { await manager.focusLeftOwnSurface() }
            answer.resume(returning: given == .cancelled ? .cancelled : .submitted(Self.text(of: given)))
        }
        prompt = (call, model)
        let controller = PromptPanelController(model: model)
        Task { await manager.focusEnteredOwnSurface() }
        controller.show()
    }

    private static func text(of answer: PromptPanelAnswer) -> String {
        if case .submitted(let text) = answer { return text }
        return ""
    }

    /// The invocation ended while its prompt was up, or before it was shown.
    private func cancelPrompt(_ call: PromptCall) {
        guard call.cancel(), let prompt, prompt.call === call else { return }
        // Answered as cancelled so the waiting call returns; the run is already over, so the answer
        // is thrown away there (RUN-3c).
        prompt.model.cancel()
    }
}

/// One `prompt` call's progress (JS-18). A cancel can reach the main actor before the show does, after
/// it, or after the answer; each call keeps its own state, so none of these leaves anything behind in
/// the presenter.
@MainActor
final class PromptCall {
    enum State: Equatable {
        case waiting, shown, cancelledEarly, finished
    }

    private(set) var state: State = .waiting

    nonisolated init() {}

    /// Whether to show the prompt: false when it was cancelled before it could be.
    func begin() -> Bool {
        guard state == .waiting else { return false }
        state = .shown
        return true
    }

    /// The prompt was answered, refused or closed.
    func finish() {
        state = .finished
    }

    /// Whether a prompt that is up must be closed. Before the show, the show is stopped instead; after
    /// the answer there is nothing to do.
    func cancel() -> Bool {
        switch state {
        case .waiting:
            state = .cancelledEarly
            return false
        case .shown:
            return true
        case .cancelledEarly, .finished:
            return false
        }
    }
}
