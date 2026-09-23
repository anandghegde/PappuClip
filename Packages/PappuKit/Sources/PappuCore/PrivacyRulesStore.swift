import Foundation
import Synchronization

/// The settings the gate reads, as the menu bar and the Settings window write them (PRD §7.5).
///
/// Two stores stand behind one answer. The pause is `PauseStore`'s, under its own key, because it has a
/// clock and an expiry to settle (ACT-18); everything else — the "Appear automatically" toggle, the
/// hard blocks, the per-app modes — is one Codable value under another. `rules` puts them back together,
/// and it is `rules` that `PrivacyGate` is handed, so no caller has to know there were two.
///
/// What is stored is therefore never the whole of `PrivacyRules`: the pause is zeroed on the way in, so
/// that a pause cannot be remembered in two places and read back from the stale one.
public final class PrivacyRulesStore: Sendable {
    public static let storageKey = "privacy.rules"

    private let stored: SettingsValue<PrivacyRules>
    private let pauseStore: PauseStore

    public init(storage: any SettingsStorage, now: @escaping @Sendable () -> Date = { Date() }) {
        stored = SettingsValue(key: Self.storageKey, default: PrivacyRules(), storage: storage)
        pauseStore = PauseStore(storage: storage, now: now)
        stored.onChange { [weak self] _ in self?.announce() }
    }

    /// Everything §S1 step 1–3 needs, with the pause as it stands this instant.
    public var rules: PrivacyRules {
        var rules = stored.value
        rules.pause = pauseStore.current
        return rules
    }

    /// What `PrivacyGate` and `DestinationVerifier` are built with. A closure rather than a value, so
    /// that a setting changed now is in force at the next attempt (architecture §4.4).
    public var reader: @Sendable () -> PrivacyRules {
        { self.rules }
    }

    public var isPaused: Bool { pauseStore.isPaused() }
    public var pause: PauseState { pauseStore.current }

    // MARK: Writing

    public var appearAutomatically: Bool { stored.value.appearAutomatically }

    public func setAppearAutomatically(_ on: Bool) {
        mutate { $0.appearAutomatically = on }
    }

    /// ACT-17a. Never reading an app's text is a different setting from staying out of its way, and this
    /// is the one that cannot be overridden by any route.
    public func setHardBlocked(_ blocked: Bool, forApp bundleID: String) {
        mutate { rules in
            if blocked {
                rules.hardBlockedApps.insert(bundleID)
            } else {
                rules.hardBlockedApps.remove(bundleID)
            }
        }
    }

    /// An appearance exclusion is `.hotkeyOnly` (ALM-8's P0 half): the bar stays away and the shortcut
    /// still works. `.automatic` is the default and is stored as the absence of an entry, so that the
    /// rules value keeps the shape a fresh install has.
    public func setMode(_ mode: AppActivationMode, forApp bundleID: String) {
        mutate { rules in
            if mode == .automatic {
                rules.appModes[bundleID] = nil
            } else {
                rules.appModes[bundleID] = mode
            }
        }
    }

    // MARK: The menu's three pause commands (ACT-18)

    public func pauseForOneHour() { changePause { pauseStore.pauseForOneHour() } }
    public func pauseUntilResumed() { changePause { pauseStore.pauseUntilResumed() } }
    public func resume() { changePause { pauseStore.resume() } }

    /// Called whenever anything above changes, including a pause, with the rules as they now stand.
    ///
    /// One hook for both stores is the point: what listens is the machinery that has to *act* on a
    /// change — a bar that a new pause has to take away (ACT-16a), an attempt in flight, an invocation
    /// that has to be invalidated (RUN-3) — and none of that cares which key moved.
    public func onChange(_ body: @escaping @Sendable (PrivacyRules) -> Void) {
        observers.withLock { $0.append(body) }
    }

    private let observers = Mutex<[@Sendable (PrivacyRules) -> Void]>([])

    /// Every write goes through here, and every write puts the pause back to `.running` before it is
    /// encoded. Nothing above sets it, so this holds a property rather than fixing a bug: the pause in
    /// this key would be a second copy of `PauseStore`'s, and a second copy is one to read by mistake.
    private func mutate(_ change: (inout PrivacyRules) -> Void) {
        stored.update { rules in
            change(&rules)
            rules.pause = .running
        }
    }

    private func changePause(_ change: () -> Void) {
        change()
        announce()
    }

    private func announce() {
        let rules = rules
        for observer in observers.withLock({ $0 }) { observer(rules) }
    }
}
