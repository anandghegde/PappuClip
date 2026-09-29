import Foundation

// What crash reports (DIA-3) and beta diagnostics (DIA-4) send, and nothing else.
//
// **Text-free by construction.** No type in this file has a `String` stored property, at any depth.
// Every field is an integer, a Boolean, a `UUID` or an enumeration with a closed list of cases, so
// there is nowhere for selected text, clipboard content, an extension's option values, an app's name or
// a bundle identifier to go — not by mistake and not by a later edit that forgets why. A test walks a
// fully populated instance of each with `Mirror` and fails on the first `String` it meets, and another
// checks that every string in the encoded JSON is an enumeration's code or a UUID.
//
// Nothing here identifies the Mac or the person: no persistent identifier, no serial, no host name. A
// report is dated to the day, never the moment.

/// A version as three numbers: `1.2.3`, or macOS `15.4.1`. Parsed from the bundle's and the system's
/// strings, never carried as one.
public struct VersionTriple: Codable, Sendable, Equatable, Hashable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `"1.2.3"`, `"1.2"` or `"1"`. Anything after a number that is not a dot ends it (`"1.0b2"` is 1.0),
    /// and something that is not a version at all is nil.
    public init?(parsing text: String) {
        let parts = text.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false).prefix(3).map { part in
            Int(part.prefix { $0.isASCII && $0.isNumber })
        }
        guard let major = parts.first ?? nil else { return nil }
        self.init(major, parts.count > 1 ? parts[1] ?? 0 : 0, parts.count > 2 ? parts[2] ?? 0 : 0)
    }
}

/// Where the build was published. Diagnostics (DIA-4) are offered only on `beta`.
public enum ReleaseChannel: String, Codable, Sendable, Equatable, CaseIterable {
    case release
    case beta
    /// Built from source, or by a developer: not a published build.
    case development
}

public enum CPUArchitecture: String, Codable, Sendable, Equatable, CaseIterable {
    case arm64
    case x86_64
    case other

    public static var current: CPUArchitecture {
        #if arch(arm64)
            .arm64
        #elseif arch(x86_64)
            .x86_64
        #else
            .other
        #endif
    }
}

/// What every report says about the build and the system it ran on (DIA-4: "with the app and macOS
/// version").
public struct ReportEnvironment: Codable, Sendable, Equatable, Hashable {
    public var app: VersionTriple
    /// `CFBundleVersion`, as a number.
    public var build: Int
    public var channel: ReleaseChannel
    public var macOS: VersionTriple
    public var architecture: CPUArchitecture

    public init(app: VersionTriple, build: Int, channel: ReleaseChannel, macOS: VersionTriple, architecture: CPUArchitecture) {
        self.app = app
        self.build = build
        self.channel = channel
        self.macOS = macOS
        self.architecture = architecture
    }

    /// Read from a bundle's `CFBundleShortVersionString` and `CFBundleVersion` and from the running
    /// system. A version the bundle does not spell as numbers is `0.0.0`, build 0: a report says less
    /// rather than carry the bundle's string.
    public static func current(bundle: Bundle = .main, channel: ReleaseChannel) -> ReportEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ReportEnvironment(
            app: (info["CFBundleShortVersionString"] as? String).flatMap(VersionTriple.init(parsing:)) ?? VersionTriple(0),
            build: (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0,
            channel: channel,
            macOS: VersionTriple(os.majorVersion, os.minorVersion, os.patchVersion),
            architecture: .current
        )
    }
}

/// A calendar day in the user's own time zone. Reports are dated to the day and never to the second,
/// so that a report cannot be matched against the moment someone used the app.
public struct DayStamp: Codable, Sendable, Equatable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    public static func < (lhs: DayStamp, rhs: DayStamp) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

// MARK: DIA-3: crash reports

/// Which process went away.
public enum CrashingProcess: String, Codable, Sendable, Equatable, CaseIterable {
    /// PappuClip itself, as MetricKit reported it at the next launch.
    case app
    /// PappuClipJSHost.xpc went away while an extension's code was running or loading in it (SEC-1d).
    /// Which extension is not said.
    case javaScriptHelper
}

/// One frame of the crashed thread, as a binary and an offset into it: enough to symbolicate against the
/// build's own dSYMs, and nothing the binary's name or path could add.
public struct CrashFrame: Codable, Sendable, Equatable {
    /// The Mach-O UUID of the image the frame is in. Nil when the system did not say.
    public var binary: UUID?
    /// Bytes from the start of that image's text segment.
    public var offset: UInt64

