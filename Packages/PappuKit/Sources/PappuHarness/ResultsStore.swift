import Foundation

/// Reads and writes `RunResult` files under `Tests/results/<runID>/`.
///
/// One file per run and machine, never overwritten, so the per-release comparison in M6 has history.
public struct ResultsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Tests/results` under a repository root.
    public init(repositoryRoot: URL) {
        directory = repositoryRoot.appending(path: "Tests/results", directoryHint: .isDirectory)
    }

    @discardableResult
    public func write(_ result: RunResult) throws -> URL {
        let folder = directory.appending(path: result.runID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: Self.fileName(for: result))
        try Self.encoder.encode(result).write(to: url, options: .atomic)
        return url
    }

    public static func read(_ url: URL) throws -> RunResult {
        try decoder.decode(RunResult.self, from: Data(contentsOf: url))
    }

    static func fileName(for result: RunResult) -> String {
        let stamp = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
            .time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted)
            .format(result.startedAt)
        return "\(stamp)-macOS\(result.environment.osVersion)-\(result.environment.architecture).json"
    }

    // Sorted keys keep diffs between runs readable.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension RunResult {
    /// A plain-text digest for the terminal and for pasting into a spike report.
    public func summaryText() -> String {
        var lines = [
            "\(title) [\(runID)]",
            "  \(startedAt.formatted(.iso8601))  macOS \(environment.osVersion) (\(environment.osBuild))  "
                + "\(environment.hardwareModel) \(environment.architecture)",
            "  signing: \(environment.signing.map { $0.isAdHoc ? "ad-hoc" : ($0.authority ?? "signed") } ?? "unsigned")"
                + "  accessibility: \(environment.accessibilityTrusted ? "trusted" : "not trusted")",
        ]
        if !findings.isEmpty {
            lines.append("")
            lines += findings.map { "  [\($0.outcome.rawValue)] \($0.key)\(Self.describe($0.labels)): \($0.detail)" }
        }
        if !measurements.isEmpty {
            lines.append("")
            lines += measurements.map { measurement in
                let name = "  \(measurement.name)\(Self.describe(measurement.labels))"
                guard let summary = measurement.summary else { return "\(name): no samples" }
                return name + String(
                    format: ": n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f %@",
                    summary.count, summary.p50, summary.p95, summary.p99, summary.max, measurement.unit
                )
            }
        }
        if !notes.isEmpty {
            lines += ["", "  notes: \(notes)"]
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ labels: [String: String]) -> String {
        guard !labels.isEmpty else { return "" }
        return " {" + labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
    }
}
