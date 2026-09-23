import CoreGraphics
import Foundation
import PappuCore
import PappuSelection
import PappuSurfaces
import Testing

private let line = CGRect(x: 600, y: 400, width: 200, height: 20)
private func selection() -> AttemptPresentation { presentation(bounds: line, pointer: CGPoint(x: 700, y: 420)) }

/// The bar end to end, against fakes: what appears, what the keyboard does to it, what a press turns
/// into, and every way it goes away.
@MainActor
@Suite struct BarControllerTests {

    // MARK: Appearing (ACT-5, BAR-14)

    @Test func aPermittedAttemptPutsABarOnTheScreen() async throws {
        let bar = Bar()
        await bar.show(selection())

        #expect(bar.controller.isShowing)
        #expect(bar.window.isVisible)
        let placement = try #require(bar.window.lastPlacement)
        #expect(placement.frame == CGRect(x: 650, y: 360, width: 100, height: 30))
        #expect(bar.controller.lastRefusal == nil)
    }

    @Test func theBarSaysItIsThere() async {
        let bar = Bar()
        await bar.show(selection())

        #expect(bar.window.announcements.contains(BarStrings.barAppeared))
    }

    @Test func aPermitWithNoBudgetLeftMeansNoBarAtAll() async {
        let bar = Bar()
        await bar.show(selection(), grant: grant(remaining: .zero))

        #expect(!bar.controller.isShowing)
        #expect(!bar.window.isVisible)
        #expect(bar.controller.lastRefusal == .outOfBudget)
    }

    @Test func nothingToShowMeansNoBar() async {
        let bar = Bar(content: BarContent(items: []))
        await bar.show(selection())

        #expect(!bar.controller.isShowing)
        #expect(bar.controller.lastRefusal == .noActions)
    }

