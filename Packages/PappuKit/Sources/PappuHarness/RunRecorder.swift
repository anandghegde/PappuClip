import Foundation
import os
import PappuCore
import Synchronization

/// Collects samples, findings and log lines during one run. Safe to call from any thread, because
/// event-tap callbacks and XPC replies do not arrive on the thread that started the run.
public final class RunRecorder: Sendable {
    private struct SeriesKey: Hashable {
        var name: String
        var unit: String
        var labels: [String: String]
    }

    private struct State {
        var order: [SeriesKey] = []
        var samples: [SeriesKey: [Double]] = [:]
        var findings: [Finding] = []
        var parameters: [String: String]
        var log: [String] = []
    }

    public let runID: String
    public let title: String
    public let question: String
    public let budgets: BudgetTable

    private let startedAt = Date()
    private let startInstant = ContinuousClock.now
    private let state: Mutex<State>
    private let onLog: (@Sendable (String) -> Void)?
    private let signposter = OSSignposter(subsystem: AppIdentity.logSubsystem, category: "Harness")

    /// - Parameter onLog: Called for every log line, on the calling thread. SpikeLab shows these live.
    public init(
        runID: String,
        title: String,
        question: String,
        budgets: BudgetTable = .initial,
        parameters: [String: String] = [:],
        onLog: (@Sendable (String) -> Void)? = nil
    ) {
        self.runID = runID
        self.title = title
        self.question = question
        self.budgets = budgets
        self.onLog = onLog
        state = Mutex(State(parameters: parameters))
    }

    // MARK: Samples

    public func record(_ name: String, unit: String = "ms", labels: [String: String] = [:], value: Double) {
        let key = SeriesKey(name: name, unit: unit, labels: labels)
        state.withLock { state in
            if state.samples[key] == nil { state.order.append(key) }
            state.samples[key, default: []].append(value)
        }
    }

    public func record(_ name: String, labels: [String: String] = [:], duration: Duration) {
        record(name, labels: labels, value: duration.milliseconds)
    }

    /// Times `body` and records it under `name`. The interval also appears in Instruments under the
    /// app's subsystem, so a surprising number can be looked at in a trace.
    @discardableResult
    public func measure<T>(_ name: String, labels: [String: String] = [:], _ body: () throws -> T) rethrows -> T {
        let interval = signposter.beginInterval("measure", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        let start = ContinuousClock.now
        defer {
            record(name, labels: labels, duration: start.duration(to: .now))
            signposter.endInterval("measure", interval)
        }
        return try body()
    }

    // MARK: Findings

    public func observe(
        _ key: String,
        _ outcome: Finding.Outcome,
        _ detail: String,
        labels: [String: String] = [:]
    ) {
        state.withLock { $0.findings.append(Finding(key: key, outcome: outcome, detail: detail, labels: labels)) }
        log("[\(outcome.rawValue)] \(key): \(detail)")
    }

    public func setParameter(_ key: String, _ value: String) {
        state.withLock { $0.parameters[key] = value }
    }

    public func log(_ line: String) {
        let stamped = String(format: "%8.3fs  ", startInstant.duration(to: .now).milliseconds / 1_000) + line
        state.withLock { $0.log.append(stamped) }
        onLog?(stamped)
    }

    // MARK: Result

    /// A snapshot; the recorder stays usable, so SpikeLab can save again after the operator adds notes.
    public func finish(notes: String = "") -> RunResult {
        let snapshot = state.withLock { $0 }
        return RunResult(
            runID: runID,
            title: title,
            question: question,
            startedAt: startedAt,
            durationSeconds: startInstant.duration(to: .now).milliseconds / 1_000,
            environment: .current(),
            budgets: budgets,
            parameters: snapshot.parameters,
            measurements: snapshot.order.map {
                Measurement(name: $0.name, unit: $0.unit, labels: $0.labels, values: snapshot.samples[$0] ?? [])
            },
            findings: snapshot.findings,
            log: snapshot.log,
            notes: notes
        )
    }
}
