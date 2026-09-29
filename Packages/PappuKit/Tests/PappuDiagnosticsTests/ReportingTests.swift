import Foundation
import PappuCore
@testable import PappuDiagnostics
import PappuTestSupport
import Synchronization
import Testing

/// Records what would have been uploaded. No test makes a network call.
final class RecordingUploader: DiagnosticsUploading {
    struct Failed: Error {}

    private let state = Mutex<(sent: [(URL, Data)], failing: Bool)>(([], false))

    var sent: [(URL, Data)] { state.withLock { $0.sent } }
    func setFailing(_ failing: Bool) { state.withLock { $0.failing = failing } }

    func upload(_ body: Data, to endpoint: URL) async throws {
        try state.withLock { state in
            if state.failing { throw Failed() }
            state.sent.append((endpoint, body))
        }
    }
}

/// The fixtures a report must never contain.
enum Forbidden {
    static let selection = "Meet at 4pm SECRET-SELECTION-7731"
    static let clipboard = "CLIPBOARD-CONTENT-9123"
    static let option = "OPTION-VALUE-5519"
    static let app = "com.example.SecretApp"
    static let appName = "SecretApp"
    static let all = [selection, clipboard, option, app, appName]
}

/// DIA-3 and DIA-4: the payloads, the reporter and the upload.
@Suite struct ReportingTests {
    static let environment = ReportEnvironment(
        app: VersionTriple(0, 7, 1), build: 42, channel: .beta, macOS: VersionTriple(15, 4, 1), architecture: .arm64
    )
    static let endpoints = DiagnosticsEndpoints(
        crashReports: URL(string: "https://reports.test/crash"),
        betaDiagnostics: URL(string: "https://reports.test/beta")
    )
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2027-01-10 10:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_799_575_200)

    struct Rig {
        let storage: FakeSettingsStorage
        let clock: ManualDateSource
        let uploader: RecordingUploader
        let preferences: DiagnosticsPreferences
        let reporter: DiagnosticsReporter
    }

    static func rig(
        channel: ReleaseChannel = .beta,
        storage: FakeSettingsStorage = FakeSettingsStorage(),
        clock: ManualDateSource = ManualDateSource(start: start),
        endpoints: DiagnosticsEndpoints = endpoints
    ) -> Rig {
        let uploader = RecordingUploader()
        let preferences = DiagnosticsPreferences(storage: storage, channel: channel)
        var environment = Self.environment
        environment.channel = channel
        let reporter = DiagnosticsReporter(
            preferences: preferences,
            environment: environment,
            endpoints: endpoints,
            uploader: uploader,
            storage: storage,
            now: clock.reader,
            calendar: calendar
        )
        return Rig(storage: storage, clock: clock, uploader: uploader, preferences: preferences, reporter: reporter)
    }

    /// A MetricKit call-stack tree as `jsonRepresentation()` writes it, with every free-text field
    /// holding a fixture that must not come through.
    static let callStackTree = Data("""
    {
      "callStackPerThread": true,
      "callStacks": [
        {
          "threadAttributed": false,
          "callStackRootFrames": [
            {"binaryUUID": "11111111-1111-1111-1111-111111111111", "offsetIntoBinaryTextSegment": 1, "binaryName": "Other", "address": 1}
          ]
        },
        {
          "threadAttributed": true,
          "callStackRootFrames": [
            {
              "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
              "offsetIntoBinaryTextSegment": 123456,
              "binaryName": "\(Forbidden.appName)",
              "address": 7234567890,
              "sampleCount": 1,
              "note": "\(Forbidden.selection)",
              "subFrames": [
                {
                  "binaryUUID": "A5D2E0C1-7E0B-3D2B-8F4E-5B5C1A8F0E11",
                  "offsetIntoBinaryTextSegment": 9876,
                  "binaryName": "/Applications/\(Forbidden.app).app/Contents/MacOS/\(Forbidden.clipboard)",
                  "address": 7234000000,
                  "subFrames": [{"offsetIntoBinaryTextSegment": 5, "binaryName": "\(Forbidden.option)"}]
                }
              ]
            }
          ]
        }
      ]
    }
    """.utf8)

    // MARK: Text-free by construction (DIA-3, DIA-4)

    /// Fully populated, every optional set.
    static func populated() -> (CrashReportBatch, DiagnosticsBatch) {
        let crash = CrashReport(
            environment: environment,
            day: DayStamp(year: 2027, month: 1, day: 10),
            process: .app,
            exceptionType: 1,
            exceptionCode: 2,
            signal: 11,
            frames: CallStackFrames.crashedThread(in: callStackTree)
        )
        var day = DailyDiagnostics(environment: environment, day: DayStamp(year: 2027, month: 1, day: 10))
        day.sessions = 3
        day.appCrashes = 1
        day.helperCrashes = 1
        day.record(.milliseconds(80), for: .selectionToBar)
        return (CrashReportBatch(reports: [crash]), DiagnosticsBatch(days: [day]))
    }

    /// No stored property of any payload type, at any depth, is a `String`.
    @Test func payloadTypesHaveNoStringFieldAtAnyDepth() {
        let (crashes, days) = Self.populated()
        var visited = 0
        func walk(_ value: Any, _ path: String) {
            visited += 1
            #expect(!(value is String) && !(value is Substring) && !(value is Character), "\(path) is text")
            for child in Mirror(reflecting: value).children {
                walk(child.value, path + "." + (child.label ?? "[]"))
            }
        }
        walk(crashes, "CrashReportBatch")
        walk(days, "DiagnosticsBatch")
        #expect(visited > 30)
    }

    /// Every string the encoder writes is an enumeration's code or a UUID.
    @Test func everyStringInTheEncodedPayloadIsACodeOrAUUID() throws {
        let (crashes, days) = Self.populated()
        let codes = Set(
            ReleaseChannel.allCases.map(\.rawValue) + CPUArchitecture.allCases.map(\.rawValue)
                + CrashingProcess.allCases.map(\.rawValue) + LatencyStage.allCases.map(\.rawValue)
        )
        var strings: [String] = []
        func walk(_ json: Any) {
            if let text = json as? String { strings.append(text) }
            if let array = json as? [Any] { array.forEach(walk) }
            if let object = json as? [String: Any] { object.values.forEach(walk) }
        }
        walk(try JSONSerialization.jsonObject(with: JSONEncoder().encode(crashes)))
        walk(try JSONSerialization.jsonObject(with: JSONEncoder().encode(days)))
        #expect(!strings.isEmpty)
        for text in strings {
            #expect(codes.contains(text) || UUID(uuidString: text) != nil, "\(text) is neither a code nor a UUID")
        }
    }

    /// The fixtures go in wherever the system hands the reporter anything; none come out.
    @Test func noSelectionClipboardOptionOrAppReachesTheEncodedBytes() async throws {
        let rig = Self.rig()
        rig.preferences.setCrashReports(true)
        rig.preferences.setBetaDiagnostics(true)
        rig.reporter.sessionStarted()
        rig.reporter.record(.milliseconds(120), for: .selectionToBar)
        rig.reporter.helperCrashed()
        rig.reporter.appCrashed(
            exceptionType: 1, exceptionCode: 0, signal: 11,
            frames: CallStackFrames.crashedThread(in: Self.callStackTree)
        )

        let (crashPreview, betaPreview) = rig.reporter.preview()
        rig.clock.advance(by: 86_400)
        #expect(await rig.reporter.uploadIfDue() == 2)

        var bytes = [try #require(crashPreview), try #require(betaPreview)] + rig.uploader.sent.map(\.1)
        bytes.append(rig.storage.data(forKey: DiagnosticsReporter.ledgerKey) ?? Data())
        for data in bytes {
            let text = String(decoding: data, as: UTF8.self)
            for fixture in Forbidden.all { #expect(!text.contains(fixture), "\(fixture) leaked") }
        }
    }

    @Test func theCrashedThreadIsBinariesAndOffsetsOnly() {
        let frames = CallStackFrames.crashedThread(in: Self.callStackTree)
        #expect(frames == [
            CrashFrame(binary: UUID(uuidString: "70B89F27-1634-3580-A695-57CDB41D7743"), offset: 123_456),
            CrashFrame(binary: UUID(uuidString: "A5D2E0C1-7E0B-3D2B-8F4E-5B5C1A8F0E11"), offset: 9_876),
            CrashFrame(binary: nil, offset: 5),
        ])
        #expect(CallStackFrames.crashedThread(in: Data(Forbidden.selection.utf8)).isEmpty)
    }

    // MARK: Off by default, and off means nothing

    @Test func bothSwitchesAreOffByDefaultAndNothingIsCollectedOrSent() async {
        let rig = Self.rig()
        #expect(!rig.preferences.crashReports)
        #expect(!rig.preferences.betaDiagnostics)
        rig.reporter.sessionStarted()
        rig.reporter.record(.milliseconds(80), for: .selectionToBar)
        rig.reporter.helperCrashed()
        rig.reporter.appCrashed(exceptionType: 1, exceptionCode: 0, signal: 11, frames: [])
        rig.clock.advance(by: 3 * 86_400)
        #expect(rig.reporter.pending == DiagnosticsReporter.Pending())
        #expect(rig.reporter.preview().crashReports == nil)
        #expect(rig.reporter.preview().betaDiagnostics == nil)
        #expect(await rig.reporter.uploadIfDue() == 0)
        #expect(rig.uploader.sent.isEmpty)
    }

    @Test func betaDiagnosticsAreOfferedOnlyInBetaBuilds() {
        for channel in [ReleaseChannel.release, .development] {
            let storage = FakeSettingsStorage()
            // Even a switch stored as on is not in force outside a beta.
            storage.set(try? JSONEncoder().encode(true), forKey: DiagnosticsPreferences.betaDiagnosticsKey)
            let rig = Self.rig(channel: channel, storage: storage)
            #expect(!rig.preferences.offersBetaDiagnostics)
            #expect(!rig.preferences.betaDiagnostics)
            rig.preferences.setBetaDiagnostics(true)
            #expect(!rig.preferences.betaDiagnostics)
            rig.reporter.sessionStarted()
            #expect(rig.reporter.preview().betaDiagnostics == nil)
        }
        #expect(Self.rig(channel: .beta).preferences.offersBetaDiagnostics)
    }

    @Test func theChannelAndEndpointsComeFromTheBundle() {
        #expect(ReleaseChannel(bundle: Bundle(for: RecordingUploader.self)) == .development)
        let endpoints = DiagnosticsEndpoints(bundle: Bundle(for: RecordingUploader.self))
        #expect(endpoints.crashReports == nil)
        #expect(endpoints.betaDiagnostics == nil)
        #expect(DiagnosticsEndpoints.placeholder.crashReports?.host()?.hasSuffix(".invalid") == true)
        #expect(DiagnosticsEndpoints.placeholder.betaDiagnostics?.host()?.hasSuffix(".invalid") == true)
        // The placeholder is no endpoint at all, and only https is taken.
        #expect(DiagnosticsEndpoints.url(DiagnosticsEndpoints.placeholder.crashReports?.absoluteString) == nil)
        #expect(DiagnosticsEndpoints.url("http://reports.example.com/v1") == nil)
        #expect(DiagnosticsEndpoints.url("not a url") == nil)
        #expect(DiagnosticsEndpoints.url("https://reports.example.com/v1")?.host() == "reports.example.com")
    }

    @Test func turningASwitchOffDiscardsWhatItCollected() {
        let rig = Self.rig()
        rig.preferences.setCrashReports(true)
        rig.preferences.setBetaDiagnostics(true)
        rig.reporter.sessionStarted()
        rig.reporter.helperCrashed()
        #expect(rig.reporter.preview().crashReports != nil)

        rig.preferences.setCrashReports(false)
        rig.preferences.setCrashReports(true)
        let crashes = try? JSONDecoder().decode(CrashReportBatch.self, from: rig.reporter.preview().crashReports ?? Data())
        #expect(crashes?.reports.isEmpty == true)

        rig.preferences.setBetaDiagnostics(false)
        rig.preferences.setBetaDiagnostics(true)
        let days = try? JSONDecoder().decode(DiagnosticsBatch.self, from: rig.reporter.preview().betaDiagnostics ?? Data())
        #expect(days?.days.isEmpty == true)

        // And what was stored went with it.
        let reopened = Self.rig(storage: rig.storage)
        #expect(reopened.reporter.pending == DiagnosticsReporter.Pending())
    }

    // MARK: Sessions and crashes (PRD §3.3)

    @Test func aSessionLeftOpenIsCountedAsACrashAtTheNextLaunch() throws {
        let storage = FakeSettingsStorage()
        let clock = ManualDateSource(start: Self.start)
        let first = Self.rig(storage: storage, clock: clock)
        first.preferences.setBetaDiagnostics(true)
        first.reporter.sessionStarted()
        first.reporter.sessionEnded()
        first.reporter.sessionStarted()
        // No sessionEnded: the process went away.

        let second = Self.rig(storage: storage, clock: clock)
        second.reporter.sessionStarted()
        clock.advance(by: 86_400)
        let days = try #require(second.reporter.pending.betaDiagnostics?.days)
        #expect(days.count == 1)
        #expect(days[0].sessions == 3)
        #expect(days[0].appCrashes == 1)
        #expect(days[0].environment == Self.environment)
    }

    @Test func aHelperCrashIsAReportAndACount() throws {
        let rig = Self.rig()
        rig.preferences.setCrashReports(true)
        rig.preferences.setBetaDiagnostics(true)
        rig.reporter.helperCrashed()
        #expect(rig.reporter.pending.crashReports?.reports.map(\.process) == [.javaScriptHelper])
        rig.clock.advance(by: 86_400)
        #expect(rig.reporter.pending.betaDiagnostics?.days.first?.helperCrashes == 1)
    }

    @Test func crashReportsAreBounded() {
        let rig = Self.rig()
        rig.preferences.setCrashReports(true)
        for signal in 0..<(DiagnosticsReporter.crashLimit + 5) {
            rig.reporter.appCrashed(exceptionType: nil, exceptionCode: nil, signal: signal, frames: [])
        }
        let reports = rig.reporter.pending.crashReports?.reports ?? []
        #expect(reports.count == DiagnosticsReporter.crashLimit)
        #expect(reports.first?.signal == 5)
    }

    // MARK: Latency histograms (DIA-4)

    @Test func durationsFallIntoFixedBuckets() {
        #expect(LatencyHistogram.bucket(for: .milliseconds(10)) == 0)
        #expect(LatencyHistogram.bucket(for: .milliseconds(25)) == 1)
        #expect(LatencyHistogram.bucket(for: .microseconds(99_900)) == 3)
        #expect(LatencyHistogram.bucket(for: .milliseconds(699)) == 8)
        #expect(LatencyHistogram.bucket(for: .milliseconds(700)) == 9)
        #expect(LatencyHistogram.bucket(for: .seconds(5)) == 9)
        var histogram = LatencyHistogram(stage: .selectionToBar)
        #expect(histogram.counts.count == LatencyHistogram.upperBoundsMs.count + 1)
        histogram.record(.milliseconds(60))
        histogram.record(.milliseconds(60))
        #expect(histogram.counts[2] == 2)
        #expect(histogram.total == 2)
    }

    // MARK: The upload

    @Test func finishedDaysAreSentOnceADayAndThenForgotten() async throws {
        let rig = Self.rig()
        rig.preferences.setBetaDiagnostics(true)
        rig.reporter.sessionStarted()
        rig.reporter.record(.milliseconds(80), for: .selectionToBar)
        rig.reporter.record(.milliseconds(400), for: .selectionToBar)

        // Today is not finished: nothing goes.
        #expect(await rig.reporter.uploadIfDue() == 0)

        rig.clock.advance(by: 86_400)
        rig.reporter.record(.milliseconds(90), for: .selectionToBar)
        #expect(await rig.reporter.uploadIfDue() == 1)
        let (url, body) = try #require(rig.uploader.sent.first)
        #expect(url == Self.endpoints.betaDiagnostics)
        let batch = try JSONDecoder().decode(DiagnosticsBatch.self, from: body)
        #expect(batch.schema == DiagnosticsBatch.schema)
        #expect(batch.days.map(\.day) == [DayStamp(year: 2027, month: 1, day: 10)])
        #expect(batch.days[0].sessions == 1)
        #expect(batch.days[0].latency.first?.total == 2)

        // Sent is forgotten; today's counts stay for tomorrow.
        #expect(rig.reporter.pending.betaDiagnostics == nil)
        let preview = try JSONDecoder().decode(DiagnosticsBatch.self, from: try #require(rig.reporter.preview().betaDiagnostics))
        #expect(preview.days.map(\.day) == [DayStamp(year: 2027, month: 1, day: 11)])

        // Once a day: a crash an hour later waits for the next day.
        rig.preferences.setCrashReports(true)
        rig.reporter.helperCrashed()
        rig.clock.advance(by: 3_600)
        #expect(await rig.reporter.uploadIfDue() == 0)
        rig.clock.advance(by: 86_400)
        #expect(await rig.reporter.uploadIfDue() == 2)
        #expect(rig.uploader.sent.map(\.0).contains(Self.endpoints.crashReports!))
    }

    @Test func aFailedUploadIsKeptForTheNextDay() async {
        let rig = Self.rig()
        rig.preferences.setCrashReports(true)
        rig.reporter.helperCrashed()
        rig.uploader.setFailing(true)
        #expect(await rig.reporter.uploadIfDue() == 0)
        #expect(rig.reporter.pending.crashReports?.reports.count == 1)
        rig.uploader.setFailing(false)
        #expect(await rig.reporter.uploadIfDue() == 0)
        rig.clock.advance(by: 86_400)
        #expect(await rig.reporter.uploadIfDue() == 1)
        #expect(rig.reporter.pending.crashReports == nil)
    }

    @Test func nothingIsSentWithoutAnEndpoint() async {
        let rig = Self.rig(endpoints: DiagnosticsEndpoints(crashReports: nil, betaDiagnostics: nil))
        rig.preferences.setCrashReports(true)
        rig.preferences.setBetaDiagnostics(true)
        rig.reporter.sessionStarted()
        rig.reporter.helperCrashed()
        rig.clock.advance(by: 86_400)
        #expect(await rig.reporter.uploadIfDue() == 0)
        #expect(rig.uploader.sent.isEmpty)
        #expect(rig.reporter.pending.crashReports != nil)
    }

    // MARK: Versions

    @Test func versionsAreNumbers() {
        #expect(VersionTriple(parsing: "1.2.3") == VersionTriple(1, 2, 3))
        #expect(VersionTriple(parsing: "0.7") == VersionTriple(0, 7, 0))
        #expect(VersionTriple(parsing: "1.0b2") == VersionTriple(1, 0, 0))
        #expect(VersionTriple(parsing: "beta") == nil)
        let current = ReportEnvironment.current(bundle: Bundle(for: RecordingUploader.self), channel: .beta)
        #expect(current.macOS.major >= 15)
        #expect(current.channel == .beta)
    }
}
