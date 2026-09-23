import PappuCore
import PappuSelection
import PappuSurfaces
import Testing

private func mode(_ count: Int = 3, route: ActivationRoute = .automatic) -> BarKeyboardMode {
    BarKeyboardMode(itemCount: count, route: route)
}

/// One key into a fresh bar, which is what most of these ask about.
private func pressing(_ key: BarKey, count: Int = 3) -> BarKeyOutcome {
    var keyboard = mode(count)
    return keyboard.press(key)
}

/// BAR-9a's compact keyboard mode and ACT-6a: which keys the bar owns, and which go straight past it
/// to the app underneath.
@Suite struct BarKeyboardTests {

    // MARK: Which key is which

    @Test func aBareArrowIsTheBarsAndAModifiedOneIsNot() {
        #expect(BarKey(key(Keys.left)) == .left)
        #expect(BarKey(key(Keys.left, .shift)) == .other)
        #expect(BarKey(key(Keys.right, .command)) == .other)
        #expect(BarKey(key(Keys.escape, .option)) == .other)
    }

    @Test func returnOnEitherKeypadIsReturn() {
        #expect(BarKey(key(36)) == .enter)
        #expect(BarKey(key(76)) == .enter)
    }

    // MARK: What the bar takes (ACT-19)

    @Test func theBarConsumesOnlyItsOwnKeys() {
        var keyboard = mode()

        #expect(keyboard.press(.right).disposition == .consume)
        #expect(keyboard.press(.left).disposition == .consume)
        #expect(keyboard.press(.enter).disposition == .consume)
        #expect(pressing(.escape).disposition == .consume)
        #expect(pressing(.other).disposition == .pass)
        #expect(pressing(.up).disposition == .pass)
        #expect(pressing(.down).disposition == .pass)
    }

    @Test func anOrdinaryKeyDismissesTheBarAndGoesOnToTheApp() {
        var keyboard = mode()
        let outcome = keyboard.press(.other)

        #expect(outcome == .dismissedAndPassedOn)
        #expect(outcome.dismisses)
        #expect(outcome.disposition == .pass)
    }

    @Test func escapeDismissesTheBarAndGoesNoFurther() {
        var keyboard = mode()
        let outcome = keyboard.press(.escape)

        #expect(outcome == .dismissed)
        #expect(outcome.disposition == .consume)
    }

    // MARK: Moving about

    @Test func theFirstRightArrowTakesTheFirstButton() {
        var keyboard = mode()

        #expect(keyboard.press(.right) == .moved(to: 0))
        #expect(keyboard.highlighted == 0)
        #expect(keyboard.isActive)
    }

    @Test func theFirstLeftArrowTakesTheLastButton() {
        var keyboard = mode()

        #expect(keyboard.press(.left) == .moved(to: 2))
    }

    @Test func theHighlightClampsRatherThanWrapping() {
        var keyboard = mode()
        _ = keyboard.press(.right)

        #expect(keyboard.press(.left) == .moved(to: 0))
        #expect(keyboard.press(.left) == .moved(to: 0))

        for _ in 0..<5 { _ = keyboard.press(.right) }
        #expect(keyboard.highlighted == 2)
    }

    @Test func returnRunsTheHighlightedButton() {
        var keyboard = mode()
        _ = keyboard.press(.right)
        _ = keyboard.press(.right)

        #expect(keyboard.press(.enter) == .run(index: 1))
    }

    @Test func returnWithNothingHighlightedBelongsToTheApp() {
        var keyboard = mode()
        let outcome = keyboard.press(.enter)

        #expect(outcome == .dismissedAndPassedOn)
        #expect(outcome.disposition == .pass)
    }

    // MARK: The bar is not in keyboard mode until it is asked

    @Test func aBarThatAppearedByItselfDoesNotHoldTheArrowKeysUntilOneIsPressed() {
        let keyboard = mode(3, route: .automatic)

        #expect(keyboard.highlighted == nil)
        #expect(!keyboard.isActive)
    }

    @Test func theShortcutOpensCompactKeyboardMode() {
        for route in ActivationRoute.allCases where route.isDeliberate {
            #expect(mode(3, route: route).highlighted == 0, "\(route)")
        }
    }

    @Test func anEmptyBarHasNoKeyboardModeToOpen() {
        #expect(mode(0, route: .hotkey).highlighted == nil)
        #expect(pressing(.right, count: 0) == .dismissedAndPassedOn)
        #expect(pressing(.escape, count: 0) == .dismissed)
    }

    // MARK: Up and down are still the app's, until folders exist (BAR-9b, M4)

    @Test func upAndDownAreOrdinaryKeysForNow() {
        #expect(pressing(.up) == .dismissedAndPassedOn)
        #expect(pressing(.down) == .dismissedAndPassedOn)
    }
}
