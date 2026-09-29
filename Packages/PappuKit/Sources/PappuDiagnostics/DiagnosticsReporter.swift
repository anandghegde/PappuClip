import Foundation
import PappuCore
import Synchronization

/// The two opt-ins (DIA-3, DIA-4). Both are off until the user turns them on, and beta diagnostics are
/// offered only in a beta build: anywhere else the stored switch is ignored and the control is not shown.
public final class DiagnosticsPreferences: Sendable {
    public static let crashReportsKey = "diagnostics.crashReports"
    public static let betaDiagnosticsKey = "diagnostics.betaDiagnostics"

    public let channel: ReleaseChannel
    private let crash: SettingsValue<Bool>
    private let beta: SettingsValue<Bool>

    public init(storage: any SettingsStorage, channel: ReleaseChannel) {
        self.channel = channel
        crash = SettingsValue(key: Self.crashReportsKey, default: false, storage: storage)
        beta = SettingsValue(key: Self.betaDiagnosticsKey, default: false, storage: storage)
    }

    /// DIA-4: "offered only in beta builds".
    public var offersBetaDiagnostics: Bool { channel == .beta }

    public var crashReports: Bool { crash.value }
    /// What is in force: the stored switch, and only in a beta build.
    public var betaDiagnostics: Bool { offersBetaDiagnostics && beta.value }

    public func setCrashReports(_ on: Bool) { crash.set(on) }

    public func setBetaDiagnostics(_ on: Bool) {
        guard offersBetaDiagnostics || !on else { return }
        beta.set(on)
    }

    /// Called after either switch changes, on whichever thread changed it.
    public func onChange(_ body: @escaping @Sendable () -> Void) {
        crash.onChange { _ in body() }
        beta.onChange { _ in body() }
    }
}

/// Where reports go. Read from the app's Info.plist (`PappuCrashReportURL`, `PappuDiagnosticsURL`); a
/// build without a key sends nothing for that kind and keeps what it has, within its bounds.
///
/// **The shipped values are placeholders.** `diagnostics.pappuclip.invalid` is in the `.invalid` domain,
/// which never resolves (RFC 2606), and `init(bundle:)` reads a `.invalid` host as no endpoint, so a
/// beta that has not been pointed at the real service does not even look the name up: it keeps what it
/// collected, within its bounds, and the switches and "Show What Is Sent" work as they will. The privacy
/// policy names the real endpoints once they exist (PRD §11.3).
public struct DiagnosticsEndpoints: Sendable, Equatable {
    public static let crashReportsKey = "PappuCrashReportURL"
    public static let betaDiagnosticsKey = "PappuDiagnosticsURL"
    public static let placeholder = DiagnosticsEndpoints(
        crashReports: URL(string: "https://diagnostics.pappuclip.invalid/v1/crash-reports"),
        betaDiagnostics: URL(string: "https://diagnostics.pappuclip.invalid/v1/beta-diagnostics")
    )

    public var crashReports: URL?
    public var betaDiagnostics: URL?

    public init(crashReports: URL?, betaDiagnostics: URL?) {
        self.crashReports = crashReports
        self.betaDiagnostics = betaDiagnostics
    }

    /// Only `https` is taken, and a placeholder in `.invalid` is taken as no endpoint: nothing is even
    /// looked up until the key names a real host.
    public init(bundle: Bundle) {
        self.init(crashReports: Self.url(bundle.object(forInfoDictionaryKey: Self.crashReportsKey) as? String),
                  betaDiagnostics: Self.url(bundle.object(forInfoDictionaryKey: Self.betaDiagnosticsKey) as? String))
    }

    static func url(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https",
              let host = url.host(), !host.isEmpty, !host.hasSuffix(".invalid")
        else { return nil }
        return url
    }
}

extension ReleaseChannel {
    public static let infoPlistKey = "PappuReleaseChannel"

    /// The bundle's `PappuReleaseChannel`. Missing or unrecognised is `development`, which is offered
    /// nothing that is only for the beta.
    public init(bundle: Bundle) {
        let text = bundle.object(forInfoDictionaryKey: Self.infoPlistKey) as? String
        self = text.flatMap(ReleaseChannel.init(rawValue:)) ?? .development
    }
}

/// Sends one encoded batch. `URLSessionDiagnosticsUploader` in the app; a recorder in tests, which make
/// no network calls.
public protocol DiagnosticsUploading: Sendable {
    func upload(_ body: Data, to endpoint: URL) async throws
}

/// A POST of JSON over an ephemeral session: no cookies, no credentials, no cache, nothing that
/// persists between uploads and could tie one to the next.
public struct URLSessionDiagnosticsUploader: DiagnosticsUploading {
    public struct Refused: Error, Equatable {
        public var status: Int
    }

