import PappuSurfaces
import Testing

private func resolve(
    dark: Bool = false,
    motion: Bool = false,
    transparency: Bool = false,
    contrast: Bool = false,
    preference: BarColorPreference = .system
) -> BarAppearance {
    BarAppearance.resolve(
        SystemAppearanceSettings(
            isDark: dark,
            reduceMotion: motion,
            reduceTransparency: transparency,
            increaseContrast: contrast
        ),
        preference: preference
    )
}

/// BAR-8a and BAR-14: the bar follows the system, and the three accessibility settings that change how
/// it is drawn are honoured rather than approximated.
@Suite struct BarAppearanceTests {

    @Test func theBarFollowsTheSystemColourMode() {
        #expect(resolve(dark: false).colorMode == .light)
        #expect(resolve(dark: true).colorMode == .dark)
    }

    @Test func aPinnedColourModeBeatsTheSystem() {
        #expect(resolve(dark: true, preference: .light).colorMode == .light)
        #expect(resolve(dark: false, preference: .dark).colorMode == .dark)
    }

    @Test func reduceTransparencyTakesTheVibrancyAway() {
        #expect(resolve().background == .vibrancy)
        #expect(resolve(transparency: true).background == .solid)
    }

    @Test func reduceMotionTakesTheMovementAway() {
        #expect(resolve().motion == .animated)
        #expect(resolve(motion: true).motion == .still)
    }

    @Test func increaseContrastDrawsABorderASolidBackgroundAndAPlainHighlight() {
        let appearance = resolve(contrast: true)

        #expect(appearance.border == .contrast)
        #expect(appearance.background == .solid)
        #expect(appearance.highlight == .contrast)
    }

    @Test func theOrdinaryBarHasAnAccentHighlightAndNoBorder() {
        let appearance = resolve()

        #expect(appearance.highlight == .accent)
        #expect(appearance.border == .none)
    }
}

/// BAR-12a: what the bar says while an action runs, and afterwards.
@Suite struct BarFeedbackTests {

    @Test func everyStateButIdleSaysSomething() {
        #expect(BarFeedbackState.idle.announcement == nil)
        for state: BarFeedbackState in [.running(cancellable: true), .copied, .succeeded, .failed] {
            #expect(state.announcement?.isEmpty == false, "\(state)")
        }
    }

    @Test func aStateChangedToItselfIsNotAnnouncedTwice() {
        var feedback = BarFeedback()

        #expect(feedback.change(to: .copied) != nil)
        #expect(feedback.change(to: .copied) == nil)
        #expect(feedback.change(to: .succeeded) != nil)
    }

    @Test func resettingGoesBackToIdleAndSaysNothing() {
        var feedback = BarFeedback()
        feedback.change(to: .running(cancellable: true))
        feedback.reset()

        #expect(feedback.state == .idle)
    }

    @Test func onlyARunningActionCanBeTakenBack() {
        #expect(BarFeedbackState.running(cancellable: true).isCancellable)
        #expect(!BarFeedbackState.running(cancellable: false).isCancellable)
        #expect(!BarFeedbackState.succeeded.isCancellable)
    }

    @Test func reduceMotionStopsTheShakeAndLeavesTheSpinner() {
        let still = BarAppearance.resolve(SystemAppearanceSettings(reduceMotion: true), preference: .system)
        let moving = BarAppearance.resolve(SystemAppearanceSettings(), preference: .system)

        #expect(BarFeedbackState.failed.motion(under: moving) == .shake)
        #expect(BarFeedbackState.failed.motion(under: still) == .none)
        #expect(BarFeedbackState.running(cancellable: true).motion(under: still) == .spinner)
    }

    @Test func aFinishedActionDoesNotMove() {
        let moving = BarAppearance.resolve(SystemAppearanceSettings(), preference: .system)

        #expect(BarFeedbackState.copied.motion(under: moving) == .none)
        #expect(BarFeedbackState.succeeded.motion(under: moving) == .none)
        #expect(BarFeedbackState.idle.motion(under: moving) == .none)
    }
}
