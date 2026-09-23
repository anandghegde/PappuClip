import Foundation
import PappuCore
import PappuTestSupport
import Testing

private let safari = TargetApp(pid: 501, bundleID: "com.apple.Safari")
private let bank = TargetApp(pid: 502, bundleID: "com.bank.Vault")
private let unnamed = TargetApp(pid: 503, bundleID: nil)

private let secureInputOn = SecureInputState(systemWide: true, focusedFieldIsSecure: false)
private let passwordField = SecureInputState(systemWide: false, focusedFieldIsSecure: true)
private let noon = Date(timeIntervalSince1970: 1_800_000_000)

/// A decision reduced to copyable parts, because a `#expect` cannot hold a `~Copyable` value.
private struct Outcome {
    var denial: PrivacyDenial?
    var route: ActivationRoute?
    var target: TargetApp?
    var scope: ReadScope?
    var trace: PrivacyTrace

    init(_ decision: consuming PrivacyDecision) {
        switch consume decision {
        case .permitted(let permit):
            route = permit.route
            target = permit.target
            scope = permit.scope
            trace = permit.trace
        case .denied(let denial):
            self.denial = denial
            trace = denial.trace
        }
    }

    var reason: PrivacyDenialReason? { denial?.reason }
    var isPermitted: Bool { denial == nil }
}

private func decide(
    _ rules: PrivacyRules,
    route: ActivationRoute = .automatic,
    target: TargetApp = safari,
    secureInput: SecureInputState = .clear,
    now: Date = noon
) -> Outcome {
    Outcome(PrivacyGate(rules, now: { now }).evaluate(route: route, target: target, secureInput: secureInput))
}

/// The same rules put to every route, which is how most of §S1 is stated.
private func everyRoute(
    _ rules: PrivacyRules,
    target: TargetApp = safari,
    secureInput: SecureInputState = .clear,
    now: Date = noon
) -> [ActivationRoute: PrivacyDenialReason?] {
    ActivationRoute.allCases.reduce(into: [:]) { result, route in
        result[route] = decide(rules, route: route, target: target, secureInput: secureInput, now: now).reason
    }
}

/// The recheck before a host-controlled effect (RUN-2f), reduced the same way.
private func recheck(
    _ rules: PrivacyRules,
    route: ActivationRoute = .automatic,
    target: TargetApp = safari,
    secureInput: SecureInputState = .clear,
    now: Date = noon
) -> Outcome {
    Outcome(
        PrivacyGate(rules, now: { now })
            .evaluateAtExecution(route: route, target: target, secureInput: secureInput)
    )
}

/// Safety spec §S1: the precedence, case by case, from every route.
@Suite struct PrivacyGateTests {
    // MARK: Step 1 — secure input (ACT-12)

    @Test func secureInputRefusesEveryRoute() {
        for (route, reason) in everyRoute(PrivacyRules(), secureInput: secureInputOn) {
            #expect(reason == .secureInputActive, "\(route) read under secure input")
        }
        for (route, reason) in everyRoute(PrivacyRules(), secureInput: passwordField) {
            #expect(reason == .secureTextField, "\(route) read a password field")
        }
    }

    @Test func secureInputIsAnsweredBeforeAnyOtherRule() {
        let rules = PrivacyRules(
            appearAutomatically: false,
            hardBlockedApps: [bank.bundleID!],
            appModes: [bank.bundleID!: .off],
            pause: .untilResumed
        )
        let outcome = decide(rules, route: .hotkey, target: bank, secureInput: secureInputOn)
        #expect(outcome.reason == .secureInputActive)
        #expect(outcome.denial?.step == .secureInput)
        #expect(outcome.trace.cleared.isEmpty)
    }

    // MARK: Step 2 — hard blocks and pause (ACT-17a, ACT-18, ACT-5)

    @Test func aHardBlockedAppRefusesEveryRouteIncludingTheShortcut() {
        let rules = PrivacyRules(hardBlockedApps: [bank.bundleID!])
        for (route, reason) in everyRoute(rules, target: bank) {
            #expect(reason == .appHardBlocked, "\(route) was let through a hard block")
        }
        // The rule names one app, not every app.
        for (route, reason) in everyRoute(rules, target: safari) {
            #expect(reason == PrivacyDenialReason?.none, "\(route) was blocked in the wrong app")
        }
    }