    public init() {}

    public func upload(_ body: Data, to endpoint: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Refused(status: status) }
    }
}

/// Collects crash reports (DIA-3) and beta diagnostics (DIA-4) and uploads them once a day.
///
/// **Nothing is collected while a switch is off, and turning one off discards what it collected.** The
/// session marker is the exception: one Boolean, kept locally whatever the switches say, so that a crash
/// is counted when the next launch finds the previous session still open.
///
/// Everything it keeps is one of the payload types, which cannot hold text (see `ReportPayloads.swift`),
/// in the settings storage under `ledgerKey`. It is bounded: at most `crashLimit` crash reports and
/// `dayLimit` days, oldest dropped first.
public final class DiagnosticsReporter: Sendable {
    public static let ledgerKey = "diagnostics.ledger"
    public static let crashLimit = 20
    public static let dayLimit = 14
    /// "Batching once per day."
    public static let uploadInterval: TimeInterval = 24 * 60 * 60

    struct Ledger: Codable, Equatable {
        var sessionOpen = false
        var crashes: [CrashReport] = []
        var days: [DailyDiagnostics] = []
        var lastUpload: Date?
    }

    /// What an upload would send now, encoded exactly as it would be (Settings shows it).
    public struct Pending: Sendable, Equatable {
        public var crashReports: CrashReportBatch?
        public var betaDiagnostics: DiagnosticsBatch?
    }

    public let preferences: DiagnosticsPreferences
    public let environment: ReportEnvironment
    private let endpoints: DiagnosticsEndpoints
    private let uploader: any DiagnosticsUploading
    private let storage: any SettingsStorage
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let ledger: Mutex<Ledger>
    /// One upload at a time.
    private let uploading = Mutex(false)

    public init(
        preferences: DiagnosticsPreferences,
        environment: ReportEnvironment,
        endpoints: DiagnosticsEndpoints,
        uploader: any DiagnosticsUploading,
        storage: any SettingsStorage,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.preferences = preferences
        self.environment = environment
        self.endpoints = endpoints
        self.uploader = uploader
        self.storage = storage
        self.now = now
        self.calendar = calendar
        let stored = storage.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
        ledger = Mutex(stored ?? Ledger())
        discardWhatIsOff()
        preferences.onChange { [weak self] in self?.discardWhatIsOff() }
    }

    // MARK: Sessions

    /// At launch. A session still open from last time ended without `sessionEnded`: a crash, a force
    /// quit or a power loss, all counted as a crash (PRD §3.3 counts sessions that did not end cleanly).
    public func sessionStarted() {
        let beta = preferences.betaDiagnostics
        let today = DayStamp(now(), calendar: calendar)
        change { ledger in
            let crashed = ledger.sessionOpen
            ledger.sessionOpen = true
            guard beta else { return }
            Self.update(&ledger, day: today, environment: environment) { record in
                record.sessions += 1
                if crashed { record.appCrashes += 1 }
            }
        }
    }

    /// At a clean quit. Synchronous, because `applicationWillTerminate` does not wait for a task.
    public func sessionEnded() {
        change { $0.sessionOpen = false }
    }

    // MARK: What is collected

    /// DIA-4's latency histograms, from the attempt's own clock.
    public func record(_ duration: Duration, for stage: LatencyStage) {
        guard preferences.betaDiagnostics else { return }
        let today = DayStamp(now(), calendar: calendar)
        change { ledger in
            Self.update(&ledger, day: today, environment: environment) { $0.record(duration, for: stage) }
        }
    }

    /// The JavaScript helper went away under an extension (SEC-1d). Which extension is not kept.
    public func helperCrashed() {
        let crash = preferences.crashReports
        let beta = preferences.betaDiagnostics
        guard crash || beta else { return }
        let today = DayStamp(now(), calendar: calendar)
        change { ledger in
            if crash {
                Self.append(CrashReport(environment: environment, day: today, process: .javaScriptHelper), to: &ledger)
            }
            if beta {
                Self.update(&ledger, day: today, environment: environment) { $0.helperCrashes += 1 }
            }
        }
    }

    /// A crash of the app itself, from MetricKit at the next launch.
    public func received(_ report: CrashReport) {
        guard preferences.crashReports else { return }
        change { Self.append(report, to: &$0) }
    }

    /// A crash built by the caller from codes and frames, dated today in this build.
    public func appCrashed(exceptionType: Int?, exceptionCode: Int?, signal: Int?, frames: [CrashFrame]) {
        received(CrashReport(
            environment: environment,
            day: DayStamp(now(), calendar: calendar),
            process: .app,
            exceptionType: exceptionType,
            exceptionCode: exceptionCode,
            signal: signal,
            frames: frames
        ))
    }

