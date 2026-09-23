import Foundation
import PappuCore
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

/// ACT-5 from the settings side: what the recorder in Settings is allowed to write, and what the app
/// registers at the next launch.
@Suite struct ShortcutStoreTests {
    private let commandShiftC = HotkeyShortcut(keyCode: 8, modifiers: [.command, .shift])

    @Test func thereIsNoShortcutUntilTheUserRecordsOne() {
        let storage = FakeSettingsStorage()
        #expect(ShortcutStore(storage: storage).shortcut == nil)
        #expect(storage.keys.isEmpty)
    }

    @Test func aRecordedShortcutSurvivesRelaunch() {
        let storage = FakeSettingsStorage()
        #expect(ShortcutStore(storage: storage).set(commandShiftC))
        #expect(ShortcutStore(storage: storage).shortcut == commandShiftC)
    }

    /// A shortcut ACT-5 forbids is refused rather than stored, so that it cannot be read back at the
    /// next launch as though it had been fine all along.
    @Test func aShortcutThatWouldFireWhileTypingIsRefused() {
        let storage = FakeSettingsStorage()
        let store = ShortcutStore(storage: storage)
        #expect(!store.set(HotkeyShortcut(keyCode: 8, modifiers: [.shift])))
        #expect(store.shortcut == nil)
        #expect(storage.keys.isEmpty)
    }

    @Test func aFunctionKeyOnItsOwnIsAllowed() {
        let store = ShortcutStore(storage: FakeSettingsStorage())
        #expect(store.set(HotkeyShortcut(keyCode: 122)))
        #expect(store.shortcut == HotkeyShortcut(keyCode: 122))
    }

    @Test func clearingTheShortcutIsAlwaysAllowedAndLeavesNothingStored() {
        let storage = FakeSettingsStorage()
        let store = ShortcutStore(storage: storage)
        store.set(commandShiftC)
        #expect(store.set(nil))
        #expect(store.shortcut == nil)
        #expect(storage.keys.isEmpty)
    }

    /// Registration follows the setting: the recorder writes, and what hears it re-registers with the
    /// system. A refused shortcut must not reach the registrar at all.
    @Test func onlyAnAcceptedChangeIsAnnounced() {
        let heard = Mutex<[HotkeyShortcut?]>([])
        let store = ShortcutStore(storage: FakeSettingsStorage())
        store.onChange { shortcut in heard.withLock { $0.append(shortcut) } }

        store.set(commandShiftC)
        store.set(HotkeyShortcut(keyCode: 8, modifiers: [.shift]))
        store.set(nil)

        #expect(heard.withLock { $0 } == [commandShiftC, nil])
    }
}
