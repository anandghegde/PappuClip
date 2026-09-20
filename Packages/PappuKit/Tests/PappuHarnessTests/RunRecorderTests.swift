import Foundation
import PappuCore
import PappuHarness
import Synchronization
import Testing

@Suite struct RunRecorderTests {
    private func makeRecorder(onLog: (@Sendable (String) -> Void)? = nil) -> RunRecorder {
        RunRecorder(runID: "test-run", title: "Test", question: "Does it record?", parameters: ["samples": "3"], onLog: onLog)
    }

    @Test func samplesGroupByNameAndLabelsInOrderOfFirstUse() {
        let recorder = makeRecorder()
        recorder.record("create", labels: ["option": "listenOnly"], value: 1)
        recorder.record("create", labels: ["option": "default"], value: 5)
        recorder.record("create", labels: ["option": "listenOnly"], value: 3)

        let result = recorder.finish()
        #expect(result.measurements.map(\.labels) == [["option": "listenOnly"], ["option": "default"]])
        #expect(result.measurements[0].values == [1, 3])
        #expect(result.measurements[0].summary?.max == 3)
        #expect(result.parameters == ["samples": "3"])
    }

    @Test func measureRecordsTheBlockAndReturnsItsValue() {
        let recorder = makeRecorder()
        let value = recorder.measure("work") { 42 }
        #expect(value == 42)
        let measurement = recorder.finish().measurements[0]
        #expect(measurement.name == "work")
        #expect(measurement.unit == "ms")
        #expect(measurement.values.count == 1)
        #expect(measurement.values[0] >= 0)
    }

    @Test func observationsAreLoggedAndForwarded() {
        let lines = Mutex<[String]>([])
        let recorder = makeRecorder { line in lines.withLock { $0.append(line) } }
        recorder.observe("tap.listenOnly.created", .confirmed, "created without Input Monitoring")

        let result = recorder.finish(notes: "Accessibility granted")
        #expect(result.findings == [
            Finding(key: "tap.listenOnly.created", outcome: .confirmed, detail: "created without Input Monitoring"),
        ])
        #expect(result.notes == "Accessibility granted")
        #expect(result.log.count == 1)
        #expect(lines.withLock { $0 } == result.log)
        #expect(result.log[0].hasSuffix("[confirmed] tap.listenOnly.created: created without Input Monitoring"))
    }

    @Test func recordingFromManyThreadsLosesNothing() async {
        let recorder = makeRecorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { recorder.record("concurrent", value: Double(index)) }
            }
        }
        #expect(recorder.finish().measurements[0].values.sorted() == (0..<200).map(Double.init))
    }

    @Test func resultsRoundTripThroughTheStore() throws {
        let recorder = makeRecorder()
        recorder.record("create", value: 1.25)
        recorder.observe("fact", .info, "detail", labels: ["app": "TextEdit"])
        let result = recorder.finish(notes: "note")

        let directory = FileManager.default.temporaryDirectory.appending(path: "pappu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ResultsStore(directory: directory).write(result)

        #expect(url.deletingLastPathComponent().lastPathComponent == "test-run")
        #expect(url.lastPathComponent.hasSuffix("-macOS\(result.environment.osVersion)-\(result.environment.architecture).json"))
        let loaded = try ResultsStore.read(url)
        // Dates are stored to the second.
        #expect(abs(loaded.startedAt.timeIntervalSince(result.startedAt)) < 1)
        #expect(loaded.measurements == result.measurements)
        #expect(loaded.findings == result.findings)
        #expect(loaded.budgets == BudgetTable.initial)
        #expect(loaded.schema == RunResult.currentSchema)
        #expect(loaded.summaryText().contains("create: n=1 p50=1.250"))
    }

    /// Results are committed, so they must not identify the person who ran them.
    @Test func resultsCarryNoPersonalIdentifiers() throws {
        let recorder = makeRecorder()
        let data = try JSONEncoder().encode(recorder.finish())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(NSHomeDirectory()))
        #expect(!json.contains("/Users/"))
        #expect(!json.contains(ProcessInfo.processInfo.hostName))
    }
}
