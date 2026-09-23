import Foundation

/// The outcome of §S1. A permit or a reason; there is no third case and no way to build either from
/// outside this module.
public enum PrivacyDecision: ~Copyable, Sendable {
    case permitted(ReadPermit)
    case denied(PrivacyDenial)

    public var isPermitted: Bool {
        switch self {
        case .permitted: true
        case .denied: false
        }
    }

    /// The refusal, for the message and the inspector. `nil` when the read was allowed.
    public var denial: PrivacyDenial? {
        switch self {
        case .permitted: nil
        case .denied(let denial): denial
        }
    }

    /// Takes the permit out, ending the decision. The reader is meant to consume it straight away.
    public consuming func permit() -> ReadPermit? {
        switch consume self {
        case .permitted(let permit): permit
        case .denied: nil
        }
    }
}

/// Safety spec §S1: the one gate every activation route passes before any text is read
/// (architecture §4.4, ACT-12, ACT-17a, ACT-18).
///
/// It judges, it does not look: secure input and the focused element's role are read by the caller and
/// handed in, and the rules come from settings through a closure so that a change takes effect on the
/// next attempt rather than at the next launch.
///
/// The gate lives beside the permit it mints rather than in PappuSelection with the strategies,
/// because `ReadPermit.init` is internal and `ContextProbe` and `BrowserMetadata` (PappuAnalysis) need
/// the permit without depending on PappuSelection.
public struct PrivacyGate: Sendable {
    private let rules: @Sendable () -> PrivacyRules
    private let now: @Sendable () -> Date

    public init(
        rules: @escaping @Sendable () -> PrivacyRules,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rules = rules
        self.now = now
    }

    /// Fixed rules, for tests and for callers that have just read them.
    public init(_ rules: PrivacyRules, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(rules: { rules }, now: now)
    }

    public func evaluate(
        route: ActivationRoute,
        target: TargetApp,
        secureInput: SecureInputState
    ) -> PrivacyDecision {
        evaluate(route: route, target: target, secureInput: secureInput, through: .activationMode)
    }

    /// The recheck before a host-controlled effect: steps 1 and 2, and no more (RUN-2f).
    ///
    /// The safety spec names those two steps and stops there, and the omission is the point. Step 3 is
    /// the appearance settings, which have nothing to say at execution time: the user has just clicked
    /// a button on a bar that is already on screen, and "do not appear automatically in this app" is not
    /// an answer to them. Where the bar came from was settled when it appeared. Steps 1 and 2 are the
    /// two that can have *become* true since — secure input turned on, the app hard-blocked, pause
    /// started — and neither has an exception for any route (ACT-5, ACT-12, ACT-17a, ACT-18).
    ///
    /// The permit it mints is what the destination re-read spends: asking whether the selection is
    /// still the one the action was invoked on means reading it again, and no read happens without a
    /// permit (architecture §3.1). The route it carries is the invocation's own, for the trace.
    public func evaluateAtExecution(
        route: ActivationRoute,
        target: TargetApp,
        secureInput: SecureInputState
    ) -> PrivacyDecision {
        evaluate(route: route, target: target, secureInput: secureInput, through: .hardBlockAndPause)
    }

    /// - Parameter through: The last step to run. `PrivacyStep` is ordered, and every caller either
    ///   runs the lot (an activation) or stops after step 2 (an execution recheck).
    private func evaluate(
        route: ActivationRoute,
        target: TargetApp,
        secureInput: SecureInputState,
        through: PrivacyStep
    ) -> PrivacyDecision {
        let rules = rules()
        let mode = rules.mode(for: target.bundleID)
        var cleared: [PrivacyStep] = []

        func trace() -> PrivacyTrace {
            PrivacyTrace(route: route, target: target, mode: mode, cleared: cleared)
        }
        func deny(_ reason: PrivacyDenialReason) -> PrivacyDecision {
            .denied(PrivacyDenial(reason: reason, trace: trace()))
        }

        // 1. Secure input (ACT-12). First because nothing overrides it, and because it is the check
        //    that can have become true since mouse-down.
        if secureInput.systemWide { return deny(.secureInputActive) }
        if secureInput.focusedFieldIsSecure { return deny(.secureTextField) }
        cleared.append(.secureInput)

        // 2. Hard blocks and pause (ACT-17a, ACT-18). Before any read, and again at execution time
        //    (RUN-2f). No route passes these, the shortcut and scripts included (ACT-5).
        if rules.isHardBlocked(target.bundleID) { return deny(.appHardBlocked) }
        switch rules.pause.settled(at: now()) {
        case .untilResumed: return deny(.pausedUntilResumed)
        case .until: return deny(.pausedUntilExpiry)
        case .running: break
        }
        cleared.append(.hardBlockAndPause)

        guard through > .hardBlockAndPause else {
            return .permitted(ReadPermit(route: route, target: target, scope: .fullText, trace: trace()))
        }

        // 3. Activation mode. A deliberate route passes: the user has just asked for the bar in this
        //    app, so "don't appear here" is not an answer to them. Off means off for everyone.
        if mode == .off { return deny(.appTurnedOff) }
        if !route.isDeliberate {
            if mode == .hotkeyOnly { return deny(.appearanceExcluded) }
            if !rules.appearAutomatically { return deny(.appearAutomaticallyOff) }
        }
        cleared.append(.activationMode)

        return .permitted(ReadPermit(route: route, target: target, scope: .fullText, trace: trace()))
    }
}
