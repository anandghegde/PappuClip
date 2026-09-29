import Foundation
import PappuCore
import PappuSelection

/// ONB-6's M3 half: when PopClip is found running — at launch, or when it starts later — say that both
/// apps will show a bar, and offer to pause PappuClip's automatic appearance or show how to turn
/// PopClip's off.
///
/// **It never touches PopClip.** What it is given is the coexistence reading, PappuClip's own rules and
/// a way to ask the user; it has no handle on PopClip's process, preferences or scripting interface,
/// so "never quit, modify or script PopClip" holds by construction. Turning PopClip's bar off is
/// explained in words for the user to do in PopClip.
///
/// **When it speaks.** Once each time PopClip starts running, and only while "Appear automatically" is
/// on — with it off there is nothing to collide. "Don't show this again" is remembered. Synthetic copy
/// on the automatic path is withheld while PopClip runs whatever the user answers here; that is
/// `CoexistenceMonitor` and the chain's, not this.
@MainActor
public final class CoexistenceNotice {
    /// The user's answer to the explanation.
    public enum Response: Sendable, Equatable {
        case pauseAutomaticAppearance
        case showHowToTurnOffPopClip
        case keepBoth
    }

    public static let suppressedKey = "coexistence.popClip.suppressed"

    private let rules: PrivacyRulesStore
    private let suppressed: SettingsValue<Bool>
    /// Shows the explanation; answers what was chosen and whether "Don't show this again" was ticked.
    private let ask: @MainActor () async -> (Response, suppress: Bool)
    /// Shows the steps for turning PopClip's own bar off.
    private let showHowTo: @MainActor () -> Void
    private var popClipWasRunning = false
    private var asking = false

    public init(
        rules: PrivacyRulesStore,
        storage: any SettingsStorage,
        ask: @escaping @MainActor () async -> (Response, suppress: Bool),
        showHowTo: @escaping @MainActor () -> Void
    ) {
        self.rules = rules
        self.suppressed = SettingsValue(key: Self.suppressedKey, default: false, storage: storage)
        self.ask = ask
        self.showHowTo = showHowTo
    }

    /// Wires this to `monitor`. The monitor's first reading counts as "starting", so a PopClip already
    /// running at launch is explained too.
    public func observe(_ monitor: CoexistenceMonitor) {
        monitor.onChange { [weak self] coexistence in
            Task { @MainActor in await self?.note(coexistence) }
        }
        // A reading taken before this subscribed would otherwise be missed.
        let current = monitor.current
        Task { @MainActor [weak self] in await self?.note(current) }
    }

    /// One reading. Returns whether the explanation was shown, for tests.
    @discardableResult
    public func note(_ coexistence: Coexistence) async -> Bool {
        let started = coexistence.popClipIsRunning && !popClipWasRunning
        popClipWasRunning = coexistence.popClipIsRunning
        guard started, !asking, !suppressed.value, rules.appearAutomatically else { return false }
        asking = true
        defer { asking = false }
        let (response, suppress) = await ask()
        if suppress { suppressed.set(true) }
        switch response {
        case .pauseAutomaticAppearance:
            rules.setAppearAutomatically(false)
        case .showHowToTurnOffPopClip:
            showHowTo()
        case .keepBoth:
            break
        }
        return true
    }
}