    // MARK: What is sent

    /// What the next upload would send if it happened now. Beta diagnostics are finished days only;
    /// today's counts go the day after.
    public var pending: Pending {
        let today = DayStamp(now(), calendar: calendar)
        let (crashes, days) = ledger.withLock { ($0.crashes, $0.days) }
        let finished = days.filter { $0.day < today }
        return Pending(
            crashReports: preferences.crashReports && !crashes.isEmpty ? CrashReportBatch(reports: crashes) : nil,
            betaDiagnostics: preferences.betaDiagnostics && !finished.isEmpty ? DiagnosticsBatch(days: finished) : nil
        )
    }

    /// Everything held for each switch that is on, today's unfinished counts included, as the JSON that
    /// would be sent. For Settings' "Show what is sent".
    public func preview() -> (crashReports: Data?, betaDiagnostics: Data?) {
        let (crashes, days) = ledger.withLock { ($0.crashes, $0.days) }
        return (
            preferences.crashReports ? try? Self.encoder.encode(CrashReportBatch(reports: crashes)) : nil,
            preferences.betaDiagnostics ? try? Self.encoder.encode(DiagnosticsBatch(days: days)) : nil
        )
    }

    /// Sends what is pending, if a day has gone by since the last upload. What was sent is forgotten;
    /// what failed is kept for the next day. Nothing is sent for a switch that is off or a kind with no
    /// endpoint.
    ///
    /// - Returns: How many batches were sent.
    @discardableResult
    public func uploadIfDue() async -> Int {
        guard uploading.withLock({ busy in
            defer { busy = true }
            return !busy
        }) else { return 0 }
        defer { uploading.withLock { $0 = false } }

        let at = now()
        let due = ledger.withLock { ledger in
            ledger.lastUpload.map { at.timeIntervalSince($0) >= Self.uploadInterval || at < $0 } ?? true
        }
        guard due else { return 0 }
        let pending = self.pending
        var work: [(URL, Data, @Sendable (inout Ledger) -> Void)] = []
        if let batch = pending.crashReports, let url = endpoints.crashReports, let body = try? Self.encoder.encode(batch) {
            let sent = batch.reports
            work.append((url, body, { ledger in
                // By value, not by position: a crash that arrived during the upload stays.
                for report in sent {
                    if let index = ledger.crashes.firstIndex(of: report) { ledger.crashes.remove(at: index) }
                }
            }))
        }
        if let batch = pending.betaDiagnostics, let url = endpoints.betaDiagnostics, let body = try? Self.encoder.encode(batch) {
            let sent = batch.days.map { DayKey(day: $0.day, environment: $0.environment) }
            work.append((url, body, { ledger in
                ledger.days.removeAll { sent.contains(DayKey(day: $0.day, environment: $0.environment)) }
            }))
        }
        guard !work.isEmpty else { return 0 }
        change { $0.lastUpload = at }
        var sent = 0
        for (url, body, forget) in work {
            do {
                try await uploader.upload(body, to: url)
                change(forget)
                sent += 1
            } catch {
                continue
            }
        }
        return sent
    }

    /// Checks for an upload now and then every `interval`, until the task is cancelled.
    public func run(checkingEvery interval: Duration = .seconds(3_600)) async {
        while !Task.isCancelled {
            await uploadIfDue()
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: Keeping

    private struct DayKey: Equatable, Sendable {
        var day: DayStamp
        var environment: ReportEnvironment
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    private func discardWhatIsOff() {
        let crash = preferences.crashReports
        let beta = preferences.betaDiagnostics
        change { ledger in
            if !crash { ledger.crashes = [] }
            if !beta { ledger.days = [] }
            if !crash && !beta { ledger.lastUpload = nil }
        }
    }

    private func change(_ body: (inout Ledger) -> Void) {
        ledger.withLock { ledger in
            let before = ledger
            body(&ledger)
            guard ledger != before else { return }
            storage.set(try? JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
        }
    }

    private static func append(_ report: CrashReport, to ledger: inout Ledger) {
        ledger.crashes.append(report)
        if ledger.crashes.count > crashLimit { ledger.crashes.removeFirst(ledger.crashes.count - crashLimit) }
    }

    private static func update(
        _ ledger: inout Ledger,
        day: DayStamp,
        environment: ReportEnvironment,
        _ body: (inout DailyDiagnostics) -> Void
    ) {
        if let index = ledger.days.lastIndex(where: { $0.day == day && $0.environment == environment }) {
            body(&ledger.days[index])
        } else {
            var record = DailyDiagnostics(environment: environment, day: day)
            body(&record)
            ledger.days.append(record)
            if ledger.days.count > dayLimit { ledger.days.removeFirst(ledger.days.count - dayLimit) }
        }
    }
}