    @Test func onlyTheButtonsThatFitAreHandedToTheWindow() async throws {
        let narrow = BarScreen(
            id: 9,
            frame: CGRect(x: 0, y: 0, width: 60, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 60, height: 400)
        )
        let bar = Bar(screens: [narrow])
        await bar.show(presentation(bounds: CGRect(x: 10, y: 200, width: 40, height: 20)))

        let shown = try #require(bar.window.calls.compactMap { call -> [String]? in
            if case .shown(let items, _, _) = call { items } else { nil }
        }.first)
        #expect(shown == ["copy"])
    }

    @Test func theWindowIsToldWhichDisplayTheBarLandedOn() async throws {
        let bar = Bar(screens: [mainScreen, rightScreen])
        await bar.show(presentation(bounds: CGRect(x: 1700, y: 300, width: 100, height: 20)))

        #expect(try #require(bar.window.lastPlacement).screen == rightScreen.id)
    }

    @Test func reduceTransparencyReachesTheWindow() async throws {
        let bar = Bar(appearance: SystemAppearanceSettings(reduceTransparency: true))
        await bar.show(selection())

        let background = try #require(bar.window.calls.compactMap { call -> BarBackgroundStyle? in
            if case .shown(_, _, let background) = call { background } else { nil }
        }.first)
        #expect(background == .solid)
    }

    // MARK: The key tap, held only while a bar is up (ACT-19)

    @Test func theKeyTapIsTakenWhenTheBarAppearsAndGivenBackWhenItGoes() async {
        let bar = Bar()
        #expect(bar.keys.leases == 0)

        await bar.show(selection())
        #expect(bar.keys.leases == 1)
        #expect(bar.keys.isHeld)

        bar.controller.dismiss(.escape)
        #expect(!bar.keys.isHeld)
        #expect(bar.keys.stops == 1)
    }

    @Test func aKeyPressedWithNoBarUpIsNotOurs() {
        let bar = Bar()

        #expect(bar.keys.press(key(Keys.right)) == .pass)
    }

    @Test func aBarWithNoKeyTapStillAppears() async {
        // macOS refuses the tap when the Accessibility grant is missing. The bar is still the point.
        let bar = Bar(keys: RecordingKeys(refuses: true))
        await bar.show(selection())

        #expect(bar.controller.isShowing)
        #expect(!bar.keys.isHeld)
    }

    // MARK: Compact keyboard mode (BAR-9a, ACT-6a)

    @Test func anArrowKeyMovesTheHighlightAndIsConsumed() async {
        let bar = Bar()
        await bar.show(selection())

        #expect(bar.keys.press(key(Keys.right)) == .consume)
        await settle(until: bar.window.highlights.last == 0)
        #expect(bar.controller.highlighted == 0)
        #expect(bar.window.highlights.last == 0)
    }

    @Test func theHighlightedButtonsNameIsSaidAsItMoves() async {
        let bar = Bar()
        await bar.show(selection())
        bar.keys.press(key(Keys.right))
        bar.keys.press(key(Keys.right))
        await settle(until: bar.window.announcements.last == "Search")

        #expect(bar.window.announcements.last == "Search")
    }

    @Test func aShortcutBarStartsInKeyboardModeWithTheFirstButtonHighlighted() async {
        let bar = Bar()
        await bar.show(presentation(bounds: line, route: .hotkey), grant: grant(route: .hotkey))

        #expect(bar.controller.highlighted == 0)
        #expect(bar.window.highlights == [0])
    }

    @Test func anAutomaticBarLeavesTheArrowKeysAloneUntilOneIsPressed() async {
        let bar = Bar()
        await bar.show(selection())

        #expect(bar.controller.highlighted == nil)
        #expect(bar.window.highlights == [nil])
    }

    @Test func returnInvokesTheHighlightedButtonThroughTheInvoker() async {
        let bar = Bar()
        await bar.show(selection())
        bar.keys.press(key(Keys.right))
        #expect(bar.keys.press(key(Keys.enter)) == .consume)
        await settle(until: !bar.invoker.clicks.isEmpty)

        #expect(bar.invoker.clicks.map(\.item.rawValue) == ["copy"])
        #expect(bar.invoker.clicks.first?.source == .keyboard)
    }

    @Test func aModifiedArrowKeyBelongsToTheAppAndTakesTheBarAway() async {
        let bar = Bar()
        await bar.show(selection())

        #expect(bar.keys.press(key(Keys.left, .shift)) == .pass)
        await settle(until: !bar.controller.isShowing)
        #expect(!bar.controller.isShowing)
        #expect(bar.controller.lastDismissal == .ordinaryKey)
    }

    @Test func escapeTakesTheBarAwayAndGoesNoFurther() async {
        let bar = Bar()
        await bar.show(selection())

        #expect(bar.keys.press(key(Keys.escape)) == .consume)
        await settle(until: !bar.controller.isShowing)
        #expect(!bar.controller.isShowing)
        #expect(bar.controller.lastDismissal == .escape)
    }

    @Test func aSecondKeyArrivingBehindADismissalGoesToTheApp() async {
        let bar = Bar()
        await bar.show(selection())

        // Both arrive on the tap's thread before the main actor has hidden anything.
        #expect(bar.keys.press(key(Keys.escape)) == .consume)
        #expect(bar.keys.press(key(Keys.escape)) == .pass)
        await settle(until: !bar.controller.isShowing)
        #expect(!bar.controller.isShowing)
    }

    // MARK: Pressing a button (BAR-11)

    @Test func aClickInvokesTheActionWithTheModifiersThatWereHeld() async {
        let bar = Bar()
        await bar.show(selection())
        bar.window.press("search", modifiers: [.option, .shift])
        await settle(until: !bar.invoker.clicks.isEmpty)

        #expect(bar.invoker.clicks.count == 1)
        #expect(bar.invoker.clicks.first?.item == BarItemID("search"))
        #expect(bar.invoker.clicks.first?.modifiers == [.option, .shift])
        #expect(bar.invoker.clicks.first?.source == .mouse)
    }

    @Test func aDisabledButtonDoesNothing() async {
        let bar = Bar(content: BarContent(items: [item("replace", enabled: false, why: "no")]))
        await bar.show(selection())
        bar.window.press("replace")
        await settle()

        #expect(bar.invoker.clicks.isEmpty)
        #expect(bar.controller.isShowing)
    }

    @Test func aPressWhileAnActionIsRunningTakesItBack() async {
        let bar = Bar()
        await bar.show(selection())
        bar.window.press("copy")
        await settle(until: !bar.invoker.clicks.isEmpty)
        #expect(bar.controller.feedbackState == .running(cancellable: true))

        bar.window.press("search")
        await settle(until: bar.invoker.cancellations == 1)
        #expect(bar.invoker.cancellations == 1)
        #expect(bar.invoker.clicks.count == 1)
        #expect(bar.controller.feedbackState == .idle)
    }

    @Test func everyFeedbackStateIsDrawnAndSaid() async {
        let bar = Bar()
        await bar.show(selection())
        bar.controller.report(.copied)

        #expect(bar.window.calls.contains(.presented(.copied, .none)))
        #expect(bar.window.announcements.last == BarStrings.feedbackCopied)
    }

    @Test func aFailureShakesUnlessReduceMotionIsOn() async {
        let moving = Bar()
        await moving.show(selection())
        moving.controller.report(.failed)
        #expect(moving.window.calls.contains(.presented(.failed, .shake)))

        let still = Bar(appearance: SystemAppearanceSettings(reduceMotion: true))
        await still.show(selection())
        still.controller.report(.failed)
        #expect(still.window.calls.contains(.presented(.failed, .none)))
    }

    // MARK: Going away (BAR-10)

    @Test func aClickOffTheBarReachesTheControllerAndHidesTheWindow() async {
        let bar = Bar()
        await bar.show(selection())
        bar.controller.pointer(mouse(.down, at: CGPoint(x: 100, y: 100)))
        await settle(until: !bar.controller.isShowing)

        #expect(!bar.controller.isShowing)
        #expect(bar.controller.lastDismissal == .outsideClick)
        #expect(!bar.window.isVisible)
    }

    @Test func aClickOnTheBarIsNotADismissal() async {
        let bar = Bar()
        await bar.show(selection())
        bar.controller.pointer(mouse(.down, at: CGPoint(x: 700, y: 370)))
        await settle()

        #expect(bar.controller.isShowing)
    }

    @Test func aScrollTakesTheBarAway() async {
        let bar = Bar()
        await bar.show(selection())
        bar.controller.pointer(mouse(.scroll, at: CGPoint(x: 700, y: 370)))
        await settle(until: !bar.controller.isShowing)

        #expect(bar.controller.lastDismissal == .scroll)
    }

    @Test func anAttemptThatIsNoLongerCurrentTakesItsBarAway() async {
        let bar = Bar()
        await bar.show(selection(), grant: grant(7))
        bar.controller.invalidate(AttemptID(rawValue: 8))
        await settle()
        #expect(bar.controller.isShowing)

        bar.controller.invalidate(AttemptID(rawValue: 7))
        await settle(until: !bar.controller.isShowing)
        #expect(!bar.controller.isShowing)
        #expect(bar.controller.lastDismissal == .attemptRetired)
    }

    @Test func pauseOrASecureFieldTakesTheBarAway() async {
        let bar = Bar()
        await bar.show(selection())
        bar.controller.privacyStateChanged()
        await settle(until: !bar.controller.isShowing)

        #expect(bar.controller.lastDismissal == .privacyState)
    }

    @Test func aDismissedBarForgetsItsKeyboardMode() async {
        let bar = Bar()
        await bar.show(selection())
        bar.keys.press(key(Keys.right))
        await settle(until: bar.controller.highlighted == 0)
        bar.controller.dismiss(.escape)

        #expect(bar.controller.highlighted == nil)
        #expect(bar.controller.feedbackState == .idle)
    }

    @Test func showingASecondBarReplacesTheFirst() async {
        let bar = Bar()
        await bar.show(selection(), grant: grant(1))
        await bar.show(selection(), grant: grant(2))

        #expect(bar.controller.isShowing)
        #expect(bar.keys.leases == 2)
    }
}

/// Lets whatever a key or a press started finish.
///
/// Two hops have to happen and neither is awaited by the thing that started it. The tap handlers hand
/// their work to the main actor and return at once, because they must (ACT-15); and a press hands the
/// invocation to an unstructured `Task`, because the bar hears about an action's progress through
/// `report(_:)` rather than by waiting for it. A fixed number of `Task.yield()`s will not cover that —
/// the work leaves the main actor and comes back, and how many hops that takes is the scheduler's
/// business, not the test's. So `until` names the thing the test is actually waiting for. With nothing
/// named it runs the whole bound, which is what a test asserting that *nothing* happened wants anyway.
@MainActor
private func settle(until reached: @autoclosure @MainActor () -> Bool = false) async {
    for round in 0..<200 {
        await Task.yield()
        if reached() { return }
        // Yielding hands the main actor back, but a task that went out to the cooperative pool needs a
        // thread there to come back from, and no number of yields makes one appear.
        if round.isMultiple(of: 20) { try? await Task.sleep(for: .milliseconds(1)) }
    }
}
