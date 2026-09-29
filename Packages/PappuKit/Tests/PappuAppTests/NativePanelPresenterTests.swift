import Foundation
import PappuApp
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
}
