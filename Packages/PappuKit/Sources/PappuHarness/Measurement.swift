/// One series of samples, for example "key tap create" in milliseconds.
public struct Measurement: Sendable, Equatable, Codable {
    public struct Summary: Sendable, Equatable, Codable {
        public var count: Int
        public var min: Double
        public var max: Double
        public var mean: Double
        public var p50: Double
        public var p95: Double
        public var p99: Double

        /// Nearest-rank percentiles: every reported value is one that was actually observed, which
        /// matters when a p95 is compared against a budget with few samples.
        public init?(values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double {
                let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
                return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
            }
            count = sorted.count
            min = sorted[0]
            max = sorted[sorted.count - 1]
            mean = sorted.reduce(0, +) / Double(sorted.count)
            p50 = percentile(50)
            p95 = percentile(95)
            p99 = percentile(99)
        }
    }

    public var name: String
    public var unit: String
    /// Dimensions such as `app`, `strategy` or `tapOption`. Kept flat so results load into a table.
    public var labels: [String: String]
    public var values: [Double]
    public var summary: Summary?

    public init(name: String, unit: String = "ms", labels: [String: String] = [:], values: [Double]) {
        self.name = name
        self.unit = unit
        self.labels = labels
        self.values = values
        summary = Summary(values: values)
    }
}

/// A yes/no result, as opposed to a timing. Spike reports are written from these.
///
/// Not called `Observation`: that would shadow the Observation module in every client that uses `@Observable`.
public struct Finding: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable {
        /// The thing the design assumes turned out to be true.
        case confirmed
        /// The design's assumption is wrong on this machine.
        case refuted
        /// The run could not tell, usually because a permission was missing.
        case inconclusive
        /// A recorded fact with no assumption behind it.
        case info
    }

    public var key: String
    public var outcome: Outcome
    public var detail: String
    public var labels: [String: String]

    public init(key: String, outcome: Outcome, detail: String, labels: [String: String] = [:]) {
        self.key = key
        self.outcome = outcome
        self.detail = detail
        self.labels = labels
    }
}

extension Duration {
    /// Fractional milliseconds, the unit every latency figure in the PRD uses.
    public var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
