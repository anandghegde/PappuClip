import Foundation
import PappuCore
import PappuSelection
import PappuSettings
import PappuSurfaces
import PappuTestSupport
import Testing

/// The Settings window's decisions (PRD §7.5), reached the way the window reaches them: through the same
/// four stores the app builds, with nothing between them and the assertion but the model.
///
/// What is worth testing here is not that a toggle writes a boolean. It is the three things that are
/// easy to get wrong when a screen has four stores behind it: that what the window writes is what the
/// next launch reads, that a change made somewhere else — the menu bar, a grant the user has just
/// given — reaches a window that is already open, and that a refusal (ACT-5) is visible rather than
/// silent.
@MainActor
@Suite struct SettingsModelTests {
    // MARK: What the window shows

    @Test func aFreshInstallShowsWhatTheStoresSay() {
        let scene = Scene()
        #expect(scene.model.appearAutomatically)
        #expect(scene.model.position == .aboveText)
        #expect(scene.model.shortcut == nil)
        #expect(scene.model.shortcutRefusal == nil)
        #expect(scene.model.apps.isEmpty)
        #expect(scene.model.accessibilityWarning == nil)
    }

    @Test func whatTheWindowWritesIsWhatTheNextLaunchReads() {
        let scene = Scene()
        scene.model.setAppearAutomatically(false)
        scene.model.setPosition(.belowText)
        #expect(scene.model.record(HotkeyShortcut(keyCode: 8, modifiers: [.command, .shift])))
        scene.model.setExcluded(true, forApp: "com.example.editor")
        scene.model.setHardBlocked(true, forApp: "com.example.vault")

        let afterRelaunch = Scene(storage: scene.storage)
        #expect(!afterRelaunch.model.appearAutomatically)
        #expect(afterRelaunch.model.position == .belowText)
        #expect(afterRelaunch.model.shortcut == HotkeyShortcut(keyCode: 8, modifiers: [.command, .shift]))
        #expect(afterRelaunch.model.apps.map(\.bundleID) == ["com.example.editor", "com.example.vault"])
    }

    /// The menu bar writes the same settings this window draws (ACT-18's pause is the one that happens
    /// while somebody is looking at it), and the grant arrives from a watcher that asked nobody. A window
    /// that only read its stores when it opened would show yesterday's answer until it was closed.
    @Test func aChangeMadeSomewhereElseReachesAnOpenWindow() {
        let scene = Scene()
        scene.rules.setAppearAutomatically(false)
        scene.bar.setPosition(.belowText)
        scene.shortcuts.set(HotkeyShortcut(keyCode: 98))
        scene.onboarding.noteGrant(.notTrusted)

        #expect(!scene.model.appearAutomatically)
        #expect(scene.model.position == .belowText)
        #expect(scene.model.shortcut == HotkeyShortcut(keyCode: 98))
        #expect(scene.model.accessibilityWarning == SettingsStrings.accessibilityMissing)
    }

    // MARK: The shortcut (ACT-5)

    /// ACT-5 refuses a shortcut that could be typed, and `ShortcutStore` is where that is decided. What
    /// this window owes is that the refusal is *said*: a recorder that quietly kept the old shortcut
    /// would leave the user pressing a key that does nothing and no way to find out why.
    @Test func aShortcutThatCouldBeTypedIsRefusedAndSaysWhy() {
        let scene = Scene()
        #expect(!scene.model.record(HotkeyShortcut(keyCode: 8, modifiers: [.shift])))
        #expect(scene.model.shortcut == nil)
        #expect(scene.model.shortcutRefusal == SettingsStrings.shortcutRefused)
        #expect(!scene.storage.keys.contains(ShortcutStore.storageKey))
    }

    @Test func theNextAttemptClearsTheRefusal() {
        let scene = Scene()
        #expect(!scene.model.record(HotkeyShortcut(keyCode: 8)))
        #expect(scene.model.record(HotkeyShortcut(keyCode: 8, modifiers: [.control])))
        #expect(scene.model.shortcutRefusal == nil)
        #expect(scene.model.shortcut == HotkeyShortcut(keyCode: 8, modifiers: [.control]))
    }

    /// The exception ACT-5 makes, from the settings side: a function key types nothing, so it needs no
    /// modifier at all.
    @Test func aFunctionKeyOnItsOwnIsAllowed() {
        let scene = Scene()
        #expect(scene.model.record(HotkeyShortcut(keyCode: 98)))
        #expect(scene.model.shortcut == HotkeyShortcut(keyCode: 98))
    }

