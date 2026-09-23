import CoreGraphics
import Foundation
import PappuSelection
import PappuTestSupport
import Testing

private func event(
    _ kind: PointerEvent.Kind,
    x: Double = 100,
    y: Double = 100,
    ms: UInt64,
    clicks: Int = 1,
    _ modifiers: PointerEvent.Modifiers = [],
    window: Int = 7
) -> PointerEvent {
    PointerEvent(
        kind: kind, location: CGPoint(x: x, y: y), modifiers: modifiers, clickCount: clicks,
        timestampNs: ms * 1_000_000, windowNumber: window
    )
}

private func gestures(_ events: [PointerEvent]) -> [Gesture] {
    GestureRecording(name: "test", events: events, expected: []).replay().map(\.gesture)
}

private func click(ms: UInt64, clicks: Int = 1, _ modifiers: PointerEvent.Modifiers = [], window: Int = 7) -> [PointerEvent] {
    [event(.down, ms: ms, clicks: clicks, modifiers, window: window), event(.up, ms: ms + 60, clicks: clicks, modifiers, window: window)]
}

@Suite struct GestureRecognizerTests {
    // MARK: ACT-1, the selecting gestures

    @Test func aDragBeyondTheSlopIsADragSelectWithItsDirection() {
        let downwards = [event(.down, ms: 0), event(.dragged, x: 180, y: 140, ms: 80), event(.up, x: 260, y: 160, ms: 300)]
        #expect(gestures(downwards) == [.dragSelect(direction: .downwards)])

        let upwards = [event(.down, ms: 0), event(.dragged, x: 60, y: 70, ms: 80), event(.up, x: 40, y: 40, ms: 300)]
        #expect(gestures(upwards) == [.dragSelect(direction: .upwards)])
    }

