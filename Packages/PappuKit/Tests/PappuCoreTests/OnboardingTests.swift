import Foundation
import PappuCore
import PappuTestSupport
import Synchronization
import Testing

/// ONB-1: the Accessibility grant as the app can actually observe it, and what each answer means for
/// whether the automatic path can work at all.
@Suite struct AccessibilityGrantTests {
    @Test func anUntrustedProcessIsUntrustedWhateverTheTapDid() {
        #expect(AccessibilityGrant(isTrusted: false, tapWasCreated: nil) == .notTrusted)
        #expect(AccessibilityGrant(isTrusted: false, tapWasCreated: false) == .notTrusted)
        // The tap cannot have been created without the grant, but the reading is taken from two calls
        // and nothing says they happened in the same instant.
        #expect(AccessibilityGrant(isTrusted: false, tapWasCreated: true) == .notTrusted)
    }

    @Test func trustedWithNothingTriedYetIsUntested() {
        #expect(AccessibilityGrant(isTrusted: true, tapWasCreated: nil) == .untested)
    }

    /// ONB-4. Trusted and refused anyway is the state a macOS upgrade leaves behind, and it is the one
    /// the user cannot diagnose from the System Settings tick, which looks right.
    @Test func trustedAndRefusedIsStaleRatherThanMissing() {
        #expect(AccessibilityGrant(isTrusted: true, tapWasCreated: false) == .stale)
        #expect(AccessibilityGrant(isTrusted: true, tapWasCreated: true) == .working)
    }

    /// A grant nobody has tested is allowed to be optimistic: the first attempt is what tests it, and
    /// refusing to try would mean never finding out.
    @Test func onlyAWorkingOrUntestedGrantLetsTheAutomaticPathRun() {
        let permitted = AccessibilityGrant.allCases.filter(\.permitsTheAutomaticPath)
        #expect(Set(permitted) == [.working, .untested])
    }
}

/// Which screen onboarding shows, as a function of the two things it knows (ONB-1, ONB-4).
@Suite struct OnboardingStateTests {
    @Test func aFreshInstallIsWelcomedFirstWhateverTheGrantSays() {
        for grant in AccessibilityGrant.allCases {
            #expect(OnboardingState(hasBeenWelcomed: false, grant: grant).screen == .welcome)
        }
    }

    @Test func aWelcomedUserWithoutTheGrantIsAskedForIt() {
        #expect(OnboardingState(hasBeenWelcomed: true, grant: .notTrusted).screen == .permission)
    }

    @Test func aStaleGrantGetsItsOwnScreenRatherThanTheAskAgain() {
        #expect(OnboardingState(hasBeenWelcomed: true, grant: .stale).screen == .repair)
    }

    /// ONB-1 asks for the grant to be detected live and the window to close itself. `.none` is what the
    /// window watches for; there is no separate "done" flag to get out of step with the grant.
    @Test func thereIsNothingToShowOnceTheGrantWorks() {
        #expect(OnboardingState(hasBeenWelcomed: true, grant: .working).screen == .none)
        #expect(OnboardingState(hasBeenWelcomed: true, grant: .untested).screen == .none)
        #expect(OnboardingState(hasBeenWelcomed: true, grant: .working).closesItself)
        #expect(!OnboardingState(hasBeenWelcomed: false).closesItself)
    }
}

@Suite struct OnboardingStoreTests {
    @Test func aFreshInstallHasNotBeenWelcomedAndStoresNothing() {
        let storage = FakeSettingsStorage()
        let store = OnboardingStore(storage: storage)
        #expect(store.state.screen == .welcome)
        #expect(storage.keys.isEmpty)
    }

    @Test func theWelcomeIsOnlyShownOnce() {
        let storage = FakeSettingsStorage()
        OnboardingStore(storage: storage).finishWelcome()

        let afterRelaunch = OnboardingStore(storage: storage, grant: .working)
        #expect(afterRelaunch.state.screen == .none)
    }

    /// The grant is read from the system at launch, never from storage: the trust database can change
    /// while the app is not running, and a remembered `working` would send a broken app past onboarding.
    @Test func theGrantIsNeverWrittenDown() {
        let storage = FakeSettingsStorage()
        let store = OnboardingStore(storage: storage, grant: .working)
        store.finishWelcome()
        store.noteGrant(.stale)
        #expect(storage.keys == [OnboardingStore.storageKey])
        #expect(OnboardingStore(storage: storage).grant == .notTrusted)
    }

    /// ONB-1's live detection, from the watcher's side: the window is told, and closes itself.
    @Test func theGrantArrivingIsAnnounced() {
        let heard = Mutex<[OnboardingState.Screen]>([])
        let store = OnboardingStore(storage: FakeSettingsStorage())
        store.onChange { state in heard.withLock { $0.append(state.screen) } }

        store.finishWelcome()
        store.noteGrant(.working)
        #expect(heard.withLock { $0 } == [.permission, .none])
    }

    /// A monitor that re-reads on every distributed notification would otherwise redraw the world each
    /// time the user touched an unrelated row in System Settings.
    @Test func agrantThatHasNotChangedIsNotAnnounced() {
        let heard = Mutex<Int>(0)
        let store = OnboardingStore(storage: FakeSettingsStorage(), grant: .working)
        store.onChange { _ in heard.withLock { $0 += 1 } }

        store.noteGrant(.working)
        store.noteGrant(.working)
        #expect(heard.withLock { $0 } == 0)

        store.noteGrant(.stale)
        store.noteGrant(.stale)
        #expect(heard.withLock { $0 } == 1)
    }

    @Test func finishingAWelcomeTwiceAnnouncesOnce() {
        let heard = Mutex<Int>(0)
        let store = OnboardingStore(storage: FakeSettingsStorage())
        store.onChange { _ in heard.withLock { $0 += 1 } }
        store.finishWelcome()
        store.finishWelcome()
        #expect(heard.withLock { $0 } == 1)
    }
}
