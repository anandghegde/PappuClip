import Foundation
import PappuCore

/// What the user's settings take away from a detection policy. A ceiling, never a grant.
///
/// Each entry is a sparse `DetectionPolicyRecord`, and `DetectionPolicyStore` spends it by applying
/// it **to the policy it is about to restrict** and then merging the two restrictively. So a field
/// the user left alone is the policy's own value and cancels out, and a field set more permissively
/// than the bundled policy also cancels out, because the merge keeps the smaller side. There is no
/// spelling of a ceiling that switches something on — that is a property of the arithmetic, not a
/// convention the settings screen has to remember (SEC-9, RUN-2h).
public struct DetectionCeilings: Sendable, Equatable, Codable {
    /// Applies to every app: the global "never simulate ⌘C" kind of switch.
    public var global: DetectionPolicyRecord
    /// By bundle identifier, on top of `global`.
    public var apps: [String: DetectionPolicyRecord]

    public init(global: DetectionPolicyRecord = .init(), apps: [String: DetectionPolicyRecord] = [:]) {
        self.global = global
        self.apps = apps
    }

    public static let none = DetectionCeilings()
}

/// The effective detection policy for an app (architecture §4.6, ACT-11a).
///
/// Bundled data first, then the user's ceilings. From M5 a signed remote document replaces the
/// bundled one (ACT-11b) and the ceilings still apply after it, which is what makes "a remote policy
/// that tries to enable synthetic copy for a user-restricted app has no effect" true by construction
/// rather than by review (SEC-9, RUN-2h).
///
/// Both sides arrive through closures, as `PrivacyGate`'s rules do, so a change in settings applies
/// to the next attempt rather than at the next launch. The lookup is on the latency path — it runs at
/// mouse-down, off the budget (architecture §4.3) — and is a pure function over two values.
public struct DetectionPolicyStore: Sendable {
    private let policies: @Sendable () -> DetectionPolicies
    private let ceilings: @Sendable () -> DetectionCeilings

    public init(
        policies: @escaping @Sendable () -> DetectionPolicies,
        ceilings: @escaping @Sendable () -> DetectionCeilings = { .none }
    ) {
        self.policies = policies
        self.ceilings = ceilings
    }

    /// Fixed data, for tests and for callers that have just read it.
    public init(_ policies: DetectionPolicies, ceilings: DetectionCeilings = .none) {
        self.init(policies: { policies }, ceilings: { ceilings })
    }

    public func policy(for bundleID: String?) -> DetectionPolicy {
        let ceilings = ceilings()
        var policy = policies().policy(for: bundleID)
        policy = policy.restricted(by: ceilings.global.applied(to: policy))
        if let bundleID, let app = ceilings.apps[bundleID] {
            policy = policy.restricted(by: app.applied(to: policy))
        }
        return policy
    }

    /// The overload the coordinator uses: a permit and an attempt name a process, not an identifier.
    public func policy(for target: TargetApp) -> DetectionPolicy {
        policy(for: target.bundleID)
    }
}
