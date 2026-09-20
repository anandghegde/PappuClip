import ArgumentParser
import Foundation
import PappuDevTools
import PappuHarness

@main
struct PappuDev: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pappu-dev",
        abstract: "Repository tooling for PappuClip contributors and CI. Not shipped to users.",
        subcommands: [Trace.self, Results.self]
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
