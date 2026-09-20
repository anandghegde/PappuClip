import Foundation
import PappuDevTools
import Testing

@Suite struct RequirementIDScannerTests {
    @Test func findsIDsWithAndWithoutLetters() {
        let text = """
        | ACT-10a | Snapshot every pasteboard item. | P0 |
        See ACT-10a–j, JS-16 and STORE-2. Not an ID: FOO-1, ACT-x, M1, P1.x.
        """
        let found = RequirementIDScanner().scan(text: text, file: "docs/x.md")
        #expect(Set(found.keys) == ["ACT-10a", "JS-16", "STORE-2"])
        #expect(found["ACT-10a"]?.file == "docs/x.md")
        #expect(found["ACT-10a"]?.line == 1)
        #expect(found["JS-16"]?.line == 2)
    }

    @Test func parentStripsOneLetter() {
        #expect(RequirementIDScanner.parent(of: "ACT-10a") == "ACT-10")
        #expect(RequirementIDScanner.parent(of: "ACT-10") == nil)
    }
}

@Suite struct TraceabilityCheckerTests {
    private let tests: [String: Set<String>] = ["CoreTests": ["budgets", "clock"]]

    private func file(_ requirements: [String: TraceabilityFile.Entry], current: String = "M0") -> TraceabilityFile {
        TraceabilityFile(currentMilestone: current, requirements: requirements)
    }

    private func check(
        _ file: TraceabilityFile,
        documented: Set<String>,
        manualFileExists: (String) -> Bool = { _ in true },
        milestone: String? = nil
    ) -> TraceabilityChecker.Report {
        TraceabilityChecker().check(
            file: file, documented: documented, tests: tests, manualFileExists: manualFileExists, milestone: milestone
        )
    }

    @Test func aConsistentFilePasses() {
        let report = check(
            file([
                "ACT-1": .init(priority: "P0", milestone: "M1", tests: ["CoreTests/clock"]),
                "ACT-10a": .init(priority: "P0", milestone: "M1"),
                "BAR-1": .init(priority: "P0", milestone: "M1", completes: "M4"),
                "SYN-1": .init(priority: "P1.x", milestone: "1.x"),
                "DIR-6": .init(priority: "P2", milestone: "post-1.0"),
            ]),
            documented: ["ACT-1", "ACT-10", "ACT-10a", "BAR-1", "SYN-1", "DIR-6"]
        )
        #expect(report.errors == [])
        #expect(report.requirementCount == 5)
        #expect(report.withTests == 1)
        #expect(report.due == 0)
    }

    @Test func documentsAndFileMustNameTheSameRequirements() {
        let report = check(
            file(["ACT-1": .init(priority: "P0", milestone: "M1"), "ACT-99": .init(priority: "P0", milestone: "M1")]),
            documented: ["ACT-1", "ACT-2"]
        )
        #expect(report.errors.count == 2)
        #expect(report.errors.contains { $0.hasPrefix("ACT-2 is in the design documents") })
        #expect(report.errors.contains { $0.hasPrefix("ACT-99 is in Tests/traceability.yaml but no design document") })
    }

    @Test func aGroupIsListedByItsPartsOnly() {
        let report = check(
            file(["ACT-10": .init(priority: "P0", milestone: "M1"), "ACT-10a": .init(priority: "P0", milestone: "M1")]),
            documented: ["ACT-10", "ACT-10a"]
        )
        #expect(report.errors == ["ACT-10 is listed both whole and in lettered parts; keep the parts"])
    }

    @Test func dueRequirementsNeedATest() {
        let entries: [String: TraceabilityFile.Entry] = [
            "ACT-1": .init(priority: "P0", milestone: "M1"),
            "ACT-2": .init(priority: "P0", milestone: "M1", tests: ["CoreTests/clock"]),
            "EXM-1": .init(priority: "P0", milestone: "M2"),
            "SYN-1": .init(priority: "P1.x", milestone: "1.x"),
        ]
        let documented: Set<String> = ["ACT-1", "ACT-2", "EXM-1", "SYN-1"]

        #expect(check(file(entries), documented: documented).passed)
        let atM1 = check(file(entries, current: "M1"), documented: documented)
        #expect(atM1.errors == ["ACT-1 (P0) landed in M1 and has no test"])
        #expect(atM1.due == 2)
        // The override answers "what would closing M2 need?" without editing the file.
        #expect(check(file(entries), documented: documented, milestone: "M2").errors.count == 2)
    }

    @Test func testReferencesMustResolve() {
        let report = check(
            file(["ACT-1": .init(priority: "P0", milestone: "M1", tests: [
                "CoreTests/clock", "CoreTests/missing", "NoSuchTests/clock", "noSlash",
                "manual:Tests/manual/there.md", "manual:Tests/manual/gone.md",
            ])]),
            documented: ["ACT-1"],
            manualFileExists: { $0 == "Tests/manual/there.md" }
        )
        #expect(report.errors == [
            "ACT-1: test target CoreTests has no function 'missing'",
            "ACT-1: test target 'NoSuchTests' does not exist",
            "ACT-1: test 'noSlash' is not of the form TestTarget/functionName",
            "ACT-1: manual checklist 'Tests/manual/gone.md' does not exist",
        ])
    }

    @Test func prioritiesAndMilestonesAreValidated() {
        let report = check(
            file([
                "ACT-1": .init(priority: "P3", milestone: "M1"),
                "ACT-2": .init(priority: "P0", milestone: "M9"),
                "ACT-3": .init(priority: "P0", milestone: "1.x"),
                "ACT-4": .init(priority: "P2", milestone: "M2"),
                "ACT-5": .init(priority: "P0", milestone: "M3", completes: "M3"),
            ]),
            documented: ["ACT-1", "ACT-2", "ACT-3", "ACT-4", "ACT-5"]
        )
        #expect(report.errors.count == 5)
        #expect(report.errors.contains("ACT-3: priority P0 does not fit milestone 1.x"))
        #expect(report.errors.contains("ACT-4: priority P2 does not fit milestone M2"))
        #expect(report.errors.contains("ACT-5: completes 'M3' must be a milestone after M3"))
    }

    @Test func yamlDecodes() throws {
        let file = try TraceabilityFile.load(yaml: """
        schema: 1
        current_milestone: M0
        requirements:
          ACT-1: { priority: P0, milestone: M1, tests: [] }
          BAR-1: { priority: P0, milestone: M1, completes: M4, tests: [CoreTests/clock], note: "Later." }
        sections:
          "PRD §11.1 latency budgets": { milestone: M1, tests: [CoreTests/budgets] }
        """)
        #expect(file.currentMilestone == "M0")
        #expect(file.requirements["BAR-1"] == .init(priority: "P0", milestone: "M1", completes: "M4", tests: ["CoreTests/clock"], note: "Later."))
        #expect(file.sections.values.first?.priority == nil)
    }

    /// The real file, the real documents and the real test sources.
    @Test func theRepositoryIsConsistent() throws {
        let root = try RepositoryRoot.find(from: URL(filePath: #filePath))
        let report = try TraceabilityChecker().check(repositoryRoot: root)
        #expect(report.errors == [])
        #expect(report.requirementCount > 200)
    }
}
