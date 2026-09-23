import Foundation
import PappuApp
import PappuCore
import PappuTestSupport
import Testing

/// ONB-1 from the window's side. `OnboardingState` decides which screen is owed and is tested on its
/// own; what is tested here is the part a window makes true — the buttons, and the closing that happens
/// without anything being pressed.
@Suite @MainActor struct OnboardingModelTests {
    @Test func aFirstRunShowsTheWelcome() {
        let model = OnboardingModel(store: OnboardingStore(storage: FakeSettingsStorage()))
        #expect(model.screen == .welcome)
        #expect(model.hasSomethingToShow)
    }

    /// The explanation is read once ever, and the system's prompt is what follows it: it is the only way
    /// into the Accessibility list, and it appears once per install for a process that is not trusted.
    @Test func pressingContinueRemembersTheExplanationAndAsksTheSystem() {
        let asked = Counter()
        let store = OnboardingStore(storage: FakeSettingsStorage())
        let model = OnboardingModel(store: store, requestGrant: { asked.increment() })

        model.welcomeRead()
        #expect(model.screen == .permission)
        #expect(asked.count == 1)
        #expect(store.state.hasBeenWelcomed)
    }

    @Test func aSecondLaunchWithoutTheGrantAsksForItRatherThanExplainingAgain() {
        let storage = FakeSettingsStorage()
        OnboardingModel(store: OnboardingStore(storage: storage)).welcomeRead()

        let afterRelaunch = OnboardingModel(store: OnboardingStore(storage: storage))
        #expect(afterRelaunch.screen == .permission)
    }

    /// The one behaviour a value type cannot express: the window asking for the permission goes away
    /// when the permission arrives, rather than leaving a Done button for something already done.
    @Test func theGrantArrivingWhileTheWindowIsOpenFinishesIt() {
        let store = OnboardingStore(storage: FakeSettingsStorage())
        let model = OnboardingModel(store: store)
        model.welcomeRead()
        let finished = Counter()
        model.onFinish = { finished.increment() }

        store.noteGrant(.working)
        #expect(model.screen == .none)
        #expect(finished.count == 1)
        #expect(!model.hasSomethingToShow)
    }

    /// ONB-4. Trusted and refused anyway: asking the system again would do nothing, because as far as
    /// the system is concerned it has already been asked and answered.
    @Test func aStaleGrantShowsTheRepairAndDoesNotAskTheSystemAgain() {
        let asked = Counter()
        let store = OnboardingStore(storage: FakeSettingsStorage(), grant: .stale)
        let model = OnboardingModel(store: store, requestGrant: { asked.increment() })

        model.welcomeRead()
        #expect(model.screen == .repair)
        #expect(asked.count == 0)
    }

    /// A reinstall over a grant that already works is still owed the sentence about what the app does,
    /// and pressing Continue on it finds there is nothing else to say.
    @Test func aFirstRunOverAWorkingGrantExplainsItselfAndThenCloses() {
        let store = OnboardingStore(storage: FakeSettingsStorage(), grant: .working)
        let model = OnboardingModel(store: store)
        let finished = Counter()
        model.onFinish = { finished.increment() }

        #expect(model.screen == .welcome)
        model.welcomeRead()
        #expect(model.screen == .none)
        #expect(finished.count == 1)
    }

    @Test func theDirectLinkOpensThePaneAndClaimsNothing() {
        let opened = Counter()
        let model = OnboardingModel(
            store: OnboardingStore(storage: FakeSettingsStorage()),
            openAccessibilitySettings: { opened.increment() }
        )
        model.openAccessibilityPane()
        #expect(opened.count == 1)
        #expect(model.screen == .welcome)
    }
}

/// Counts what a closure was asked to do, from the main actor the model runs on.
@MainActor private final class Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}
