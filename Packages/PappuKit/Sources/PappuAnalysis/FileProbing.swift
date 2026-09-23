import Foundation

/// Whether a path exists, which is the last half of FLT-2's file-path rule: a path that is not on this
/// Mac is text that looks like a path, and Reveal in Finder would fail on it.
///
/// A seam for two reasons. It is the only part of the analyser that touches the world, so a test can be
/// a pure function over a set of paths; and it is the only part that can block — a stat against a
/// network volume that has gone away takes as long as the mount's timeout, which is why
/// `ContentAnalyzer` caps both the number of checks and the time they may take between them.
public protocol FileProbing: Sendable {
    func exists(atPath path: String) -> Bool
}

public struct SystemFileProbe: FileProbing {
    public init() {}

    public func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// Answers no to everything, for the callers that have no business touching the disk.
public struct NoFileProbe: FileProbing {
    public init() {}

    public func exists(atPath path: String) -> Bool { false }
}