    public init(binary: UUID?, offset: UInt64) {
        self.binary = binary
        self.offset = offset
    }
}

/// One crash (DIA-3). Codes and frames only: MetricKit's termination reason and memory-region
/// description are free text written by the system and are dropped, as is every binary's name.
public struct CrashReport: Codable, Sendable, Equatable {
    /// The most frames a report keeps, from the top of the stack.
    public static let frameLimit = 64

    public var environment: ReportEnvironment
    public var day: DayStamp
    public var process: CrashingProcess
    /// The Mach exception type (`EXC_BAD_ACCESS` is 1), when there was one.
    public var exceptionType: Int?
    public var exceptionCode: Int?
    /// The signal (`SIGSEGV` is 11), when there was one.
    public var signal: Int?
    /// The crashed thread, innermost frame first.
    public var frames: [CrashFrame]

    public init(
        environment: ReportEnvironment,
        day: DayStamp,
        process: CrashingProcess,
        exceptionType: Int? = nil,
        exceptionCode: Int? = nil,
        signal: Int? = nil,
        frames: [CrashFrame] = []
    ) {
        self.environment = environment
        self.day = day
        self.process = process
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.frames = Array(frames.prefix(Self.frameLimit))
    }
}

/// What the crash-report endpoint receives: every crash held since the last upload.
public struct CrashReportBatch: Codable, Sendable, Equatable {
    public static let schema = 1
    public var schema: Int
    public var reports: [CrashReport]

    public init(reports: [CrashReport]) {
        schema = Self.schema
        self.reports = reports
    }
}

// MARK: DIA-4: beta diagnostics

/// A measured interval whose distribution is reported (PRD §11.1's budget).
public enum LatencyStage: String, Codable, Sendable, Equatable, CaseIterable {
    /// From the end of the gesture to the bar being shown: `AttemptRecord.elapsed` for an attempt that
    /// showed one.
    case selectionToBar
}

/// Counts of intervals by bucket. The buckets are fixed by the schema, so a count is all that is sent.
public struct LatencyHistogram: Codable, Sendable, Equatable {
    /// Upper bounds, in milliseconds, of every bucket but the last, which is everything above.
    public static let upperBoundsMs = [25, 50, 75, 100, 150, 200, 300, 500, 700]

    public var stage: LatencyStage
    /// One count per bucket: `upperBoundsMs.count + 1` of them.
    public var counts: [Int]

    public init(stage: LatencyStage) {
        self.stage = stage
        counts = Array(repeating: 0, count: Self.upperBoundsMs.count + 1)
    }

    public static func bucket(for duration: Duration) -> Int {
        let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return upperBoundsMs.firstIndex { ms < Double($0) } ?? upperBoundsMs.count
    }

    public mutating func record(_ duration: Duration) {
        counts[Self.bucket(for: duration)] += 1
    }

    public var total: Int { counts.reduce(0, +) }
}

/// One day of one build (DIA-4): how many times PappuClip was started, how many of those sessions ended
/// in a crash, how often the JavaScript helper went away under an extension, and how long bars took.
///
/// This is the only source of the crash-free sessions metric (PRD §3.3).
public struct DailyDiagnostics: Codable, Sendable, Equatable {
    public var environment: ReportEnvironment
    public var day: DayStamp
    public var sessions: Int
    /// Sessions that did not end cleanly: the app crashed, was force-quit or the Mac lost power.
    public var appCrashes: Int
    public var helperCrashes: Int
    public var latency: [LatencyHistogram]

    public init(environment: ReportEnvironment, day: DayStamp) {
        self.environment = environment
        self.day = day
        sessions = 0
        appCrashes = 0
        helperCrashes = 0
        latency = []
    }

    public mutating func record(_ duration: Duration, for stage: LatencyStage) {
        if let index = latency.firstIndex(where: { $0.stage == stage }) {
            latency[index].record(duration)
        } else {
            var histogram = LatencyHistogram(stage: stage)
            histogram.record(duration)
            latency.append(histogram)
        }
    }
}

/// What the beta-diagnostics endpoint receives: every finished day held since the last upload.
public struct DiagnosticsBatch: Codable, Sendable, Equatable {
    public static let schema = 1
    public var schema: Int
    public var days: [DailyDiagnostics]

    public init(days: [DailyDiagnostics]) {
        schema = Self.schema
        self.days = days
    }
}