    /// There is no default shortcut (`ShortcutStore`), so clearing one has to be able to get back to
    /// having none rather than to some value the user never chose.
    @Test func clearingTheShortcutPutsItBackToNone() {
        let scene = Scene()
        #expect(scene.model.record(HotkeyShortcut(keyCode: 98)))
        scene.model.clearShortcut()
        #expect(scene.model.shortcut == nil)
        #expect(!scene.storage.keys.contains(ShortcutStore.storageKey))
    }

    // MARK: Apps (ACT-17a, ALM-8)

    /// The two ticks are two settings. An app the bar stays out of is not an app whose text is never
    /// read, and a row that wrote both at once would take a decision the user did not make.
    @Test func excludingAnAppDoesNotBlockReadingIt() throws {
        let scene = Scene()
        scene.model.setExcluded(true, forApp: "com.example.editor")

        let rule = try #require(scene.model.apps.first)
        #expect(rule.isExcluded)
        #expect(!rule.isHardBlocked)
        #expect(scene.rules.rules.mode(for: "com.example.editor") == .hotkeyOnly)
        #expect(!scene.rules.rules.isHardBlocked("com.example.editor"))
    }

    /// Adding an app is naming it, not deciding about it. The row has to stay on screen while the user
    /// chooses what it is for, and nothing may be stored until they have: an app with neither tick has no
    /// setting, and a stored "no setting" would be a rule that outlived the sheet.
    @Test func anAppNamedButNotYetDecidedAboutKeepsItsRowAndStoresNothing() {
        let scene = Scene()
        scene.model.addApp("com.example.editor")

        #expect(scene.model.apps.map(\.bundleID) == ["com.example.editor"])
        #expect(scene.model.apps.first?.isExcluded == false)
        #expect(scene.model.apps.first?.isHardBlocked == false)
        #expect(scene.storage.keys.isEmpty)
        #expect(Scene(storage: scene.storage).model.apps.isEmpty)
    }

    @Test func removingAnAppForgetsBothOfItsRules() {
        let scene = Scene()
        scene.model.setExcluded(true, forApp: "com.example.vault")
        scene.model.setHardBlocked(true, forApp: "com.example.vault")
        scene.model.removeApp("com.example.vault")

        #expect(scene.model.apps.isEmpty)
        #expect(scene.rules.rules.appModes.isEmpty)
        #expect(scene.rules.rules.hardBlockedApps.isEmpty)
    }

    /// The list reads the way the user thinks of it, and an app we cannot name is still listed — under
    /// its identifier, which is ugly but is the only way to see a rule in order to remove it.
    @Test func theAppsAreListedByNameAndAnUnknownOneByItsIdentifier() {
        let scene = Scene(names: ["com.example.zebra": "Alpha", "com.example.alpha": "Zebra"])
        for app in ["com.example.zebra", "com.example.alpha", "com.example.ghost"] {
            scene.model.setHardBlocked(true, forApp: app)
        }
        #expect(scene.model.apps.map(\.name) == ["Alpha", "com.example.ghost", "Zebra"])
    }

    // MARK: The Accessibility banner (ONB-1, ONB-4)

    /// The same rule the menu follows: an untested grant is the ordinary state of a launch where nothing
    /// has been asked for yet, and a warning there would be a warning in every quiet moment.
    @Test func theBannerSaysNothingUntilThereIsSomethingToSay() {
        let expected: [(AccessibilityGrant, String?)] = [
            (.working, nil),
            (.untested, nil),
            (.notTrusted, SettingsStrings.accessibilityMissing),
            (.stale, SettingsStrings.accessibilityStale),
        ]
        #expect(Set(expected.map(\.0)) == Set(AccessibilityGrant.allCases))
        for (grant, warning) in expected {
            #expect(Scene(grant: grant).model.accessibilityWarning == warning, "\(grant)")
        }
    }

    /// ONB-1 asks for the grant to be detected live. A window open while the user ticks the box has to
    /// stop saying the permission is missing without being reopened.
    @Test func aGrantGivenWhileTheWindowIsOpenTakesTheBannerAway() {
        let scene = Scene(grant: .notTrusted)
        #expect(scene.model.accessibilityWarning != nil)
        scene.onboarding.noteGrant(.working)
        #expect(scene.model.accessibilityWarning == nil)
    }

    @Test func theBannersButtonOpensTheAccessibilityPaneAndNothingElse() {
        let opened = Counter()
        let scene = Scene(grant: .notTrusted, openAccessibilitySettings: { opened.bump() })
        scene.model.openAccessibilityPane()
        #expect(opened.count == 1)
        #expect(scene.model.grant == .notTrusted)
    }

    // MARK: The Actions tab (§7.6)

