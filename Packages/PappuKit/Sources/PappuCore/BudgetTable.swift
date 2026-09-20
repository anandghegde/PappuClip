/// Which latency target an attempt is measured against (PRD §3.3).
public enum DetectionPath: String, Sendable, Codable, CaseIterable {
    /// Strategies 1–3. Target 150 ms at p95.
    case accessibility
    /// Strategies 4–5. Target 350 ms at p95, including the earlier strategy attempts.
    case clipboardFallback
}

/// The stages of PRD §11.1, in the order they run.
public enum BudgetStage: String, Sendable, Codable, CaseIterable {
    /// Gesture dispatch, privacy and context checks, and the selection read.
    case read
    /// Bounded analysis and static filtering.
    case analysis
    /// Dynamic population and IPC against a warm helper (JS-16).
    case population
    /// Layout and first visible frame.
    case render
}

/// The latency budgets of PRD §11.1 as one table of data, so M0 can retune them in one place.
///
/// Values are whole milliseconds so the table reads the same in code, in JSON results and in the PRD.
public struct BudgetTable: Sendable, Equatable, Codable {
    public struct Stages: Sendable, Equatable, Codable {
        public var readMs: Int
        public var analysisMs: Int
        public var populationMs: Int
        public var renderMs: Int

        public init(readMs: Int, analysisMs: Int, populationMs: Int, renderMs: Int) {
            self.readMs = readMs
            self.analysisMs = analysisMs
            self.populationMs = populationMs
            self.renderMs = renderMs
        }

        func milliseconds(for stage: BudgetStage) -> Int {
            switch stage {
            case .read: readMs
            case .analysis: analysisMs
            case .population: populationMs
            case .render: renderMs
            }
        }
    }

    public var accessibility: Stages
    public var clipboardFallback: Stages
    /// Ceiling for one population function, inside the aggregate population stage (JS-16).
    public var populationPerFunctionMs: Int
    /// No bar is shown after this, measured from mouse-up (PRD §3.3, ACT-16).
    public var hardCutoffMs: Int

    public init(
        accessibility: Stages,
        clipboardFallback: Stages,
        populationPerFunctionMs: Int,
        hardCutoffMs: Int
    ) {
        self.accessibility = accessibility
        self.clipboardFallback = clipboardFallback
        self.populationPerFunctionMs = populationPerFunctionMs
        self.hardCutoffMs = hardCutoffMs
    }

    /// PRD v0.4 §11.1. Initial values; M0 may redistribute stages but not raise the totals.
    public static let initial = BudgetTable(
        accessibility: Stages(readMs: 70, analysisMs: 20, populationMs: 30, renderMs: 30),
        clipboardFallback: Stages(readMs: 270, analysisMs: 20, populationMs: 30, renderMs: 30),
        populationPerFunctionMs: 15,
        hardCutoffMs: 700
    )

    public func stages(on path: DetectionPath) -> Stages {
        switch path {
        case .accessibility: accessibility
        case .clipboardFallback: clipboardFallback
        }
    }

    public func budget(for stage: BudgetStage, on path: DetectionPath) -> Duration {
        .milliseconds(stages(on: path).milliseconds(for: stage))
    }

    /// Time from mouse-up by which `stage` should have finished: its own budget plus every earlier stage's.
    public func deadline(through stage: BudgetStage, on path: DetectionPath) -> Duration {
        let stages = stages(on: path)
        let total = BudgetStage.allCases
            .prefix { $0 != stage }
            .reduce(stages.milliseconds(for: stage)) { $0 + stages.milliseconds(for: $1) }
        return .milliseconds(total)
    }

    /// The p95 target for the whole path: 150 ms or 350 ms with the initial table.
    public func targetBudget(on path: DetectionPath) -> Duration {
        deadline(through: .render, on: path)
    }

    public var hardCutoff: Duration { .milliseconds(hardCutoffMs) }
    public var populationPerFunction: Duration { .milliseconds(populationPerFunctionMs) }
}
