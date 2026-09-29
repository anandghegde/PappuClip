import Foundation
import PappuCore
import PappuSelection
@testable import PappuSettings
import PappuSurfaces
import PappuTestSupport
import Testing

/// Settings → App (PRD §7.5, §11.4): Software Update over the updater seam, the channel, Start at
/// login and the version. Sparkle itself is the app target's and is exercised by the release checklist.
@MainActor @Suite struct AppTabTests {
    /// Sparkle's side, as `SparkleUpdater` presents it.
    final class FakeUpdater: SoftwareUpdating {
        var started = 0
        var checks = 0
        var policy = UpdatePolicy.notifyOnly
        var channel = UpdateChannel.stable
        var canCheckForUpdates = true
        var lastCheck: Date?

        func start() { started += 1 }
        func checkForUpdates() { checks += 1 }
    }

    final class FakeLoginItem: LoginItemControlling {
        var state = LoginItemState.off
        var failure: (any Error)?
        var opened = 0
        /// What registering leaves behind: `.on`, or `.needsApproval` when System Settings has to agree.
        var afterRegistering = LoginItemState.on

        func setEnabled(_ enabled: Bool) throws {
            if let failure { throw failure }
            state = enabled ? afterRegistering : .off
        }

        func openSystemSettings() { opened += 1 }
    }

    private let storage = FakeSettingsStorage()

    private func model(updater: FakeUpdater? = FakeUpdater(), loginItem: FakeLoginItem? = FakeLoginItem()) -> AppTabModel {
        AppTabModel(
            version: .init(marketing: "0.9.0", build: "42"),
            updater: updater,
            preferences: UpdatePreferences(storage: storage),
            loginItem: loginItem
        )
    }

    // MARK: Strings

