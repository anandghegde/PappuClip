import Foundation

/// Where PappuClip stands with the Accessibility grant (ONB-1, ONB-4, architecture §13).
///
/// Two facts make it, and both are needed. `AXIsProcessTrusted` answers whether the user has ticked
/// the box; creating a tap answers whether the box means anything. They come apart after a macOS
/// upgrade or a rebuild, when the trust database still holds an entry for a signature the binary no
/// longer has: the app is listed, looks granted, and every tap is refused. That is ONB-4's "stale
/// grant", and it is a different thing to tell the user than "please grant Accessibility", because the
/// tick they can see is already there.
public enum AccessibilityGrant: String, Sendable, Equatable, Codable, CaseIterable {
    /// Not trusted. The ordinary first-run state, and the one ONB-1 is about.
    case notTrusted
    /// Trusted, and nothing has tried to create a tap yet. Not a problem — just not yet an answer.
    case untested
    /// Trusted, and the tap was created. Everything works.
    case working
    /// Trusted, and the tap was refused anyway (ONB-4).
    case stale

    public init(isTrusted: Bool, tapWasCreated: Bool?) {
        guard isTrusted else {
            self = .notTrusted
            return
        }
        switch tapWasCreated {
        case .some(true): self = .working
        case .some(false): self = .stale
        case .none: self = .untested
        }
    }

    /// Whether the automatic path can work at all. The shortcut does not need this — that is the whole
    /// point of `RegisterEventHotKey` (ACT-19, architecture §4.1) — so a `false` here means "no bar on
    /// selection", not "nothing works".
    public var permitsTheAutomaticPath: Bool {
        switch self {
        case .working, .untested: true
        case .notTrusted, .stale: false
        }
    }
}

/// ONB-1's first run, as a value: which screen the user is owed, and what closes it.
///
/// The two inputs are stored settings and live observation, and keeping the rule here rather than
/// inside a SwiftUI view is what makes "detect the grant live" testable: a granted permission is a
/// change of `grant`, and the assertion is that the screen goes away by itself.
public struct OnboardingState: Sendable, Equatable {
    public enum Screen: String, Sendable, Equatable, Codable, CaseIterable {
        /// What the app does, and the button that asks for the grant. Shown once ever.
        case welcome
        /// The explanation is done, the grant is not. A direct link to the right System Settings pane.
        case permission
        /// Trusted and refused: the grant has to be removed and re-added (ONB-4, P1, M6). This build
        /// recognises the state and says so; the guided repair is M6's.
        case repair
        /// Nothing owed.
        case none
    }

    /// Stored, so that a second launch does not repeat the explanation.
    public var hasBeenWelcomed: Bool
    public var grant: AccessibilityGrant

    public init(hasBeenWelcomed: Bool = false, grant: AccessibilityGrant = .notTrusted) {
        self.hasBeenWelcomed = hasBeenWelcomed
        self.grant = grant
    }

    public var screen: Screen {
        // First run explains itself whatever the grant says. A user reinstalling over an old grant is
        // still owed the sentence about what the app does, and the welcome screen shows the state of
        // the permission rather than asking again for one that is already there.
        guard hasBeenWelcomed else { return .welcome }
        switch grant {
        case .notTrusted: return .permission
        case .stale: return .repair
        case .working, .untested: return .none
        }
    }

    /// ONB-1's "detect the grant live": the window that is *asking* for the permission closes itself
    /// when it arrives, rather than leaving a Done button for something already done. The welcome
    /// screen does not, because the user has not finished reading it.
    public var closesItself: Bool { screen == .none }
}
