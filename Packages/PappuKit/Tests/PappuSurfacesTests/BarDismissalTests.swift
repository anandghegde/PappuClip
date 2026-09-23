import CoreGraphics
import PappuSelection
import PappuSurfaces
import Testing

private let bar = CGRect(x: 650, y: 360, width: 100, height: 36)

/// BAR-10: the bar goes away because something happened, never because time passed.
@Suite struct BarDismissalTests {

    @Test func aClickOutsideTheBarTakesItAway() {
        let reason = BarDismissal.reason(for: mouse(.down, at: CGPoint(x: 200, y: 200)), barFrame: bar)

        #expect(reason == .outsideClick)
    }

    @Test func aClickOnTheBarIsAButtonPressAndNotADismissal() {
        #expect(BarDismissal.reason(for: mouse(.down, at: CGPoint(x: 700, y: 370)), barFrame: bar) == nil)
    }

    @Test func aClickOnTheArrowIsStillOnTheBar() {
        // The arrow is inside the window frame, which is what the bar is hit-tested against.
        #expect(BarDismissal.reason(for: mouse(.down, at: CGPoint(x: 700, y: 393)), barFrame: bar) == nil)
    }

    @Test func aScrollAnywhereTakesTheBarAway() {
        #expect(BarDismissal.reason(for: mouse(.scroll, at: CGPoint(x: 700, y: 370)), barFrame: bar) == .scroll)
        #expect(BarDismissal.reason(for: mouse(.scroll, at: CGPoint(x: 10, y: 10)), barFrame: bar) == .scroll)
    }

    @Test func draggingAndLettingGoLeaveTheBarAlone() {
        #expect(BarDismissal.reason(for: mouse(.dragged, at: CGPoint(x: 10, y: 10)), barFrame: bar) == nil)
        #expect(BarDismissal.reason(for: mouse(.up, at: CGPoint(x: 10, y: 10)), barFrame: bar) == nil)
    }

    /// The requirement, read off the signature: there is no clock to pass in, so there is no timer to
    /// write. Every reason names an event.
    @Test func everyDismissalReasonIsAnEvent() {
        let reasons = Set(BarDismissalReason.allCases)

        #expect(reasons == [
            .outsideClick, .scroll, .ordinaryKey, .escape, .actionRun, .attemptRetired, .privacyState,
        ])
    }
}
