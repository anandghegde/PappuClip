import Foundation
import PappuApp
import PappuCore
import PappuExtensions
import PappuJSBridge
import PappuSettings
import PappuTestSupport
import Testing

/// DEV-1: the debugging the helper is told about reaches only approved development folders, and the
/// menu says development mode is on for as long as one is approved.
@Suite struct DevelopmentModeTests {
    private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let folder = LocalIdentity(UUID(uuidString: "00000000-0000-0000-0000-00000000DE01")!)

    @Test func withBothSwitchesOffNothingIsDebugged() {
        #expect(DevelopmentMode.debugging(for: [folder], verboseLogging: false, webInspector: false).isEmpty)
    }

    @Test func withoutAFolderNothingIsDebuggedWhateverTheSwitchesSay() {
        #expect(DevelopmentMode.debugging(for: [], verboseLogging: true, webInspector: true).isEmpty)
    }

    @Test func onlyTheNamedFoldersGetOnlyTheSwitchesTurnedOn() {
        let inspectOnly = DevelopmentMode.debugging(for: [folder], verboseLogging: false, webInspector: true)
        #expect(inspectOnly == [folder.description: JSDebug(inspectable: true, verbose: false)])

        let verboseOnly = DevelopmentMode.debugging(for: [folder], verboseLogging: true, webInspector: false)
        #expect(verboseOnly == [folder.description: JSDebug(inspectable: false, verbose: true)])
    }

    @Test func thePreferencesAreReadTogetherWithTheFolders() {
        let preferences = DeveloperPreferences(storage: FakeSettingsStorage())
        #expect(DevelopmentMode.debugging(for: [folder], preferences: preferences).isEmpty)
        preferences.setWebInspector(true)
        #expect(DevelopmentMode.debugging(for: [folder], preferences: preferences)[folder.description]?.inspectable == true)
    }

    @Test func theMenuSaysDevelopmentModeIsOn() {
        let menu = MenuBarMenu(rules: PrivacyRules(), now: noon, developmentMode: true)
        #expect(menu.entries.first == .status(DeveloperStrings.menuStatus))
        #expect(menu.statusLine == nil, "the pause status line is still only about a pause")
        #expect(menu.commands == MenuBarMenu(rules: PrivacyRules(), now: noon).commands)
    }

    @Test func theMenuSaysNothingAboutDevelopmentOtherwise() {
        let menu = MenuBarMenu(rules: PrivacyRules(), now: noon)
        #expect(!menu.entries.contains(.status(DeveloperStrings.menuStatus)))
    }

    @Test func aPauseIsStillSaidWhileDeveloping() {
        let menu = MenuBarMenu(rules: PrivacyRules(pause: .untilResumed), now: noon, developmentMode: true)
        #expect(menu.entries.contains(.status(DeveloperStrings.menuStatus)))
        #expect(menu.statusLine == AppStrings.pausedUntilResumed)
    }
}
