import Foundation

/// What PappuClip may do in one app (ALM-8).
///
/// An appearance exclusion is `hotkeyOnly`: the bar stays away, the shortcut still works (ACT-5).
/// `off` is the third choice the per-app settings add in 1.0; nothing in the app sets it yet.
public enum AppActivationMode: String, Sendable, Codable, CaseIterable {
    case automatic
    case hotkeyOnly
    case off
}

/// The user's privacy and appearance settings, as the gate reads them.
///
/// Hard blocks are not exclusions, and the difference is the whole of ACT-17a: an excluded app is one
/// the bar stays out of, a hard-blocked app is one whose text is never read, by any route, ever.
public struct PrivacyRules: Sendable, Equatable, Codable {
    /// PRD §7.1's "Appear automatically" toggle. Off leaves every deliberate route working.
    public var appearAutomatically: Bool
    /// **Never read text here** (ACT-17a), by bundle identifier.
    public var hardBlockedApps: Set<String>
    public var appModes: [String: AppActivationMode]
    public var pause: PauseState

    public init(
        appearAutomatically: Bool = true,
        hardBlockedApps: Set<String> = [],
        appModes: [String: AppActivationMode] = [:],
        pause: PauseState = .running
    ) {
        self.appearAutomatically = appearAutomatically
        self.hardBlockedApps = hardBlockedApps
        self.appModes = appModes
        self.pause = pause
    }

    /// A process with no bundle identifier — a helper tool, something started from a shell — cannot be
    /// named in a rule, so it takes the default mode. Secure input still covers it.
    public func mode(for bundleID: String?) -> AppActivationMode {
        bundleID.flatMap { appModes[$0] } ?? .automatic
    }

    public func isHardBlocked(_ bundleID: String?) -> Bool {
        bundleID.map(hardBlockedApps.contains) ?? false
    }
}
