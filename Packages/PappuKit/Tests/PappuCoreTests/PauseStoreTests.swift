import Foundation
import PappuCore
import PappuTestSupport
import Testing

/// ACT-18. The menu's three commands, and the one property that makes a timed pause safe: it is a
/// date, not a countdown.
@Suite struct PauseStoreTests {
    @Test func aFreshStoreIsNotPaused() {
        let store = PauseStore(storage: FakeSettingsStorage())
        #expect(store.current == .running)
        #expect(!store.isPaused())
    }

    @Test func pausingForAnHourEndsAnHourLater() {
        let time = ManualDateSource()
        let store = PauseStore(storage: FakeSettingsStorage(), now: time.reader)
        store.pauseForOneHour()
        #expect(store.isPaused())
        time.advance(by: PauseState.oneHour - 1)
        #expect(store.isPaused())
        time.advance(by: 1)
        #expect(!store.isPaused())
        #expect(store.current == .running)
    }

    @Test func pausingUntilResumedNeverEndsOnItsOwn() {
        let time = ManualDateSource()
        let store = PauseStore(storage: FakeSettingsStorage(), now: time.reader)
        store.pauseUntilResumed()
        time.advance(by: 30 * 24 * 60 * 60)
        #expect(store.isPaused())
        store.resume()
        #expect(!store.isPaused())
    }

    @Test func aPauseSurvivesRelaunch() {
        let storage = FakeSettingsStorage()
        let time = ManualDateSource()
        PauseStore(storage: storage, now: time.reader).pauseForOneHour()

        time.advance(by: 10 * 60)
        let afterRelaunch = PauseStore(storage: storage, now: time.reader)
        #expect(afterRelaunch.isPaused())
        // Absolute, so the remaining fifty minutes are what is left, not a fresh hour.
        time.advance(by: 50 * 60)
        #expect(!afterRelaunch.isPaused())
    }

    /// A pause that ran out while the app was not running is over, not pending.
    @Test func anExpiryInThePastReadsAsRunningAndIsClearedAway() {
        let storage = FakeSettingsStorage()
        let time = ManualDateSource()
        PauseStore(storage: storage, now: time.reader).pauseForOneHour()
        time.advance(by: 2 * PauseState.oneHour)

        let afterRelaunch = PauseStore(storage: storage, now: time.reader)
        #expect(afterRelaunch.current == .running)
        #expect(storage.keys.isEmpty)
    }

    @Test func resumingLeavesNothingBehind() {
        let storage = FakeSettingsStorage()
        let store = PauseStore(storage: storage)
        store.pauseUntilResumed()
        #expect(storage.keys == [PauseStore.storageKey])
        store.resume()
        #expect(storage.keys.isEmpty)
    }

    @Test func rubbishInStorageReadsAsNotPaused() {
        let storage = FakeSettingsStorage([PauseStore.storageKey: Data("not a pause".utf8)])
        #expect(PauseStore(storage: storage).current == .running)
    }
}
