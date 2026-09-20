import Foundation
import PappuCore

/// Everything one harness run produced. This is the on-disk format under `Tests/results/`.
///
/// Bump `schema` on any change a reader would trip over; M6 compares results across releases.
public struct RunResult: Sendable, Equatable, Codable {
    public static let currentSchema = 1

    public var schema: Int
    /// Stable identifier of the experiment, for example `spike-2-taps`. Also the results sub-directory.
    public var runID: String
    public var title: String
    /// The question the run answers, quoted from the plan so a result file stands on its own.
    public var question: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var environment: HarnessEnvironment
    /// The budgets the run was judged against.
    public var budgets: BudgetTable
    /// Free-form knobs: sample counts, which optional tests ran, the TCC state the operator set up.
    public var parameters: [String: String]
    public var measurements: [Measurement]
    public var findings: [Finding]
    public var log: [String]
    /// Written by the operator after the run.
    public var notes: String

    public init(
        schema: Int = RunResult.currentSchema,
        runID: String,
        title: String,
        question: String,
        startedAt: Date,
        durationSeconds: Double,
        environment: HarnessEnvironment,
        budgets: BudgetTable,
        parameters: [String: String],
        measurements: [Measurement],
        findings: [Finding],
        log: [String],
        notes: String
    ) {
        self.schema = schema
        self.runID = runID
        self.title = title
        self.question = question
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.environment = environment
        self.budgets = budgets
        self.parameters = parameters
        self.measurements = measurements
        self.findings = findings
        self.log = log
        self.notes = notes
    }
}
