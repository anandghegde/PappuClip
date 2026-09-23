import Foundation

/// Pause as the menu bar offers it: for one hour, until resumed, or not at all (ACT-18).
///
/// A timed pause is an absolute date rather than a countdown, so quitting the app does not end it and
/// relaunching does not restart it. Nothing schedules a timer: the state settles when it is read.
public enum PauseState: Sendable, Equatable, Codable {
    case running
    case untilResumed
    case until(Date)

    public static let oneHour: TimeInterval = 60 * 60

    public static func forOneHour(from now: Date) -> PauseState { .until(now + oneHour) }

    public func isPaused(at now: Date) -> Bool {
        switch self {
        case .running: false
        case .untilResumed: true
        case .until(let expiry): now < expiry
        }
    }

    /// The same state with a spent expiry turned back into `.running`, so the gate and the menu read
    /// one value and agree about it.
    public func settled(at now: Date) -> PauseState {
        isPaused(at: now) ? self : .running
    }
}
