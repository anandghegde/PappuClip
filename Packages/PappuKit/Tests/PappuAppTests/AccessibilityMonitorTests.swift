import Foundation
import PappuApp
import PappuCore
import PappuTestSupport
import Synchronization
import Testing

/// ONB-1's third part: the grant as the app watches it, from the two facts that make it up.
///
/// `AccessibilityGrantTests` covers what a pair of facts means. This covers where the pair comes from —
/// a trust read that can change under the app, a tap answer that only exists once something has tried —
/// and the one thing that has to be *unlearned*: a refusal recorded against a signature the user has
/// since re-granted.
@Suite struct AccessibilityMonitorTests {
    private struct Scene {
        let store: OnboardingStore
        let watcher: FakeTrustWatcher
        let monitor: AccessibilityMonitor
        let trust: FakeTrust
        let announced: RecordingOnboarding

        static func make(trusted: Bool = false, welcomed: Bool = true) -> Scene {
            let store = OnboardingStore(storage: FakeSettingsStorage())
            if welcomed { store.finishWelcome() }
            let watcher = FakeTrustWatcher()
            let trust = FakeTrust(trusted)
            let announced = RecordingOnboarding()
            store.onChange { announced.note($0) }
            return Scene(
                store: store,
                watcher: watcher,
                monitor: AccessibilityMonitor(store: store, watcher: watcher, isTrusted: trust.reader),
                trust: trust,
                announced: announced
            )
        }
    }

    @Test func theGrantIsReadAtStartWithoutWaitingForANotice() {
        let scene = Scene.make(trusted: true)
        scene.monitor.start()

        #expect(scene.store.grant == .untested)
        #expect(scene.watcher.starts == 1)
    }

    /// The notification says "look again", never "you are trusted now", so a tick made in System Settings
    /// arrives as a re-read.
    @Test func aTickMadeWhileTheAppIsRunningIsNoticedWithoutAnybodyAsking() {
        let scene = Scene.make()
        scene.monitor.start()
        #expect(scene.store.grant == .notTrusted)

        scene.trust.set(true)
        scene.watcher.fire()

        #expect(scene.store.grant == .untested)
        #expect(scene.store.state.screen == .none)
    }

    @Test func aTrustedProcessWhoseTapWorksIsWorking() {
        let scene = Scene.make(trusted: true)
        scene.monitor.start()
        scene.monitor.noteTap(created: true)

        #expect(scene.store.grant == .working)
    }

    /// ONB-4: trusted and refused anyway. The tick the user can see is already there, so this is a
    /// different thing to tell them than "please grant Accessibility".
    @Test func aTrustedProcessWhoseTapWasRefusedIsStale() {
        let scene = Scene.make(trusted: true)
        scene.monitor.start()
        scene.monitor.noteTap(created: false)

        #expect(scene.store.grant == .stale)
        #expect(scene.store.state.screen == .repair)
    }

    /// The reason the tap answer is not simply remembered: it was recorded against a signature the trust
    /// database no longer holds an entry for, and it says nothing about the grant that replaced it.
    @Test func aGrantRemovedAndPutBackIsUntestedRatherThanStale() {
        let scene = Scene.make(trusted: true)
        scene.monitor.start()
        scene.monitor.noteTap(created: false)
        #expect(scene.store.grant == .stale)

        scene.trust.set(false)
        scene.watcher.fire()
        #expect(scene.store.grant == .notTrusted)

        scene.trust.set(true)
        scene.watcher.fire()
        #expect(scene.store.grant == .untested)
    }

    /// The notification is posted for every app's grant, not only ours, and there is no way to tell which.
    /// Re-reading is cheap; announcing would not be.
    @Test func aNoticeThatChangesNothingIsAnnouncedToNobody() {
        let scene = Scene.make(trusted: true)
        scene.monitor.start()
        scene.watcher.fire()
        scene.watcher.fire()

        #expect(scene.announced.grants == [.untested])
    }

    @Test func stoppingUnsubscribes() {
        let scene = Scene.make()
        scene.monitor.start()
        scene.monitor.stop()

        scene.trust.set(true)
        scene.watcher.fire()
        #expect(scene.store.grant == .notTrusted)
        #expect(scene.watcher.stops == 1)
    }
}
