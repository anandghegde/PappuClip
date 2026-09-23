import Foundation

/// The steps of safety spec §S1, in the order the gate runs them. Step 4, action filtering, happens
/// after the read and belongs to the matching pipeline (extension spec §8.5).
public enum PrivacyStep: Int, Sendable, Codable, CaseIterable, Comparable {
    case secureInput = 1
    case hardBlockAndPause = 2
    case activationMode = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a read was refused: one code per rule.
///
/// These are the vocabulary of the bar's message (BAR-13), the shortcut's explanation (ACT-18) and the
/// "Why didn't it appear?" inspector (DIA-2). A reason is a code and nothing else, so no denial can
/// carry a word of what the user had selected.
public enum PrivacyDenialReason: String, Sendable, Codable, CaseIterable {
    case secureInputActive
    case secureTextField
    case appHardBlocked
    case pausedUntilResumed
    case pausedUntilExpiry
    case appearanceExcluded
    case appearAutomaticallyOff
    case appTurnedOff

    public var step: PrivacyStep {
        switch self {
        case .secureInputActive, .secureTextField: .secureInput
        case .appHardBlocked, .pausedUntilResumed, .pausedUntilExpiry: .hardBlockAndPause
        case .appearanceExcluded, .appearAutomaticallyOff, .appTurnedOff: .activationMode
        }
    }
}

/// What the gate looked at, kept by both outcomes for the inspector (DIA-2).
///
/// Everything in it is a code, a process identifier or a bundle identifier. There is no field a
/// selection could be written into.
public struct PrivacyTrace: Sendable, Equatable, Codable {
    public let route: ActivationRoute
    public let target: TargetApp
    public let mode: AppActivationMode
    /// The steps that passed, in order. An activation permit's trace holds all three; an execution
    /// recheck's holds the first two, because RUN-2f asks for those two and stops.
    public let cleared: [PrivacyStep]

    init(route: ActivationRoute, target: TargetApp, mode: AppActivationMode, cleared: [PrivacyStep]) {
        self.route = route
        self.target = target
        self.mode = mode
        self.cleared = cleared
    }
}

/// A refusal, with the rule that produced it.
public struct PrivacyDenial: Sendable, Equatable, Codable, Error {
    public let reason: PrivacyDenialReason
    public let trace: PrivacyTrace

    public var step: PrivacyStep { reason.step }

    init(reason: PrivacyDenialReason, trace: PrivacyTrace) {
        self.reason = reason
        self.trace = trace
    }
}
