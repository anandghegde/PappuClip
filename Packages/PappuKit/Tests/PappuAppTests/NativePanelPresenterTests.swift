import Foundation
@testable import PappuApp
import PappuRuntime
import PappuSurfaces
import Testing

/// RUN-2e: a disabled Replace or Insert says why, in words the user can act on.
@Suite struct NativePanelPresenterTests {
    @Test func everyDestinationFailureHasAnExplanation() {
        for failure in DestinationFailure.allCases {
            #expect(!NativePanelPresenter.explanation(for: [failure]).isEmpty)
        }
        #expect(NativePanelPresenter.explanation(for: [.selectionMoved]) == PanelStrings.destinationSelectionChanged)
        #expect(NativePanelPresenter.explanation(for: [.windowChanged, .notFrontmost]) == PanelStrings.destinationMoved)
        #expect(NativePanelPresenter.explanation(for: [.notEditable]) == PanelStrings.destinationNotEditable)
        #expect(NativePanelPresenter.explanation(for: [.inputSinceSnapshot]) == PanelStrings.destinationInput)
        #expect(NativePanelPresenter.explanation(for: [.privacyRefused]) == PanelStrings.destinationPrivacy)
        #expect(NativePanelPresenter.explanation(for: []) == PanelStrings.destinationUnknown)
    }

    // MARK: A prompt call (JS-18)

    /// A cancel that reaches the main actor before the show stops the show.
    @MainActor @Test func aCancelBeforeTheShowStopsIt() {
        let call = PromptCall()
        #expect(!call.cancel())
        #expect(!call.begin())
        #expect(call.state == .cancelledEarly)
    }

    /// A cancel while the prompt is up closes it.
    @MainActor @Test func aCancelWhileShownClosesThePrompt() {
        let call = PromptCall()
        #expect(call.begin())
        #expect(call.cancel())
    }

    /// A cancel after the answer, or after a refusal, does nothing and keeps nothing: before this, it
    /// was remembered in a presenter-wide set that only a later show of the same invocation emptied.
    @MainActor @Test func aCancelAfterTheAnswerDoesNothing() {
        let answered = PromptCall()
        #expect(answered.begin())
        answered.finish()
        #expect(!answered.cancel())
        #expect(answered.state == .finished)
        #expect(!answered.begin(), "a finished call is never shown again")
    }
}