    @Test func pauseRefusesEveryRouteIncludingTheShortcut() {
        for (route, reason) in everyRoute(PrivacyRules(pause: .untilResumed)) {
            #expect(reason == .pausedUntilResumed, "\(route) ran while paused")
        }
        for (route, reason) in everyRoute(PrivacyRules(pause: .forOneHour(from: noon))) {
            #expect(reason == .pausedUntilExpiry, "\(route) ran while paused")
        }
    }

    /// A timed pause ends by itself: no timer, and nothing to resume it (ACT-18).
    @Test func aPauseThatHasRunOutStopsRefusing() {
        let rules = PrivacyRules(pause: .forOneHour(from: noon))
        #expect(decide(rules, now: noon + PauseState.oneHour - 1).reason == .pausedUntilExpiry)
        #expect(decide(rules, now: noon + PauseState.oneHour).isPermitted)
    }

    @Test func aHardBlockIsAnsweredBeforeTheActivationMode() {
        let rules = PrivacyRules(
            appearAutomatically: false,
            hardBlockedApps: [bank.bundleID!],
            appModes: [bank.bundleID!: .off]
        )
        let outcome = decide(rules, target: bank)
        #expect(outcome.reason == .appHardBlocked)
        #expect(outcome.trace.cleared == [.secureInput])
    }

    // MARK: Step 3 — activation mode (ACT-5, ALM-8)

    @Test func theShortcutPassesAnAppearanceExclusionThatStopsTheBar() {
        let byRoute = everyRoute(PrivacyRules(appModes: [safari.bundleID!: .hotkeyOnly]))
        #expect(byRoute[.automatic] == .appearanceExcluded)
        for route in ActivationRoute.allCases where route.isDeliberate {
            #expect(byRoute[route] == PrivacyDenialReason?.none, "\(route) was stopped by an appearance exclusion")
        }
    }

    @Test func turningAppearAutomaticallyOffLeavesTheShortcutWorking() {
        let byRoute = everyRoute(PrivacyRules(appearAutomatically: false))
        #expect(byRoute[.automatic] == .appearAutomaticallyOff)
        for route in ActivationRoute.allCases where route.isDeliberate {
            #expect(byRoute[route] == PrivacyDenialReason?.none, "\(route) was stopped by the global toggle")
        }
    }

    @Test func anAppTurnedOffRefusesTheShortcutToo() {
        for (route, reason) in everyRoute(PrivacyRules(appModes: [safari.bundleID!: .off])) {
            #expect(reason == .appTurnedOff, "\(route) ran in an app that is switched off")
        }
    }

    /// A process with no bundle identifier cannot be named in a rule, so it takes the default mode.
    /// Lest that read as a way around a block: the rules that do not name an app still apply to it.
    @Test func aProcessWithNoBundleIdentifierTakesTheDefaultMode() {
        let named = PrivacyRules(hardBlockedApps: [bank.bundleID!], appModes: [bank.bundleID!: .off])
        #expect(decide(named, target: unnamed).isPermitted)
        #expect(decide(named, target: unnamed, secureInput: secureInputOn).reason == .secureInputActive)
        #expect(decide(PrivacyRules(pause: .untilResumed), target: unnamed).reason == .pausedUntilResumed)
        #expect(decide(PrivacyRules(appearAutomatically: false), target: unnamed).reason == .appearAutomaticallyOff)
    }

    // MARK: The recheck before an effect (RUN-2f)

