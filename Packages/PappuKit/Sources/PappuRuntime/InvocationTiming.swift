import Foundation

/// The invocation's own numbers (safety spec §S3, architecture §8).
///
/// Apart from `BudgetTable`, which holds the targets for the *stages of an attempt* — the same number
/// everywhere, retuned by M0 as one table. These are the shape of one invocation, and the quiescence
/// window in particular is a safety limit rather than a latency target: it says how long "the user has
/// not touched anything" stays good enough to paste on.
///
/// Whole milliseconds, like the other two tables, so a report and the code read the same.
public struct InvocationTiming: Sendable, Equatable, Codable {
    /// How long after the snapshot a quiescence-verified destination stays verified (RUN-2g).
    ///
    /// Three seconds is the safety spec's initial value, and it is the *ceiling* on the tier, not a
    /// target: the epoch check is what actually says nobody has typed, and this bounds how long that
    /// evidence is trusted when something happened that no tap can see — a window closing under a
    /// script, an app redrawing itself.
    public var quiescenceWindowMs: Int
    /// How long `cancel` waits for owned work to stop before it stops waiting and says so (RUN-3d).
    /// It never waits for a delegated action: those are asked to cancel and reported as possibly
    /// complete (RUN-3e).
    public var cancellationGraceMs: Int

    public init(quiescenceWindowMs: Int, cancellationGraceMs: Int) {
        self.quiescenceWindowMs = quiescenceWindowMs
        self.cancellationGraceMs = cancellationGraceMs
    }

    /// Safety spec §S3. **Provisional**: the window is the spec's initial value and M0 spike 6's
    /// `live` run has not been made, so no measurement stands behind it yet.
    public static let initial = InvocationTiming(quiescenceWindowMs: 3_000, cancellationGraceMs: 2_000)

    public var quiescenceWindow: Duration { .milliseconds(quiescenceWindowMs) }
    public var cancellationGrace: Duration { .milliseconds(cancellationGraceMs) }
}