    @Test func everyAppTabStringIsInItsTable() {
        let missing = "\u{1}missing"
        for key in AppTabStrings.all {
            #expect(
                AppTabStrings.bundle.localizedString(forKey: key, value: missing, table: AppTabStrings.table) != missing,
                "\(key) is not in AppTab.strings"
            )
        }
        #expect(Set(AppTabStrings.all).count == AppTabStrings.all.count)
        #expect(AppTabStrings.version("1.2", "7") == "Version 1.2 (7)")
        #expect(AppTabStrings.linkLabel("Source Code").contains("Source Code"))
        #expect(AppTabStrings.lastChecked("today").contains("today"))
    }

    // MARK: Policy and channel

    /// Sparkle's two switches say three things, and only three.
    @Test func thePolicyIsSparklesTwoSwitches() {
        #expect(UpdatePolicy(automaticallyChecks: false, automaticallyDownloads: false) == .off)
        #expect(UpdatePolicy(automaticallyChecks: false, automaticallyDownloads: true) == .off)
        #expect(UpdatePolicy(automaticallyChecks: true, automaticallyDownloads: false) == .notifyOnly)
        #expect(UpdatePolicy(automaticallyChecks: true, automaticallyDownloads: true) == .installAutomatically)
        for policy in UpdatePolicy.allCases {
            let back = UpdatePolicy(automaticallyChecks: policy.automaticallyChecks, automaticallyDownloads: policy.automaticallyDownloads)
            #expect(back == policy)
        }
    }

    /// The stable channel is the appcast's default one, which every copy sees; a beta copy also sees
    /// items published on the "beta" channel.
    @Test func theBetaChannelAddsTheBetaItemsToTheDefaultOnes() {
        #expect(UpdateChannel.stable.allowedChannels.isEmpty)
        #expect(UpdateChannel.beta.allowedChannels == ["beta"])
    }

    @Test func choosingAPolicyReachesTheUpdater() {
        let updater = FakeUpdater()
        let model = model(updater: updater)
        #expect(model.policy == .notifyOnly)
        model.setPolicy(.installAutomatically)
        #expect(updater.policy == .installAutomatically)
        #expect(model.policy == .installAutomatically)
        model.setPolicy(.off)
        #expect(updater.policy == .off)
    }

    /// Stable until the user asks for betas, remembered across launches, and handed to the updater.
    @Test func includingBetasIsStoredAndReachesTheUpdater() {
        let updater = FakeUpdater()
        let model = model(updater: updater)
        #expect(model.channel == .stable)
        model.setChannel(.beta)
        #expect(updater.channel == .beta)
        #expect(UpdatePreferences(storage: storage).channel == .beta)
        #expect(self.model(updater: FakeUpdater()).channel == .beta)
        model.setChannel(.stable)
        #expect(updater.channel == .stable)
        #expect(UpdatePreferences(storage: storage).channel == .stable)
    }

    @Test func checkNowAsksTheUpdaterOnlyWhenItCan() {
        let updater = FakeUpdater()
        let model = model(updater: updater)
        model.checkForUpdates()
        #expect(updater.checks == 1)
        updater.canCheckForUpdates = false
        model.refresh()
        #expect(!model.canCheckForUpdates)
        model.checkForUpdates()
        #expect(updater.checks == 1)
    }

    @Test func theLastCheckIsSaidOrNeverChecked() {
        let updater = FakeUpdater()
        let model = model(updater: updater)
        #expect(model.lastCheckText() == AppTabStrings.neverChecked)
        updater.lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
        model.refresh()
        #expect(model.lastCheckText(locale: Locale(identifier: "en_US")).hasPrefix("Last checked "))
    }

    /// A development build has no updater: nothing to press, and a sentence saying why.
    @Test func aBuildWithoutAnUpdaterOffersNothingToPress() {
        let model = model(updater: nil)
        #expect(!model.updatesAvailable)
        #expect(!model.canCheckForUpdates)
        model.checkForUpdates()
        model.setPolicy(.installAutomatically)
        #expect(model.policy == .off)
        // The channel is still remembered, for the day this copy is replaced by a release build.
        model.setChannel(.beta)
        #expect(UpdatePreferences(storage: storage).channel == .beta)
    }

    // MARK: Start at login

    @Test func startAtLoginRegistersAndUnregisters() {
        let item = FakeLoginItem()
        let model = model(loginItem: item)
        #expect(!model.loginItemIsOn)
        #expect(model.loginItemIsAvailable)
        model.setStartAtLogin(true)
        #expect(item.state == .on)
        #expect(model.loginItemIsOn)
        model.setStartAtLogin(false)
        #expect(item.state == .off)
        #expect(!model.loginItemIsOn)
    }

    /// Registered but not yet allowed in System Settings: the switch stays on and the tab says where to
    /// finish.
    @Test func aLoginItemAwaitingApprovalSaysWhereToAllowIt() {
        let item = FakeLoginItem()
        item.afterRegistering = .needsApproval
        let model = model(loginItem: item)
        model.setStartAtLogin(true)
        #expect(model.loginItemState == .needsApproval)
        #expect(model.loginItemIsOn)
        model.openLoginItemSettings()
        #expect(item.opened == 1)
    }

    @Test func aFailedLoginItemChangeIsSaidAndCleared() {
        let item = FakeLoginItem()
        item.failure = CocoaError(.featureUnsupported)
        let model = model(loginItem: item)
        model.setStartAtLogin(true)
        #expect(model.loginItemFailure == AppTabStrings.loginItemFailed)
        #expect(!model.loginItemIsOn)
        item.failure = nil
        model.setStartAtLogin(true)
        #expect(model.loginItemFailure == nil)
        #expect(model.loginItemIsOn)
    }

    @Test func aCopyThatCannotBeALoginItemSaysSo() {
        let item = FakeLoginItem()
        item.state = .unavailable
        #expect(!model(loginItem: item).loginItemIsAvailable)
        #expect(!model(loginItem: nil).loginItemIsAvailable)
    }

    // MARK: Version and links

    @Test func theVersionIsTheBundlesTwoNumbers() {
        #expect(model().versionText == "Version 0.9.0 (42)")
        let version = AppTabModel.Version(bundle: Bundle(for: FakeUpdater.self))
        #expect(!version.marketing.isEmpty)
        #expect(!version.build.isEmpty)
    }

    @Test func linksAndTheConsoleOpenWhatTheyName() {
        var opened: [URL] = []
        var consoles = 0
        let link = AppTabModel.Link(title: AppTabStrings.sourceCode, url: ProductIdentity.sourceRepository)
        let model = AppTabModel(
            version: .init(marketing: "1", build: "1"),
            links: [link],
            updater: nil,
            preferences: UpdatePreferences(storage: storage),
            loginItem: nil,
            open: { opened.append($0) },
            openDebugConsole: { consoles += 1 }
        )
        model.open(link)
        model.showDebugConsole()
        #expect(opened == [ProductIdentity.sourceRepository])
        #expect(consoles == 1)
    }

    /// The tab is in the window only when the assembly hands the model one.
    @Test func theSettingsModelCarriesTheAppTab() {
        let app = model()
        let settings = SettingsModel(
            rules: PrivacyRulesStore(storage: storage),
            shortcuts: ShortcutStore(storage: storage),
            bar: BarPreferences(storage: storage),
            onboarding: OnboardingStore(storage: storage),
            catalog: { ActionCatalog() },
            app: app
        )
        #expect(settings.app === app)
        #expect(SettingsView.Tab.allCases.contains(.app))
    }
}
