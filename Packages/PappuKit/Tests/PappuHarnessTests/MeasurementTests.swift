import PappuHarness
import Testing

@Suite struct MeasurementTests {
    @Test func percentilesUseNearestRank() throws {
        let summary = try #require(Measurement.Summary(values: (1...100).map(Double.init).shuffled()))
        #expect(summary.count == 100)
        #expect(summary.min == 1)
        #expect(summary.max == 100)
        #expect(summary.mean == 50.5)
        #expect(summary.p50 == 50)
        #expect(summary.p95 == 95)
        #expect(summary.p99 == 99)
    }

    /// With few samples the p95 is the worst observed value, never an interpolated one.
    @Test func smallSeriesReportObservedValues() throws {
        let summary = try #require(Measurement.Summary(values: [4, 2, 9]))
        #expect(summary.p50 == 4)
        #expect(summary.p95 == 9)
        #expect(summary.p99 == 9)
        let single = try #require(Measurement.Summary(values: [7]))
        #expect(single.p50 == 7)
        #expect(single.p95 == 7)
    }

    @Test func emptySeriesHaveNoSummary() {
        #expect(Measurement.Summary(values: []) == nil)
        #expect(Measurement(name: "empty", values: []).summary == nil)
    }

    @Test func durationsConvertToFractionalMilliseconds() {
        #expect(Duration.milliseconds(150).milliseconds == 150)
        #expect(Duration.microseconds(1_500).milliseconds == 1.5)
        #expect(Duration.seconds(2).milliseconds == 2_000)
    }
}
