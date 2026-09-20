import Foundation
import Yams

/// `Tests/traceability.yaml`. The file's header comment documents the format.
public struct TraceabilityFile: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        /// Absent for `sections`, which have no priority of their own.
        public var priority: String?
        public var milestone: String
        public var completes: String?
        public var tests: [String]
        public var note: String?

        public init(
            priority: String? = nil,
            milestone: String,
            completes: String? = nil,
            tests: [String] = [],
            note: String? = nil
        ) {
            self.priority = priority
            self.milestone = milestone
            self.completes = completes
            self.tests = tests
            self.note = note
        }
    }

    public static let relativePath = "Tests/traceability.yaml"

    public var schema: Int
    public var currentMilestone: String
    public var requirements: [String: Entry]
    public var sections: [String: Entry]

    enum CodingKeys: String, CodingKey {
        case schema
        case currentMilestone = "current_milestone"
        case requirements
        case sections
    }

    public init(schema: Int = 1, currentMilestone: String, requirements: [String: Entry], sections: [String: Entry] = [:]) {
        self.schema = schema
        self.currentMilestone = currentMilestone
        self.requirements = requirements
        self.sections = sections
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        currentMilestone = try container.decode(String.self, forKey: .currentMilestone)
        requirements = try container.decode([String: Entry].self, forKey: .requirements)
        sections = try container.decodeIfPresent([String: Entry].self, forKey: .sections) ?? [:]
    }

    public static func load(yaml: String) throws -> TraceabilityFile {
        try YAMLDecoder().decode(TraceabilityFile.self, from: yaml)
    }

    public static func load(repositoryRoot: URL) throws -> TraceabilityFile {
        try load(yaml: String(contentsOf: repositoryRoot.appending(path: relativePath), encoding: .utf8))
    }
}

/// Milestones in the order they close. `M0` has no requirements of its own; it is where the file starts.
public enum Milestone {
    public static let ordered = ["M0", "M1", "M2", "M3", "M4", "M5", "M6", "1.x", "post-1.0"]
    /// Values a requirement may land in.
    public static let assignable = Array(ordered.dropFirst())

    /// Whether work landing in `milestone` is due once `current` has closed.
    public static func isDue(_ milestone: String, at current: String) -> Bool {
        guard let due = ordered.firstIndex(of: milestone), let now = ordered.firstIndex(of: current) else { return false }
        return due <= now
    }
}
