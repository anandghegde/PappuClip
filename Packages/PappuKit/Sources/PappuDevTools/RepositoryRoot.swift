import Foundation

public enum RepositoryRoot {
    public struct NotFound: Error, CustomStringConvertible {
        public var start: String
        public var description: String {
            "No \(TraceabilityFile.relativePath) at or above \(start). Pass --root."
        }
    }

    /// Walks up from `start` to the directory that holds `Tests/traceability.yaml`, so the tools work
    /// from the repository root and from `Packages/PappuKit` alike.
    public static func find(from start: URL = URL(filePath: FileManager.default.currentDirectoryPath)) throws -> URL {
        var candidate = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: candidate.appending(path: TraceabilityFile.relativePath).path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { throw NotFound(start: start.path) }
            candidate = parent
        }
    }
}
