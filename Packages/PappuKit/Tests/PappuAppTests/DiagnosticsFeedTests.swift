import Foundation
@testable import PappuApp
import PappuCore
import PappuDiagnostics
import PappuSelection
import PappuTestSupport
import Testing

/// DIA-4: an attempt reaches beta diagnostics as one duration, and nothing else of it goes on.
@Suite struct DiagnosticsFeedTests {
    private static let app = "com.example.SecretApp"

    private func reporter(_ storage: FakeSettingsStorage) -> DiagnosticsReporter {
        let preferences = DiagnosticsPreferences(storage: storage, channel: .beta)
        preferences.setBetaDiagnostics(true)
        return DiagnosticsReporter(
            preferences: preferences,
            environment: ReportEnvironment(
                app: VersionTriple(1), build: 1, channel: .beta, macOS: VersionTriple(15), architecture: .arm64
            ),
            endpoints: DiagnosticsEndpoints(crashReports: nil, betaDiagnostics: nil),
            uploader: URLSessionDiagnosticsUploader(),
            storage: storage
        )
    }

    private func record(showedBar: Bool) -> AttemptRecord {
        var record = AttemptRecord(attempt: AttemptID(rawValue: 7), route: .automatic, gesture: .suppressed)
        record.pid = 4_242
        record.bundleID = Self.app
        record.characters = 31
        record.showedBar = showedBar
        record.elapsed = .milliseconds(120)
        return record
    }

    @Test func anAttemptThatShowedABarIsOneDurationAndNoApp() throws {
        let storage = FakeSettingsStorage()
        let reporter = reporter(storage)
        DiagnosticsFeed.record(record(showedBar: true), into: reporter)

        let preview = try #require(reporter.preview().betaDiagnostics)
        let batch = try JSONDecoder().decode(DiagnosticsBatch.self, from: preview)
        var expected = LatencyHistogram(stage: .selectionToBar)
        expected.record(.milliseconds(120))
        #expect(batch.days.first?.latency == [expected])
        for bytes in [preview, storage.data(forKey: DiagnosticsReporter.ledgerKey) ?? Data()] {
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains(Self.app))
            #expect(!text.contains("SecretApp"))
            #expect(!text.contains("4242"))
        }
    }

    @Test func anAttemptWithoutABarRecordsNothing() {
        #expect(DiagnosticsFeed.latency(of: record(showedBar: false)) == nil)
        let reporter = reporter(FakeSettingsStorage())
        DiagnosticsFeed.record(record(showedBar: false), into: reporter)
        let text = reporter.preview().betaDiagnostics.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!text.contains("selectionToBar"))
    }
}
