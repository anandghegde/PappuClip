import Foundation
import PappuCore
import PappuTestSupport
import Synchronization
import Testing

/// The shape every remembered setting has: a default nobody stored, a change that survives a relaunch,
/// and a notification for the parts of the app that have to be told rather than asked.
@Suite struct SettingsValueTests {
    @Test func anUntouchedSettingIsItsDefaultAndIsNotStored() {
        let storage = FakeSettingsStorage()
        let value = SettingsValue(key: "bar.position", default: "above", storage: storage)
        #expect(value.value == "above")
        #expect(storage.keys.isEmpty)
    }

    @Test func aChangeSurvivesRelaunch() {
        let storage = FakeSettingsStorage()
        SettingsValue(key: "bar.position", default: "above", storage: storage).set("below")

        let afterRelaunch = SettingsValue(key: "bar.position", default: "above", storage: storage)
        #expect(afterRelaunch.value == "below")
    }

    /// A setting put back to its default is stored as nothing, so that a later change of default reaches
    /// a user who had chosen the old one by hand and then changed their mind back.
    @Test func settingTheDefaultBackClearsTheKey() {
        let storage = FakeSettingsStorage()
        let value = SettingsValue(key: "bar.position", default: "above", storage: storage)
        value.set("below")
        #expect(storage.keys == ["bar.position"])
        value.set("above")
        #expect(storage.keys.isEmpty)
    }

    @Test func observersHearEveryChangeAndNothingElse() {
        let heard = Mutex<[String]>([])
        let value = SettingsValue(key: "bar.position", default: "above", storage: FakeSettingsStorage())
        value.onChange { new in heard.withLock { $0.append(new) } }

        value.set("below")
        value.set("below")
        value.set("above")
        #expect(heard.withLock { $0 } == ["below", "above"])
    }

    /// The first write is a change too, even though nothing was ever read: a store built and then set
    /// has no cache to compare against, and an observer that missed this would register the wrong
    /// shortcut for the life of the process.
    @Test func theFirstChangeAfterLaunchIsHeard() {
        let heard = Mutex<[String]>([])
        let value = SettingsValue(key: "bar.position", default: "above", storage: FakeSettingsStorage())
        value.onChange { new in heard.withLock { $0.append(new) } }
        value.set("below")
        #expect(heard.withLock { $0 } == ["below"])
    }

    /// Storage written by a version that spelled the value differently, or a hand-edited defaults file,
    /// must not take the app down with it.
    @Test func anUndecodableValueReadsAsTheDefault() {
        let storage = FakeSettingsStorage(["bar.position": Data("not json".utf8)])
        #expect(SettingsValue(key: "bar.position", default: "above", storage: storage).value == "above")
    }

    @Test func updateChangesOneFieldOfACompoundSetting() {
        let value = SettingsValue(key: "rules", default: PrivacyRules(), storage: FakeSettingsStorage())
        value.update { $0.appearAutomatically = false }
        #expect(value.value == PrivacyRules(appearAutomatically: false))
    }
}

/// ACT-17a, ACT-18 and PRD §7.5 from the settings side: what the menu and the Settings window write,
/// and what the gate then reads.
@Suite struct PrivacyRulesStoreTests {
    @Test func aFreshInstallAppearsAutomaticallyAndBlocksNothing() {
        let store = PrivacyRulesStore(storage: FakeSettingsStorage())
        #expect(store.rules == PrivacyRules())
        #expect(store.appearAutomatically)
        #expect(!store.isPaused)
    }

    @Test func everySettingSurvivesRelaunch() {
        let storage = FakeSettingsStorage()
        let store = PrivacyRulesStore(storage: storage)
        store.setAppearAutomatically(false)
        store.setHardBlocked(true, forApp: "com.example.vault")
        store.setMode(.hotkeyOnly, forApp: "com.example.editor")

        let afterRelaunch = PrivacyRulesStore(storage: storage).rules
        #expect(!afterRelaunch.appearAutomatically)
        #expect(afterRelaunch.isHardBlocked("com.example.vault"))
        #expect(afterRelaunch.mode(for: "com.example.editor") == .hotkeyOnly)
    }

    /// An exclusion and a block are different settings, and turning one off leaves the other standing.
    @Test func unblockingAnAppLeavesItsModeAlone() {
        let store = PrivacyRulesStore(storage: FakeSettingsStorage())
        store.setHardBlocked(true, forApp: "com.example.editor")
        store.setMode(.hotkeyOnly, forApp: "com.example.editor")
        store.setHardBlocked(false, forApp: "com.example.editor")

        #expect(!store.rules.isHardBlocked("com.example.editor"))
        #expect(store.rules.mode(for: "com.example.editor") == .hotkeyOnly)
    }

    @Test func theDefaultModeIsStoredAsNoEntryAtAll() {
        let store = PrivacyRulesStore(storage: FakeSettingsStorage())
        store.setMode(.hotkeyOnly, forApp: "com.example.editor")
        store.setMode(.automatic, forApp: "com.example.editor")
        #expect(store.rules.appModes.isEmpty)
    }

    /// The pause belongs to `PauseStore`, under its own key with its own clock. A copy of it in this key
    /// would be one to read by mistake.
    @Test func aPauseIsNeverWrittenIntoTheRulesKey() throws {
        let storage = FakeSettingsStorage()
        let store = PrivacyRulesStore(storage: storage)
        store.pauseUntilResumed()
        store.setAppearAutomatically(false)

        #expect(store.rules.pause == .untilResumed)
        let written = try #require(storage.data(forKey: PrivacyRulesStore.storageKey))
        #expect(try JSONDecoder().decode(PrivacyRules.self, from: written).pause == .running)
    }

    @Test func aTimedPauseIsOverWhenItsHourIsUp() {
        let time = ManualDateSource()
        let store = PrivacyRulesStore(storage: FakeSettingsStorage(), now: time.reader)
        store.pauseForOneHour()
        #expect(store.isPaused)
        time.advance(by: PauseState.oneHour)
        #expect(!store.isPaused)
        #expect(store.rules.pause == .running)
    }

    /// What the gate is built with is a closure, so a setting changed after the gate exists is the one
    /// the next attempt is judged against (architecture §4.4).
    @Test func theReaderHandedToTheGateSeesLaterChanges() {
        let store = PrivacyRulesStore(storage: FakeSettingsStorage())
        let reader = store.reader
        #expect(reader().appearAutomatically)
        store.setAppearAutomatically(false)
        #expect(!reader().appearAutomatically)
    }

    /// One hook for both keys (ACT-16a, RUN-3): what listens is machinery that has to take a bar away or
    /// stop what is running, and it does not care which setting moved.
    @Test func oneHookHearsBothAPauseAndARuleChange() {
        let heard = Mutex<[PrivacyRules]>([])
        let store = PrivacyRulesStore(storage: FakeSettingsStorage())
        store.onChange { rules in heard.withLock { $0.append(rules) } }

        store.setAppearAutomatically(false)
        store.pauseUntilResumed()
        store.resume()

        let all = heard.withLock { $0 }
        #expect(all.count == 3)
        #expect(all.allSatisfy { !$0.appearAutomatically })
        #expect(all.map(\.pause) == [.running, .untilResumed, .running])
    }
}
