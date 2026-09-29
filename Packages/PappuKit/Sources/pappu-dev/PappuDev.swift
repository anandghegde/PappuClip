import ArgumentParser
import Foundation
import PappuCLI
import PappuDevTools
import PappuHarness

@main
struct PappuDev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pappu-dev",
        abstract: "Repository tooling for PappuClip contributors and CI. Not shipped to users.",
        subcommands: [Trace.self, Results.self, Corpus.self]
    )
}

struct RootOption: ParsableArguments {
    @Option(help: "Repository root. Default: found by walking up from the current directory.")
    var root: String?

    func resolve() throws -> URL {
        try root.map { URL(filePath: $0) } ?? RepositoryRoot.find()
    }
}

struct Trace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Requirement traceability (Tests/traceability.yaml).",
        subcommands: [Check.self, Stats.self]
    )

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Fail if the file and the design documents disagree, a test reference is dead, or a due requirement has no test."
        )

        @OptionGroup var root: RootOption

        @Option(help: "Check as if this milestone had closed, to see what closing it still needs.")
        var milestone: String?

        func run() throws {
            let report = try TraceabilityChecker().check(repositoryRoot: root.resolve(), milestone: milestone)
            report.errors.forEach { print("error: \($0)") }
            print("\(report.requirementCount) requirements, \(report.withTests) with tests, \(report.due) due, \(report.errors.count) errors")
            if !report.passed { throw ExitCode.failure }
        }
    }

    struct Stats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Requirements and test coverage per milestone.")

        @OptionGroup var root: RootOption

        func run() throws {
            let file = try TraceabilityFile.load(repositoryRoot: root.resolve())
            print("current milestone: \(file.currentMilestone)")
            for milestone in Milestone.assignable {
                let entries = file.requirements.values.filter { $0.milestone == milestone }
                let tested = entries.count { !$0.tests.isEmpty }
                let p0 = entries.count { $0.priority == "P0" }
                print("  \(milestone.padding(toLength: 9, withPad: " ", startingAt: 0)) \(entries.count) requirements (\(p0) P0), \(tested) with tests")
            }
        }
    }
}

struct Results: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Harness results (Tests/results).",
        subcommands: [Summarize.self]
    )

    struct Summarize: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a digest of one or more result files.")

        @Argument(help: "Result JSON files.")
        var files: [String]

        func run() throws {
            for file in files {
                print(try ResultsStore.read(URL(filePath: file)).summaryText())
                print()
            }
        }
    }
}

struct Corpus: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The frozen extension corpus (Tests/corpus).",
        subcommands: [Load.self, Functional.self]
    )

    /// PRD §3.3: the corpus's functional pass rate, written to `Tests/results/corpus-functional/`.
    struct Functional: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run every extension in the corpus headless, report the functional pass rate, and write it to Tests/results.",
            discussion: """
            Every package counts. Blocked, load-only, untested and failed packages are reported separately and \
            none of them is a pass. Nothing is pasted, opened, pressed or sent.
            """
        )

        @OptionGroup var root: RootOption

        @Option(help: "Corpus directory. Default: Tests/corpus under the repository root.")
        var corpus: String?

        @Option(help: "Seconds each JavaScript action may run.")
        var timeout: Int = 15

        @Flag(help: "Print every package that did not pass, and why.")
        var verbose = false

        @Flag(help: "Print the rate without writing a result file.")
        var dryRun = false

        func run() async throws {
            let repository = try root.resolve()
            let corpusURL = corpus.map { URL(filePath: $0) } ?? repository.appending(path: "Tests/corpus")
            let packages = CorpusLoader.discover(in: corpusURL)
            guard !packages.isEmpty else {
                print("error: no extensions under \(corpusURL.path); is the submodule checked out?")
                throw ExitCode.failure
            }
            let started = Date()
            let report = await CorpusFunctional(timeout: .seconds(timeout)).run(corpus: corpusURL, packages: packages)
            if verbose {
                for package in report.packages where package.verdict != .passed {
                    print("\(package.verdict.rawValue): \(package.path): \(package.detail)")
                }
            }
            print(report.rateText)
            guard !dryRun else { return }
            let result = CorpusFunctionalResult.make(
                report, corpus: corpusURL, startedAt: started, durationSeconds: Date().timeIntervalSince(started), timeout: timeout
            )
            let url = try ResultsStore(repositoryRoot: repository).write(result)
            print("wrote \(url.path)")
        }
    }

    struct Load: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Load every extension in the corpus, report the load rate, and fail on an unexpected failure or a stale expectation."
        )

        @OptionGroup var root: RootOption

        @Option(help: "Corpus directory. Default: Tests/corpus under the repository root.")
        var corpus: String?

        @Flag(help: "Print every failure's errors, expected ones included.")
        var verbose = false

        @Flag(help: "Print every warning.")
        var warnings = false

        func run() throws {
            let repository = try root.resolve()
            let corpusURL = corpus.map { URL(filePath: $0) } ?? repository.appending(path: "Tests/corpus")
            let expectedText = (try? String(
                contentsOf: repository.appending(path: CorpusLoader.expectedFailuresPath), encoding: .utf8
            )) ?? ""
            let report = CorpusLoader.run(
                corpus: corpusURL,
                expectedFailures: CorpusLoader.parseExpectedFailures(expectedText)
            )
            guard !report.entries.isEmpty else {
                print("error: no extensions under \(corpusURL.path); is the submodule checked out?")
                throw ExitCode.failure
            }
            for entry in verbose ? report.failed : report.unexpectedFailures {
                let expected = report.expectedFailures[entry.path].map { " (expected: \($0))" } ?? ""
                print("\(report.expectedFailures[entry.path] == nil ? "error" : "note"): \(entry.path)\(expected)")
                if case .failed(let errors) = entry.outcome {
                    errors.forEach { print("    \($0)") }
                }
            }
            if warnings {
                report.allWarnings.forEach { print("warning: \($0.path): \($0.warning)") }
            }
            for path in report.staleExpectations {
                print("error: \(path) is listed in \(CorpusLoader.expectedFailuresPath) but loads (or is gone); remove it")
            }
            print(report.rateText)
            if !report.passed { throw ExitCode.failure }
        }
    }
}
