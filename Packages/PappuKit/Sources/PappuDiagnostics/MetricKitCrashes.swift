import Foundation
import MetricKit

/// The crashed thread of a MetricKit call-stack tree, as binaries and offsets (DIA-3).
///
/// MetricKit's JSON also names each binary and gives its load address; neither is kept. The name can
/// be a third-party image loaded into the process, and the address says where the system put it.
public enum CallStackFrames {
    /// - Parameter json: `MXCallStackTree.jsonRepresentation()`. Nothing that is not a call-stack tree
    ///   gives frames.
    public static func crashedThread(in json: Data) -> [CrashFrame] {
        guard let tree = try? JSONDecoder().decode(Tree.self, from: json) else { return [] }
        let stacks = tree.callStacks ?? []
        guard let stack = stacks.first(where: { $0.threadAttributed == true }) ?? stacks.first,
              var frame = stack.callStackRootFrames?.first
        else { return [] }
        var frames: [CrashFrame] = []
        while frames.count < CrashReport.frameLimit {
            frames.append(CrashFrame(
                binary: frame.binaryUUID.flatMap(UUID.init(uuidString:)),
                offset: frame.offsetIntoBinaryTextSegment ?? 0
            ))
            guard let next = frame.subFrames?.first else { break }
            frame = next
        }
        return frames
    }

    // Only the keys read. The names and addresses are not even decoded.
    private struct Tree: Decodable {
        var callStacks: [Stack]?
    }

    private struct Stack: Decodable {
        var threadAttributed: Bool?
        var callStackRootFrames: [Frame]?
    }

    private struct Frame: Decodable {
        var binaryUUID: String?
        var offsetIntoBinaryTextSegment: UInt64?
        var subFrames: [Frame]?
    }
}

/// Hands MetricKit's crash diagnostics to the reporter (DIA-3). MetricKit delivers a crash at the next
/// launch; hangs, CPU and disk diagnostics are not taken. Subscribed only while crash reports are on.
public final class MetricKitCrashSource: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let reporter: DiagnosticsReporter
    private let subscribed = NSLock()
    private var isSubscribed = false

    public init(reporter: DiagnosticsReporter) {
        self.reporter = reporter
    }

    /// Subscribes while crash reports are on, and follows the switch.
    public func start() {
        follow()
        reporter.preferences.onChange { [weak self] in self?.follow() }
    }

    private func follow() {
        let on = reporter.preferences.crashReports
        subscribed.withLock {
            guard on != isSubscribed else { return }
            isSubscribed = on
            if on { MXMetricManager.shared.add(self) } else { MXMetricManager.shared.remove(self) }
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                // `terminationReason`, `virtualMemoryRegionInfo` and `exceptionReason` are free text and
                // are never read.
                reporter.appCrashed(
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue,
                    frames: CallStackFrames.crashedThread(in: crash.callStackTree.jsonRepresentation())
                )
            }
        }
    }
}