    /// The two steps that can have *become* true since the bar appeared still refuse, from every
    /// route — the shortcut and a script included (ACT-5).
    @Test func theRecheckStillRefusesSecureInputAHardBlockAndAPause() {
        for route in ActivationRoute.allCases {
            #expect(recheck(PrivacyRules(), route: route, secureInput: secureInputOn).reason == .secureInputActive)
            #expect(recheck(PrivacyRules(), route: route, secureInput: passwordField).reason == .secureTextField)
            let blocked = PrivacyRules(hardBlockedApps: [bank.bundleID!])
            #expect(recheck(blocked, route: route, target: bank).reason == .appHardBlocked)
            #expect(recheck(PrivacyRules(pause: .untilResumed), route: route).reason == .pausedUntilResumed)
        }
    }

    /// And step 3 is not run. The appearance settings answer where the bar came from, which was
    /// settled when it appeared; they are not an answer to a user who has just clicked a button on it.
    @Test func theRecheckDoesNotRunTheAppearanceStep() {
        let cases: [(String, PrivacyRules)] = [
            ("appearance exclusion", PrivacyRules(appModes: [safari.bundleID!: .hotkeyOnly])),
            ("appear automatically off", PrivacyRules(appearAutomatically: false)),
            ("app turned off", PrivacyRules(appModes: [safari.bundleID!: .off])),
        ]
        for (what, rules) in cases {
            #expect(decide(rules).isPermitted == false, "\(what) let the bar appear")
            #expect(recheck(rules).isPermitted, "\(what) stopped an action already running")
        }
    }

    /// The trace says which steps it ran, so the inspector can tell an execution recheck from an
    /// activation rather than reading a permit that cleared two steps as one that cleared three.
    @Test func theRecheckSaysItClearedTwoStepsAndNotThree() {
        let outcome = recheck(PrivacyRules(), route: .hotkey)
        #expect(outcome.isPermitted)
        #expect(outcome.trace.cleared == [.secureInput, .hardBlockAndPause])
        #expect(outcome.route == .hotkey)
        #expect(outcome.scope == .fullText)
        #expect(decide(PrivacyRules(), route: .hotkey).trace.cleared == PrivacyStep.allCases)
    }

    // MARK: The permit

    @Test func aPermitNamesTheRouteTheProcessAndTheStepsItPassed() {
        let outcome = decide(PrivacyRules(), route: .hotkey)
        #expect(outcome.isPermitted)
        #expect(outcome.route == .hotkey)
        #expect(outcome.target == safari)
        #expect(outcome.scope == .fullText)
        #expect(outcome.trace.cleared == PrivacyStep.allCases)
        #expect(outcome.trace.mode == .automatic)
    }

    @Test func aRefusalCarriesNoPermit() {
        let decision = PrivacyGate(PrivacyRules(pause: .untilResumed))
            .evaluate(route: .automatic, target: safari, secureInput: .clear)
        let permitted = decision.isPermitted
        #expect(!permitted)
        guard case .none = decision.permit() else {
            Issue.record("a refusal handed out a permit")
            return
        }
    }

    /// Rules are read at each attempt, so a setting changed in the menu takes effect on the next
    /// selection rather than at the next launch.
    @Test func theGateReadsTheRulesAgainOnEveryAttempt() {
        let storage = FakeSettingsStorage()
        let pause = PauseStore(storage: storage)
        let gate = PrivacyGate(rules: { PrivacyRules(pause: pause.current) })
        func permitted() -> Bool {
            Outcome(gate.evaluate(route: .automatic, target: safari, secureInput: .clear)).isPermitted
        }
        #expect(permitted())
        pause.pauseUntilResumed()
        #expect(!permitted())
        pause.resume()
        #expect(permitted())
    }

    /// A denial is a code, a route, a pid and a bundle identifier. There is no field in it a selection
    /// could reach, and this test is what keeps it that way.
    @Test func aDenialWrittenOutHoldsNothingButCodesAndIdentifiers() throws {
        let denial = try #require(decide(PrivacyRules(hardBlockedApps: [bank.bundleID!]), target: bank).denial)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(denial)) as? [String: Any]
        #expect(written?.keys.sorted() == ["reason", "trace"])
        let trace = written?["trace"] as? [String: Any]
        #expect(trace?.keys.sorted() == ["cleared", "mode", "route", "target"])
        #expect((trace?["target"] as? [String: Any])?.keys.sorted() == ["bundleID", "pid"])
    }
}
