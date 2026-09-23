import Foundation
import Observation
import PappuCore
import PappuSelection
import PappuSurfaces

/// Everything the Settings window shows, decided where a test can read it (PRD §7.5).
///
/// The window itself is SwiftUI over this, and the split is the usual one in this codebase: the rules
/// live in a value or a plain object, and the framework is handed an answer rather than asked to work
/// one out. What that buys here in particular is the *write* side. Four stores stand behind this one
/// screen — `PrivacyRulesStore`, `ShortcutStore`, `BarPreferences`, `OnboardingStore` — each with its
/// own key, its own default and, in one case, a refusal (ACT-5). A `Toggle` bound straight at a store
/// would make each of those a fact about a SwiftUI view, and the refusal unreachable without a window.
///
/// Every setting is mirrored here rather than read through: the stored properties are what the window
/// draws, `refresh()` is what puts them back in step, and each store's `onChange` calls it. So a change
/// made from the menu bar while the window is open reaches the window (ACT-18's pause is the one that
/// happens in practice), and nothing needs a timer or a re-open to notice. The mirrors are
/// `private(set)` and the setters are named, because a `didSet` that wrote back to its store would hear
/// its own write coming home again.
@MainActor @Observable
public final class SettingsModel {
    /// One app with a rule of its own, as the Apps sheet lists it (ACT-17a, ALM-8).
    ///
    /// Two independent settings, not one choice of three. "Don't appear automatically" is an exclusion
    /// — the bar stays away, the shortcut still works; "Never read text here" is a hard block, and
    /// nothing is read there by any route. An app can be either, both or, for as long as the sheet is
    /// open, neither.
    public struct AppRule: Identifiable, Sendable, Equatable {
        public var bundleID: String
        /// The app's name if we could find it, else its bundle identifier — which is not pretty, but is
        /// the truth about a rule the user can otherwise no longer see to remove.
        public var name: String
        public var isExcluded: Bool
        public var isHardBlocked: Bool

        public var id: String { bundleID }

        public init(bundleID: String, name: String, isExcluded: Bool, isHardBlocked: Bool) {
            self.bundleID = bundleID
            self.name = name
            self.isExcluded = isExcluded
            self.isHardBlocked = isHardBlocked
        }
    }

    /// One row of the Actions tab (§7.6).
    ///
    /// Read-only in this build. §7.6's list reorders, renames, switches off per action and assigns a
    /// command to each; that is ALM-2a and ALM-5, P1, and lands in M4 with the extension packages the
    /// list is really for. What M1 owes is that the five built-ins are *visible* — a user who sees
    /// "Search" on the bar should be able to find out where it came from.
    ///
    /// The icon is `BarIcon` rather than a type of this module's own: it is already this app's answer
    /// to "what does §8.11's specifier draw", and a second answer here would be a second answer to get
    /// out of step with the bar.
    public struct ActionRow: Identifiable, Sendable, Equatable {
        public var key: ActionKey
        public var title: String
        /// The extension the action came from. For a built-in it is the same word as the title, and the
        /// row says "Built-in" instead.
        public var extensionName: String
        public var icon: BarIcon?
        public var isBuiltIn: Bool
        /// ALM-4. A disabled action keeps its place in the list and says so.
        public var isEnabled: Bool

        public var id: ActionKey { key }

        public init(
            key: ActionKey,
            title: String,
            extensionName: String,
            icon: BarIcon?,
            isBuiltIn: Bool,
            isEnabled: Bool
        ) {
            self.key = key
            self.title = title
            self.extensionName = extensionName
            self.icon = icon
            self.isBuiltIn = isBuiltIn
            self.isEnabled = isEnabled
        }
    }

    private let rules: PrivacyRulesStore
    private let shortcuts: ShortcutStore
    private let bar: BarPreferences
    private let onboarding: OnboardingStore
    private let catalog: @Sendable () -> ActionCatalog
    private let displayName: @Sendable (String) -> String?
    private let locale: Locale
    private let openAccessibilitySettings: @MainActor () -> Void

    /// Apps named in the sheet during this session that have no rule yet, so that a row does not vanish
    /// between adding it and choosing what it is for. Not stored: an app with neither box ticked has no
    /// setting to remember, and the sheet is the only place it would be seen.
    private var awaitingARule: Set<String> = []

    // MARK: What the window draws

    public private(set) var appearAutomatically = true
    public private(set) var position = BarPosition.aboveText
    public private(set) var shortcut: HotkeyShortcut?
    /// Set when a recorded shortcut was refused (ACT-5), and cleared by the next attempt. The window
    /// shows it under the recorder: a shortcut that silently did not take is worse than no shortcut.
    public private(set) var shortcutRefusal: String?
    public private(set) var grant = AccessibilityGrant.notTrusted
    public private(set) var apps: [AppRule] = []
    public private(set) var actions: [ActionRow] = []