    /// The five that ship, from the files that ship them: what a user sees when they ask where the
    /// buttons on the bar came from.
    ///
    /// In `BuiltinAction.allCases` order, which is ALM-3's default action order and PRD §7.4's table —
    /// not the order a directory listing happens to come back in. The list is the surface that order is
    /// *for*, so it is checked against the same source `BuiltinExtensions` loads from.
    @Test func theActionsTabListsTheBuiltinsInTheDefaultActionOrder() throws {
        let scene = Scene(catalog: try builtinCatalog())
        #expect(scene.model.actions.map(\.key.action) == BuiltinAction.allCases.map(\.rawValue))
        #expect(scene.model.actions.map(\.title) == ["Cut", "Copy", "Paste", "Search", "Open Link"])
        #expect(scene.model.actions.allSatisfy { $0.isBuiltIn })
        #expect(scene.model.actions.allSatisfy { $0.isEnabled })
        #expect(scene.model.actions.map(\.icon) == [
            .symbol("scissors"),
            .symbol("doc.on.doc"),
            .symbol("doc.on.clipboard"),
            .symbol("magnifyingglass"),
            .symbol("arrow.up.right.square"),
        ])
    }

    /// ALM-4: a disabled action keeps its place in the list. A list that dropped it would leave the user
    /// with no way to switch it back on.
    @Test func anActionThatIsSwitchedOffStaysInTheListAndSaysSo() throws {
        let entries = try BuiltinExtensions.entries(from: Self.builtinsDirectory())
            .map { ActionCatalog.Entry(manifest: $0.manifest, origin: $0.origin, isEnabled: false) }
        let scene = Scene(catalog: ActionCatalog(entries: entries))
        #expect(scene.model.actions.count == 5)
        #expect(scene.model.actions.allSatisfy { !$0.isEnabled })
    }

    /// A title is resolved for a locale once, in the same place `BarItem` resolves it, so that the list
    /// and the bar cannot disagree about what an action is called.
    @Test func aTitleIsResolvedForTheLocaleTheModelWasGiven() {
        let manifest = ExtensionManifest(
            name: .localized(["en": "Copy", "fr": "Copier"]),
            identifier: "com.example.copy",
            actions: [ActionManifest(identifier: "copy", executor: .builtin(.copy))]
        )
        let catalog = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)])
        #expect(Scene(catalog: catalog, locale: Locale(identifier: "fr_FR")).model.actions.first?.title == "Copier")
        #expect(Scene(catalog: catalog, locale: Locale(identifier: "en_US")).model.actions.first?.title == "Copy")
    }

    // MARK: -

    /// The real built-ins, found by walking up from this file. There is no app bundle yet.
    static func builtinsDirectory() throws -> URL {
        var candidate = URL(filePath: #filePath).standardizedFileURL
        while candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
            let resources = candidate.appending(path: "Resources/" + BuiltinExtensions.directoryName)
            if FileManager.default.fileExists(atPath: resources.path) {
                return resources
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func builtinCatalog() throws -> ActionCatalog {
        ActionCatalog(entries: try BuiltinExtensions.entries(from: Self.builtinsDirectory()))
    }
}

/// The four stores the app builds, over one storage a test can hand to a second scene to play a
/// relaunch.
@MainActor
private struct Scene {
    let storage: FakeSettingsStorage
    let rules: PrivacyRulesStore
    let shortcuts: ShortcutStore
    let bar: BarPreferences
    let onboarding: OnboardingStore
    let model: SettingsModel

    init(
        storage: FakeSettingsStorage = FakeSettingsStorage(),
        grant: AccessibilityGrant = .working,
        catalog: ActionCatalog = ActionCatalog(),
        locale: Locale = Locale(identifier: "en_US"),
        names: [String: String] = [:],
        openAccessibilitySettings: @escaping @MainActor () -> Void = {}
    ) {
        self.storage = storage
        rules = PrivacyRulesStore(storage: storage)
        shortcuts = ShortcutStore(storage: storage)
        bar = BarPreferences(storage: storage)
        onboarding = OnboardingStore(storage: storage, grant: grant)
        model = SettingsModel(
            rules: rules,
            shortcuts: shortcuts,
            bar: bar,
            onboarding: onboarding,
            catalog: { catalog },
            displayName: { names[$0] },
            locale: locale,
            openAccessibilitySettings: openAccessibilitySettings
        )
    }
}

/// A count the closure the model stores can bump. The closure is `@MainActor`, like everything else
/// here, so nothing more than a `var` is needed.
@MainActor
private final class Counter {
    private(set) var count = 0

    func bump() {
        count += 1
    }
}
