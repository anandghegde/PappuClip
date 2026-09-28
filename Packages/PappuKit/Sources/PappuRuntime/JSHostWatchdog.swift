import Darwin
import Foundation

/// The JavaScript helper's CPU and memory, watched while extension code runs in it (SEC-2,
/// architecture §10.7).
///
/// JavaScriptCore's execution-time limit is private API, so the limit is on the process. While any
/// world is running, loading or being described, `JSHostClient` samples the helper every `interval`
/// and hands each sample to a `Meter`. An overrun kills the helper; the client charges the extensions
/// that had code running with it, as it does a crash.
///
/// **There is no fixed timeout** (SEC-2). A script that waits — on the network, on a Shortcut, on the
/// user — costs no CPU and is never stopped by this; the user can cancel it. Only a script that keeps a
/// core busy for `cpuSpan` without a break, or a helper whose footprint passes `memoryLimit`, is.
public enum JSHostWatchdog {
    public struct Limits: Sendable, Equatable {
        /// The helper's physical footprint, as Activity Monitor's Memory column counts it.
        public var memoryLimit: UInt64
        /// How long the helper may keep a core busy without a break.
        public var cpuSpan: Duration
        /// The share of one core, between two samples, that counts as busy.
        public var busyShare: Double
        /// How often the helper is sampled while code runs in it.
        public var interval: Duration

        public init(memoryLimit: UInt64, cpuSpan: Duration, busyShare: Double = 0.9, interval: Duration = .milliseconds(500)) {
            self.memoryLimit = memoryLimit
            self.cpuSpan = cpuSpan
            self.busyShare = busyShare
            self.interval = interval
        }

        /// 1.5 GB and 30 s. Far above what any corpus extension uses, which stays under 100 MB and
        /// finishes its CPU work in well under a second; the limits are for runaways, not for budgets.
        public static let standard = Limits(memoryLimit: 1_536 * 1_024 * 1_024, cpuSpan: .seconds(30))
    }

    /// What one sample found.
    public struct Usage: Sendable, Equatable {
        /// User and system time since the helper started.
        public var cpuTime: Duration
        /// Physical footprint, in bytes.
        public var footprint: UInt64

        public init(cpuTime: Duration, footprint: UInt64) {
            self.cpuTime = cpuTime
            self.footprint = footprint
        }
    }

    /// Why the helper was stopped.
    public enum Overrun: Sendable, Equatable {
        case memory(footprint: UInt64, limit: UInt64)
        case cpu(busyFor: Duration)

        /// For the Debug Console, in the words the rest of its lines use. Never anything the script
        /// said or saw.
        public var explanation: String {
            switch self {
            case .memory(let footprint, let limit):
                "The JavaScript helper used \(Self.megabytes(footprint)) of memory, over the limit of \(Self.megabytes(limit)), and was restarted."
            case .cpu(let busy):
                "The JavaScript helper kept a processor busy for \(Int(busy.components.seconds)) s without a break, and was restarted."
            }
        }

        private static func megabytes(_ bytes: UInt64) -> String {
            "\(bytes / (1_024 * 1_024)) MB"
        }
    }

    /// The rule, apart from the sampling, so a test can feed it samples.
    public struct Meter: Sendable {
        public let limits: Limits
        private var last: (at: ContinuousClock.Instant, cpu: Duration)?
        private var busySince: ContinuousClock.Instant?

        public init(limits: Limits) {
            self.limits = limits
        }

        /// The overrun this sample shows, if any.
        public mutating func observe(_ usage: Usage, at instant: ContinuousClock.Instant) -> Overrun? {
            defer { last = (instant, usage.cpuTime) }
            if usage.footprint > limits.memoryLimit {
                return .memory(footprint: usage.footprint, limit: limits.memoryLimit)
            }
            guard let last else { return nil }
            let wall = last.at.duration(to: instant)
            guard wall > .zero else { return nil }
            let used = usage.cpuTime - last.cpu
            if used >= wall * limits.busyShare {
                let since = busySince ?? last.at
                busySince = since
                let busy = since.duration(to: instant)
                if busy >= limits.cpuSpan { return .cpu(busyFor: busy) }
            } else {
                busySince = nil
            }
            return nil
        }
    }
}

/// A connection whose helper is a process the app can sample.
public protocol JSHostProcess: AnyObject {
    var processIdentifier: pid_t { get }
}

/// How the client reads the helper's usage. Nil when there is no process to read — a helper in this
/// process, in the tests — and the watchdog then does not watch that connection.
public protocol JSHostUsageSampling: Sendable {
    func usage(of connection: any JSHostConnection) -> JSHostWatchdog.Usage?
}

/// `proc_pid_rusage` on the helper's process ID, which the connection learned when it was opened.
public struct ProcessUsageSampler: JSHostUsageSampling {
    public init() {}

    public func usage(of connection: any JSHostConnection) -> JSHostWatchdog.Usage? {
        guard let process = connection as? any JSHostProcess else { return nil }
        return Self.usage(of: process.processIdentifier)
    }

    /// The process's CPU time and footprint, or nil when it cannot be read — it has gone, or it is not
    /// ours to read.
    public static func usage(of processID: pid_t) -> JSHostWatchdog.Usage? {
        guard processID > 0 else { return nil }
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
            }
        }
        guard read == 0 else { return nil }
        // The times are in Mach absolute units, which are nanoseconds only on Intel.
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let ticks = info.ri_user_time + info.ri_system_time
        let nanoseconds = ticks.multipliedReportingOverflow(by: UInt64(base.numer)).partialValue / UInt64(max(base.denom, 1))
        return JSHostWatchdog.Usage(
            cpuTime: .nanoseconds(Int64(clamping: nanoseconds)),
            footprint: info.ri_phys_footprint
        )
    }
}
