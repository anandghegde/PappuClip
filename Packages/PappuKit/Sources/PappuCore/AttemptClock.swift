/// The one monotonic clock of a selection attempt (architecture §3.3, PRD §11.1).
///
/// It starts at mouse-up, or at the hotkey press, and is never restarted: a fallback strategy inherits
/// the time earlier strategies spent. Budgets are targets; only the hard cutoff stops a bar from showing.
public struct AttemptClock: Sendable {
    public enum Scope: Sendable, Equatable {
        /// Until the end of one stage, counted from the start of the attempt.
        case stage(BudgetStage)
        /// Until the p95 target for the whole path.
        case targetBudget
    }

    public let start: ContinuousClock.Instant
    public let budgets: BudgetTable
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - start: Pass the event's own time when it is known, so queueing delay counts against the budget.
    ///   - now: Replaced by tests; see `ManualTimeSource` in PappuTestSupport.
    public init(
        budgets: BudgetTable = .initial,
        start: ContinuousClock.Instant? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.budgets = budgets
        self.now = now
        self.start = start ?? now()
    }

    public var elapsed: Duration { start.duration(to: now()) }

    /// Time left in `scope`, never negative. Zero means the work should be skipped or cut short, not
    /// that the attempt is dead; `isPastHardCutoff` decides that.
    public func remaining(in scope: Scope, on path: DetectionPath) -> Duration {
        let deadline: Duration = switch scope {
        case .stage(let stage): budgets.deadline(through: stage, on: path)
        case .targetBudget: budgets.targetBudget(on: path)
        }
        return max(.zero, deadline - elapsed)
    }

    /// Population is always skipped once the target budget is spent, so a late bar is a static bar (PRD §11.1).
    public func isPastTargetBudget(on path: DetectionPath) -> Bool {
        elapsed >= budgets.targetBudget(on: path)
    }

    public var isPastHardCutoff: Bool { elapsed >= budgets.hardCutoff }
}
