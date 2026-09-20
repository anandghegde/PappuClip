import Foundation

/// Enforces the definition of done's traceability rule (implementation plan §2).
public struct TraceabilityChecker: Sendable {
    public struct Report: Sendable, Equatable {
        public var errors: [String] = []
        public var requirementCount = 0
        public var withTests = 0
        /// P0 and P1 requirements due at the checked milestone.
        public var due = 0

        public var passed: Bool { errors.isEmpty }
    }

    public static let priorities = ["P0", "P1", "P1.x", "P2"]
    public static let manualPrefix = "manual:"
    static let testsDirectory = "Packages/PappuKit/Tests"

    public init() {}

    public func check(repositoryRoot: URL, milestone override: String? = nil) throws -> Report {
        try check(
            file: TraceabilityFile.load(repositoryRoot: repositoryRoot),
            documented: Set(RequirementIDScanner().scan(repositoryRoot: repositoryRoot).keys),
            tests: Self.indexTests(repositoryRoot: repositoryRoot),
            manualFileExists: { FileManager.default.fileExists(atPath: repositoryRoot.appending(path: $0).path) },
            milestone: override
        )
    }

    /// - Parameters:
    ///   - documented: Every ID the design documents mention.
    ///   - tests: Test function names by test target.
    public func check(
        file: TraceabilityFile,
        documented: Set<String>,
        tests: [String: Set<String>],
        manualFileExists: (String) -> Bool = { _ in true },
        milestone override: String? = nil
    ) -> Report {
        var report = Report()
        let current = override ?? file.currentMilestone
        if !Milestone.ordered.contains(current) {
            report.errors.append("current_milestone '\(current)' is not one of \(Milestone.ordered.joined(separator: ", "))")
        }

        // Documents and file must name the same requirements. A bare ID such as ACT-10 heads a group
        // of lettered parts and is covered by them.
        let listed = Set(file.requirements.keys)
        let coveredParents = Set(listed.compactMap(RequirementIDScanner.parent(of:)))
        for id in documented.subtracting(listed).subtracting(coveredParents).sorted() {
            report.errors.append("\(id) is in the design documents but not in \(TraceabilityFile.relativePath)")
        }
        for id in listed.subtracting(documented).sorted() {
            report.errors.append("\(id) is in \(TraceabilityFile.relativePath) but no design document mentions it")
        }
        for id in listed.intersection(coveredParents).sorted() {
            report.errors.append("\(id) is listed both whole and in lettered parts; keep the parts")
        }

        let entries = file.requirements.map { ($0.key, $0.value, true) } + file.sections.map { ($0.key, $0.value, false) }
        for (id, entry, isRequirement) in entries.sorted(by: { $0.0 < $1.0 }) {
            if isRequirement {
                report.requirementCount += 1
                if !entry.tests.isEmpty { report.withTests += 1 }
                validatePriority(of: id, entry, into: &report)
            }
            validateMilestones(of: id, entry, into: &report)

            for reference in entry.tests {
                if let problem = resolve(reference, tests: tests, manualFileExists: manualFileExists) {
                    report.errors.append("\(id): \(problem)")
                }
            }

            let gated = entry.priority == "P0" || entry.priority == "P1"
            if isRequirement, gated, Milestone.isDue(entry.milestone, at: current) {
                report.due += 1
                if entry.tests.isEmpty {
                    report.errors.append("\(id) (\(entry.priority ?? "")) landed in \(entry.milestone) and has no test")
                }
            }
        }
        return report
    }

    private func validatePriority(of id: String, _ entry: TraceabilityFile.Entry, into report: inout Report) {
        guard let priority = entry.priority, Self.priorities.contains(priority) else {
            report.errors.append("\(id): priority must be one of \(Self.priorities.joined(separator: ", "))")
            return
        }
        // P0 and P1 are the 1.0 scope (PRD §6), so they cannot be planned past M6.
        let inOnePointZero = Milestone.isDue(entry.milestone, at: "M6")
        if (priority == "P0" || priority == "P1") != inOnePointZero, Milestone.assignable.contains(entry.milestone) {
            report.errors.append("\(id): priority \(priority) does not fit milestone \(entry.milestone)")
        }
    }

    private func validateMilestones(of id: String, _ entry: TraceabilityFile.Entry, into report: inout Report) {
        guard Milestone.assignable.contains(entry.milestone) else {
            report.errors.append("\(id): milestone '\(entry.milestone)' is not one of \(Milestone.assignable.joined(separator: ", "))")
            return
        }
        guard let completes = entry.completes else { return }
        if !Milestone.assignable.contains(completes) || Milestone.isDue(completes, at: entry.milestone) {
            report.errors.append("\(id): completes '\(completes)' must be a milestone after \(entry.milestone)")
        }
    }

    private func resolve(
        _ reference: String,
        tests: [String: Set<String>],
        manualFileExists: (String) -> Bool
    ) -> String? {
        if reference.hasPrefix(Self.manualPrefix) {
            let path = String(reference.dropFirst(Self.manualPrefix.count))
            return manualFileExists(path) ? nil : "manual checklist '\(path)' does not exist"
        }
        let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "test '\(reference)' is not of the form TestTarget/functionName" }
        guard let functions = tests[parts[0]] else { return "test target '\(parts[0])' does not exist" }
        return functions.contains(parts[1]) ? nil : "test target \(parts[0]) has no function '\(parts[1])'"
    }

    /// Reads test sources rather than asking the build, so the check runs without compiling anything.
    public static func indexTests(repositoryRoot: URL) throws -> [String: Set<String>] {
        let root = repositoryRoot.appending(path: testsDirectory)
        let declaration = try! Regex("\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*[(<]")
        var index: [String: Set<String>] = [:]
        for target in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        where (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            var functions: Set<String> = []
            let files = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for match in source.matches(of: declaration) {
                    if let name = match.output[1].substring { functions.insert(String(name)) }
                }
            }
            index[target.lastPathComponent] = functions
        }
        return index
    }
}
