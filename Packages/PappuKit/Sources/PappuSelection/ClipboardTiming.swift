import Foundation

/// How long each part of a clipboard transaction is allowed to take (architecture §5, PRD §11.1).
///
/// These are *not* in `BudgetTable`. A budget is a target for a stage of an attempt and the same number
/// everywhere; these are the shape of one transaction, and the two per-app knobs here move in opposite
/// directions — a longer settle is safer and a longer drain is riskier for the next attempt — so they
/// cannot go in `DetectionPolicy`, where every field has to be monotone for `restricted(by:)` to mean
/// what SEC-9 says it means. `CopyDelta` is the one clipboard value that *is* monotone, and that is the
/// one that lives in the policy.
///
/// Whole milliseconds, like `BudgetTable`, so a report and the code read the same.
public struct ClipboardTiming: Sendable, Equatable, Codable {
    /// How long to wait for the change count to move after the synthetic ⌘C. The transaction gives up
    /// and reports that nothing was copied when it does not.
    public var windowMs: Int
    /// After the count has moved, how long to wait for a text type to appear on the pasteboard. The
    /// count moves on the *clear*, so at the moment it moves there may be nothing there yet: M0 spike 6
    /// measured 0.14–0.28 ms between the two at p50, and no bound at all for a slow writer.
    public var textWaitMs: Int
    /// After the expected delta is reached, how long the count must stay still before the change is
    /// attributed to us. This is half of the answer to spike 6's first-writer hole.
    public var settleMs: Int
    /// The settle to use when a clipboard manager is running (ACT-10i). Longer, because a manager reads
    /// and sometimes rewrites after every copy, so the pasteboard is busier and a quiet 30 ms says less.
    public var managerSettleMs: Int
    /// After the transaction has answered, how long to keep watching the pasteboard for a copy that
    /// arrived late. Spike 6 is explicit that this cannot be made complete: a copy after any finite
    /// drain is a hole, and this number only decides how big it is.
    public var drainMs: Int
    /// How often to look at the change count. One millisecond: a `changeCount` read is 0.0006 ms at p95
    /// and is not a round trip, so the poll costs less than the timer that would replace it.
    public var pollMs: Int
    /// The least window worth opening. Below it the transaction would post a ⌘C it has no time to see
    /// the result of, which is the one outcome worse than no bar: the user's clipboard replaced and
    /// nothing to show for it.
    public var minimumWindowMs: Int
    /// How long the snapshot may take before the read is abandoned and the transaction skipped. Above a
    /// lazy provider it is unbounded, which is the whole reason this number exists.
    public var snapshotMs: Int
    /// How long an action's result stays on the user's clipboard after the ⌘V has been posted (RUN-4).
    ///
    /// The one number in this file that nothing can measure for us. A paste leaves no trace on the
    /// pasteboard — no count moves, no type appears — so there is no signal that says the app has taken
    /// it, and the hold is a guess in both directions: too short and the app pastes the user's own
    /// clipboard back over their selection, too long and the user's clipboard is missing for longer
    /// than it needs to be. Spike 6's `live` run is what turns this into a measurement.
    public var holdMs: Int
    /// How much of the user's clipboard the broker will hold a second copy of. Not a time limit —
    /// 50 MB round-trips in about 35 ms — but a memory one.
    public var ceilingBytes: Int

    public init(
        windowMs: Int,
        textWaitMs: Int,
        settleMs: Int,
        managerSettleMs: Int,
        drainMs: Int,
        pollMs: Int,
        minimumWindowMs: Int,
        snapshotMs: Int,
        holdMs: Int,
        ceilingBytes: Int
    ) {
        self.windowMs = windowMs
        self.textWaitMs = textWaitMs
        self.settleMs = settleMs
        self.managerSettleMs = managerSettleMs
        self.drainMs = drainMs
        self.pollMs = pollMs
        self.minimumWindowMs = minimumWindowMs
        self.snapshotMs = snapshotMs
        self.holdMs = holdMs
        self.ceilingBytes = ceilingBytes
    }

    /// Provisional, and provisional in a way worth naming: M0 spike 6 measured the pasteboard against a
    /// *private* pasteboard and a cooperating writer, and its `live` option — a real app, a real ⌘C —
    /// has not been run. The window and the settle are the two numbers that run will change.
    ///
    /// They fit: 120 snapshot + 180 window + 40 text + 30 settle is 370 ms, over the 270 ms read stage,
    /// which is why `ClipboardBroker` sizes the window from what is actually left rather than from
    /// `windowMs`, and refuses when what is left cannot pay for the text wait, the settle and
    /// `minimumWindowMs`.
    public static let initial = ClipboardTiming(
        windowMs: 180,
        textWaitMs: 40,
        settleMs: 30,
        managerSettleMs: 90,
        drainMs: 400,
        pollMs: 1,
        minimumWindowMs: 30,
        snapshotMs: 120,
        holdMs: 120,
        ceilingBytes: 50 * 1_024 * 1_024
    )

    public var window: Duration { .milliseconds(windowMs) }
    public var textWait: Duration { .milliseconds(textWaitMs) }
    public var drain: Duration { .milliseconds(drainMs) }
    public var poll: Duration { .milliseconds(pollMs) }
    public var minimumWindow: Duration { .milliseconds(minimumWindowMs) }
    public var snapshot: Duration { .milliseconds(snapshotMs) }
    public var hold: Duration { .milliseconds(holdMs) }

    public func settle(managerIsRunning: Bool) -> Duration {
        .milliseconds(managerIsRunning ? managerSettleMs : settleMs)
    }

    /// What the window may be, given the clock: everything left of the read stage once the settle and
    /// the text wait are set aside. Negative when there is not enough, which is `minimumWindow`'s cue.
    public func window(within remaining: Duration, managerIsRunning: Bool) -> Duration {
        Swift.min(window, remaining - textWait - settle(managerIsRunning: managerIsRunning))
    }
}