    @Test func doubleAndTripleClicksReportTheirCount() {
        #expect(gestures(click(ms: 0) + click(ms: 150, clicks: 2)) == [.multiClick(count: 2, dragged: false)])
        #expect(gestures(click(ms: 0) + click(ms: 150, clicks: 2) + click(ms: 300, clicks: 3)) == [
            .multiClick(count: 2, dragged: false), .multiClick(count: 3, dragged: false),
        ])
    }

    @Test func aDoubleClickAndDragIsOneMultiClick() {
        let events = click(ms: 0) + [
            event(.down, ms: 150, clicks: 2),
            event(.dragged, x: 220, ms: 400, clicks: 2),
            event(.up, x: 300, ms: 900, clicks: 2),
        ]
        #expect(gestures(events) == [.multiClick(count: 2, dragged: true)])
    }

    @Test func aShiftClickExtendsFromAnEarlierPressInTheSameWindow() {
        #expect(gestures(click(ms: 0) + click(ms: 2_000, .shift)) == [.shiftClick])
        // A word picked by double-click, then extended.
        #expect(gestures(click(ms: 0) + click(ms: 150, clicks: 2) + click(ms: 2_000, .shift)) == [
            .multiClick(count: 2, dragged: false), .shiftClick,
        ])
    }

    @Test func aShiftClickWithNoAnchorInThatWindowIsNotACandidate() {
        #expect(gestures(click(ms: 0, .shift)) == [])
        #expect(gestures(click(ms: 0, window: 7) + click(ms: 2_000, .shift, window: 8)) == [])
    }

    @Test func movementInsideTheSlopIsStillAClick() {
        let events = [event(.down, ms: 0), event(.dragged, x: 102, y: 101, ms: 30), event(.up, x: 102, y: 101, ms: 90)]
        #expect(gestures(events) == [])
    }

    // MARK: ACT-2, nothing before release

    @Test func nothingIsReportedUntilTheButtonIsReleased() {
        var recognizer = GestureRecognizer()
        let held = click(ms: 0) + [
            event(.down, ms: 150, clicks: 2),
            event(.dragged, x: 220, ms: 400, clicks: 2),
            // Held still for far longer than a long press.
            event(.dragged, x: 221, ms: 2_400, clicks: 2),
        ]
        for event in held {
            if case .candidate = recognizer.handle(event) { Issue.record("reported before release: \(event)") }
        }
        guard case .candidate(let candidate) = recognizer.handle(event(.up, x: 221, ms: 2_500, clicks: 2)) else {
            Issue.record("nothing reported at release")
            return
        }
        #expect(candidate.gesture == .multiClick(count: 2, dragged: true))
        #expect(candidate.timestampNs == 2_500 * 1_000_000)
    }

    @Test func aDoubleClickAndHoldNeverArmsTheLongPress() {
        var recognizer = GestureRecognizer()
        click(ms: 0).forEach { _ = recognizer.handle($0) }
        #expect(recognizer.handle(event(.down, ms: 150, clicks: 2)) == nil)
    }

    // MARK: ACT-3, long press

    @Test func aLongPressIsReportedAtHalfASecondWhileTheButtonIsDown() {
        var recognizer = GestureRecognizer()
        guard case .armLongPress(let press, let deadlineNs) = recognizer.handle(event(.down, x: 40, y: 50, ms: 1_000)) else {
            Issue.record("a plain press did not arm the timer")
            return
        }
        #expect(deadlineNs == 1_500 * 1_000_000)

        guard case .candidate(let candidate) = recognizer.longPressTimerFired(press) else {
            Issue.record("the timer did not produce a candidate")
            return
        }
        #expect(candidate.gesture == .longPress)
        #expect(candidate.pressLocation == CGPoint(x: 40, y: 50))
        #expect(candidate.timestampNs == deadlineNs)
        // The release that follows is not a second gesture.
        #expect(recognizer.handle(event(.up, x: 40, y: 50, ms: 1_900)) == nil)
    }

    @Test func movementOrReleaseCancelsTheLongPress() {
        var moved = GestureRecognizer()
        guard case .armLongPress(let press, _) = moved.handle(event(.down, ms: 0)) else { return }
        #expect(moved.handle(event(.dragged, x: 130, ms: 200)) == .disarmLongPress)
        #expect(moved.longPressTimerFired(press) == nil)

        var released = GestureRecognizer()
        guard case .armLongPress(let quick, _) = released.handle(event(.down, ms: 0)) else { return }
        #expect(released.handle(event(.up, ms: 80)) == .disarmLongPress)
        #expect(released.longPressTimerFired(quick) == nil)
    }

    @Test func aTimerFromAnEarlierPressIsIgnored() {
        var recognizer = GestureRecognizer()
        guard case .armLongPress(let first, _) = recognizer.handle(event(.down, ms: 0)) else { return }
        _ = recognizer.handle(event(.up, ms: 80))
        _ = recognizer.handle(event(.down, ms: 5_000))
        #expect(recognizer.longPressTimerFired(first) == nil)
    }

    @Test func aDragAfterALongPressIsStillASelection() {
        let events = [event(.down, ms: 0), event(.dragged, x: 200, y: 130, ms: 900), event(.up, x: 240, y: 130, ms: 1_200)]
        #expect(gestures(events) == [.longPress, .dragSelect(direction: .downwards)])
    }

    // MARK: ACT-7, ⌘ suppresses

    @Test func commandAtAnyPointInTheGestureSuppressesIt() {
        let atPress = [event(.down, ms: 0, .command), event(.dragged, x: 200, ms: 100), event(.up, x: 200, ms: 200)]
        let midDrag = [event(.down, ms: 0), event(.dragged, x: 200, ms: 100, .command), event(.up, x: 220, ms: 200)]
        let atRelease = [event(.down, ms: 0), event(.dragged, x: 200, ms: 100), event(.up, x: 200, ms: 200, .command)]
        for events in [atPress, midDrag, atRelease] {
            #expect(gestures(events) == [.suppressed])
        }
    }

    @Test func commandOnTheFirstClickSuppressesTheDoubleClick() {
        #expect(gestures(click(ms: 0, .command) + click(ms: 150, clicks: 2)) == [.suppressed])
        // The next click sequence starts clean.
        #expect(gestures(click(ms: 0, .command) + click(ms: 150, clicks: 2) + click(ms: 3_000) + click(ms: 3_150, clicks: 2)) == [
            .suppressed, .multiClick(count: 2, dragged: false),
        ])
    }

    @Test func commandSuppressesALongPress() {
        #expect(gestures([event(.down, ms: 0, .command), event(.up, ms: 900, .command)]) == [.suppressed])
    }

    @Test func aCommandClickThatSelectsNothingReportsNothing() {
        #expect(gestures(click(ms: 0, .command)) == [])
    }

    // MARK: Robustness

    @Test func aLostMouseUpDoesNotWedgeTheMachine() {
        let events = [
            event(.down, ms: 0), event(.dragged, x: 300, ms: 100),
            // The tap was disabled here and the release never arrived (ACT-15).
            event(.down, x: 400, y: 400, ms: 9_000), event(.dragged, x: 480, y: 380, ms: 9_100), event(.up, x: 500, y: 370, ms: 9_200),
        ]
        #expect(gestures(events) == [.dragSelect(direction: .upwards)])
    }

    @Test func resetDropsThePressInProgress() {
        var recognizer = GestureRecognizer()
        _ = recognizer.handle(event(.down, ms: 0))
        #expect(recognizer.reset() == .disarmLongPress)
        #expect(recognizer.handle(event(.dragged, x: 300, ms: 100)) == nil)
        #expect(recognizer.handle(event(.up, x: 300, ms: 200)) == nil)
        #expect(recognizer.reset() == nil)
    }

    @Test func scrollingAndStrayEventsAreIgnored() {
        let events = [
            event(.scroll, ms: 0, clicks: 0), event(.dragged, x: 300, ms: 10), event(.up, x: 300, ms: 20),
            event(.down, ms: 1_000), event(.scroll, ms: 1_050, clicks: 0), event(.up, ms: 1_100),
        ]
        #expect(gestures(events) == [])
    }
}
