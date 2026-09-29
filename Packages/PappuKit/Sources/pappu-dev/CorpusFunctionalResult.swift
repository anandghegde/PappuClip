import Foundation
import PappuCLI
import PappuCore
import PappuHarness

/// The corpus functional pass as a harness result (`Tests/results/corpus-functional/`), so that the
/// rate has history and M6 can compare it across releases.
enum CorpusFunctionalResult {
    static let runID = "corpus-functional"

    static func make(
        _ report: CorpusFunctional.Report,
        corpus: URL,
        startedAt: Date,
        durationSeconds: Double,
        timeout: Int
    ) -> RunResult {
        var parameters = [
            "packages": String(report.packages.count),
            "rate": String(format: "%.1f%%", report.rate * 100),
            "javascript-timeout-seconds": String(timeout),
            "corpus": "Tests/corpus",
        ]
        if let commit = commit(of: corpus) { parameters["corpus-commit"] = commit }
        for verdict in CorpusFunctional.Verdict.allCases {
            parameters[verdict.rawValue] = String(report.count(verdict))
        }
        for blocker in CorpusFunctional.Blocker.allCases {
            parameters["blocked-by-\(blocker.rawValue)"] = String(report.packages.count {
                $0.verdict == .blocked && $0.blockers.contains(blocker)
            })
        }

        let findings = [
            Finding(
                key: "functional-rate",
                outcome: report.rate >= 0.95 ? .confirmed : .refuted,
                detail: "PRD §3.3 asks for at least 95% of the corpus to work. " + report.rateText
            ),
        ] + report.packages.map { package in
            var labels = ["verdict": package.verdict.rawValue]
            if !package.blockers.isEmpty, package.verdict == .blocked {
                labels["blockers"] = package.blockers.map(\.rawValue).joined(separator: ",")
            }
            let kinds = Set(package.actions.map(\.kind.rawValue)).sorted()
            if !kinds.isEmpty { labels["kinds"] = kinds.joined(separator: ",") }
            return Finding(
                key: package.path,
                outcome: package.verdict == .passed ? .confirmed : (package.verdict == .failed ? .refuted : .inconclusive),
                detail: package.detail,
                labels: labels
            )
        }

        return RunResult(
            runID: runID,
            title: "Corpus functional pass",
            question: "What share of the frozen PopClip extensions corpus works, not just loads, when run headless? (PRD §3.3, implementation plan M3 week 7)",
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            environment: HarnessEnvironment.current(),
            budgets: .initial,
            parameters: parameters,
            measurements: [],
            findings: findings,
            log: [report.rateText],
            notes: """
            Denominator: every package in the corpus, including the ones that do not load. A package passes \
            only when every action it offers passes. JavaScript runs in the helper's own code against a \
            headless host with every grant, where network requests, scripts and system services are \
            refused (counted as blocked); URL actions pass when they expand to a URL and key presses when \
            every combo parses; AppleScript and shell scripts are not run (load-only); Services, \
            Shortcuts, app-specific actions and actions needing credentials are blocked.
            """
        )
    }

    /// The corpus submodule's commit, when git can say.
    private static func commit(of corpus: URL) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", corpus.path, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
