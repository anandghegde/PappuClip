import Foundation

/// Finds requirement IDs in the design documents, so the traceability file cannot drift from them.
public struct RequirementIDScanner: Sendable {
    public static let families = [
        "ACT", "BAR", "FLT", "ALM", "EXM", "SYN", "SCR", "ONB", "DIA", "RUN",
        "CFG", "FMT", "JS", "DEV", "SEC", "DIR", "STORE", "PUB", "CAT", "DIF",
    ]

    public struct Mention: Sendable, Equatable {
        public var file: String
        public var line: Int
    }

    public init() {}

    /// The current documents only; `docs/archive` holds superseded versions with retired IDs.
    public func documents(repositoryRoot: URL) throws -> [URL] {
        try ["docs", "docs/spec"].flatMap { folder in
            try FileManager.default
                .contentsOfDirectory(at: repositoryRoot.appending(path: folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
        }
        .sorted { $0.path < $1.path }
    }

    public func scan(repositoryRoot: URL) throws -> [String: Mention] {
        var found: [String: Mention] = [:]
        for url in try documents(repositoryRoot: repositoryRoot) {
            let name = url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)
            for (id, mention) in scan(text: text, file: name) where found[id] == nil {
                found[id] = mention
            }
        }
        return found
    }

    /// First mention of each ID. `ACT-10a–j` yields `ACT-10a`; the parts of a range are all defined
    /// in their own table rows, so ranges need no expansion.
    public func scan(text: String, file: String) -> [String: Mention] {
        let pattern = try! Regex("\\b(?:\(Self.families.joined(separator: "|")))-[0-9]+[a-z]?\\b")
        var found: [String: Mention] = [:]
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for match in line.matches(of: pattern) {
                let id = String(line[match.range])
                if found[id] == nil { found[id] = Mention(file: file, line: index + 1) }
            }
        }
        return found
    }

    /// `ACT-10a` → `ACT-10`; nil for an ID without a letter.
    public static func parent(of id: String) -> String? {
        guard let last = id.last, last.isLetter, last.isLowercase else { return nil }
        return String(id.dropLast())
    }
}
