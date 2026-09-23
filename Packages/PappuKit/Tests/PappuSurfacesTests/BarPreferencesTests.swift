import Foundation
import PappuCore
import PappuSurfaces
import PappuTestSupport
import Synchronization
import Testing

/// BAR-3 and BAR-8a: the one thing about the bar M1 lets the user decide, and the settings the
/// controller is handed when they decide it.
@Suite struct BarPreferencesTests {
    @Test func theBarStartsAboveTheTextWithNothingStored() {
        let storage = FakeSettingsStorage()
        let preferences = BarPreferences(storage: storage)
        #expect(preferences.position == .aboveText)
        #expect(storage.keys.isEmpty)
    }

    @Test func aChosenPositionSurvivesRelaunch() {
        let storage = FakeSettingsStorage()
        BarPreferences(storage: storage).setPosition(.belowText)
        #expect(BarPreferences(storage: storage).position == .belowText)
    }

    /// The colour mode and the metrics are not choices in this build (BAR-8b is P1), and the settings
    /// the controller gets have to say so rather than carrying a saved copy of either.
    @Test func everythingButThePositionIsTheSameEveryTime() {
        let preferences = BarPreferences(storage: FakeSettingsStorage())
        preferences.setPosition(.belowText)
        #expect(preferences.settings == BarSettings(
            position: .belowText,
            colorPreference: .system,
            metrics: .standard
        ))
    }

    /// A bar already on screen does not move, but the next one does, so what listens is handed whole
    /// settings rather than being told to go and ask.
    @Test func aChangeIsAnnouncedAsTheSettingsToUseNext() {
        let heard = Mutex<[BarSettings]>([])
        let preferences = BarPreferences(storage: FakeSettingsStorage())
        preferences.onChange { settings in heard.withLock { $0.append(settings) } }

        preferences.setPosition(.belowText)
        preferences.setPosition(.belowText)
        preferences.setPosition(.aboveText)

        #expect(heard.withLock { $0 }.map(\.position) == [.belowText, .aboveText])
    }
}