    public init(
        rules: PrivacyRulesStore,
        shortcuts: ShortcutStore,
        bar: BarPreferences,
        onboarding: OnboardingStore,
        catalog: @escaping @Sendable () -> ActionCatalog,
        displayName: @escaping @Sendable (String) -> String? = { _ in nil },
        locale: Locale = .current,
        openAccessibilitySettings: @escaping @MainActor () -> Void = {}
    ) {
        self.rules = rules
        self.shortcuts = shortcuts
        self.bar = bar
        self.onboarding = onboarding
        self.catalog = catalog
        self.displayName = displayName
        self.locale = locale
        self.openAccessibilitySettings = openAccessibilitySettings
        refresh()
        // Each store announces on whichever thread wrote to it — the menu bar is the main one, the tap
        // health monitor is not — so every one of them comes back to this actor before touching a mirror.
        // A change that is already on the main thread is taken now rather than next turn: the menu bar's
        // own writes are the ones that happen while the window is open, and a hop would draw the old
        // value for a frame first.
        let observe: @Sendable () -> Void = { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
        rules.onChange { _ in observe() }
        shortcuts.onChange { _ in observe() }
        bar.onChange { _ in observe() }
        onboarding.onChange { _ in observe() }
    }

    /// Reads every store and puts the mirrors back in step. Idempotent, and cheap enough to call on any
    /// change from anywhere rather than working out which mirror a given change touched.
    public func refresh() {
        let current = rules.rules
        appearAutomatically = current.appearAutomatically
        position = bar.position
        shortcut = shortcuts.shortcut
        grant = onboarding.grant
        apps = Self.appRules(from: current, alsoShowing: awaitingARule, named: displayName)
        actions = catalog().actions.map { ActionRow($0, locale: locale) }
    }

    // MARK: General

    public func setAppearAutomatically(_ on: Bool) {
        rules.setAppearAutomatically(on)
        refresh()
    }

    public func setPosition(_ position: BarPosition) {
        bar.setPosition(position)
        refresh()
    }

    /// - Returns: False when ACT-5 will not have it, in which case nothing is stored and
    ///   `shortcutRefusal` says why. The recorder keeps the keys it heard on screen either way, so that
    ///   the user can see what they pressed next to the reason it will not do.
    @discardableResult
    public func record(_ shortcut: HotkeyShortcut) -> Bool {
        guard shortcuts.set(shortcut) else {
            shortcutRefusal = SettingsStrings.shortcutRefused
            return false
        }
        shortcutRefusal = nil
        refresh()
        return true
    }

    /// Back to no shortcut at all, which is the state a fresh install is in (ACT-5 has no default).
    public func clearShortcut() {
        shortcuts.set(nil)
        shortcutRefusal = nil
        refresh()
    }

    // MARK: The Accessibility banner (ONB-1, ONB-4)

    /// What to say about the grant, or nothing at all. An untested grant says nothing: it is the
    /// ordinary state of a launch where no bar has been asked for yet, and a warning there would be a
    /// warning in every quiet moment — the same rule the menu follows.
    public var accessibilityWarning: String? {
        switch grant {
        case .notTrusted: SettingsStrings.accessibilityMissing
        case .stale: SettingsStrings.accessibilityStale
        case .working, .untested: nil
        }
    }

    public func openAccessibilityPane() {
        openAccessibilitySettings()
    }

    // MARK: Apps (ACT-17a, ALM-8)

    /// Names an app in the sheet without deciding anything about it yet.
    public func addApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        awaitingARule.insert(trimmed)
        refresh()
    }

    public func setExcluded(_ excluded: Bool, forApp bundleID: String) {
        rules.setMode(excluded ? .hotkeyOnly : .automatic, forApp: bundleID)
        awaitingARule.insert(bundleID)
        refresh()
    }

    public func setHardBlocked(_ blocked: Bool, forApp bundleID: String) {
        rules.setHardBlocked(blocked, forApp: bundleID)
        awaitingARule.insert(bundleID)
        refresh()
    }

    /// Forgets both rules at once, and the row with them. Leaving one behind is how an app comes back
    /// into a list the user thought they had cleared.
    public func removeApp(_ bundleID: String) {
        rules.setMode(.automatic, forApp: bundleID)
        rules.setHardBlocked(false, forApp: bundleID)
        awaitingARule.remove(bundleID)
        refresh()
    }

    private static func appRules(
        from rules: PrivacyRules,
        alsoShowing pending: Set<String>,
        named displayName: @Sendable (String) -> String?
    ) -> [AppRule] {
        let identifiers = Set(rules.appModes.keys).union(rules.hardBlockedApps).union(pending)
        return identifiers
            .map { bundleID in
                AppRule(
                    bundleID: bundleID,
                    name: displayName(bundleID) ?? bundleID,
                    isExcluded: rules.mode(for: bundleID) != .automatic,
                    isHardBlocked: rules.isHardBlocked(bundleID)
                )
            }
            // By name, so the list reads the way the user thinks of it, and by identifier after that so
            // that two apps with one name — an app and its helper — keep a stable order.
            .sorted {
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byName == .orderedSame ? $0.bundleID < $1.bundleID : byName == .orderedAscending
            }
    }
}

extension SettingsModel.ActionRow {
    /// One catalog action as a row. The title is resolved for `locale` here, the same place and for the
    /// same reason `BarItem` resolves it: `LocalizedText` keeps every language the author wrote, and a
    /// test that passes the locale it means gets the same answer on every machine.
    public init(_ action: CatalogAction, locale: Locale = .current) {
        self.init(
            key: action.key,
            title: action.title.text(for: locale),
            extensionName: action.extensionName.text(for: locale),
            icon: BarIcon(action.icon),
            isBuiltIn: action.builtin != nil,
            isEnabled: action.isEnabled
        )
    }
}
