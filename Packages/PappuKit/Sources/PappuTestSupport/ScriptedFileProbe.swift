import PappuAnalysis
import Synchronization

/// A disk that holds exactly what a test says it holds, and remembers what was asked.
///
/// `ContentAnalyzer`'s file-path rule is "and it exists" (FLT-2), so the interesting cases are all
/// about which paths were tested and how many: that a path is resolved before it is looked up, that the
/// caps stop the looking, and that text with no path in it touches no disk at all.
public final class ScriptedFileProbe: FileProbing, Sendable {
    private let present: Mutex<Set<String>>
    private let asked = Mutex<[String]>([])
    /// Answered before the path is looked up, so a test can make the disk itself slow.
    private let cost = Mutex<(@Sendable () -> Void)?>(nil)

    public init(present: Set<String> = []) {
        self.present = Mutex(present)
    }

    /// Every path the analyser tested, in order and already resolved.
    public var askedFor: [String] { asked.withLock { $0 } }

    public func add(_ path: String) {
        present.withLock { _ = $0.insert(path) }
    }

    /// Runs on every check, before the answer. A test that advances a `ManualTimeSource` here makes
    /// each stat cost time, which is how the file budget is exercised without a real slow volume.
    public func onEachCheck(_ body: @escaping @Sendable () -> Void) {
        cost.withLock { $0 = body }
    }

    public func exists(atPath path: String) -> Bool {
        asked.withLock { $0.append(path) }
        cost.withLock { $0 }?()
        return present.withLock { $0.contains(path) }
    }
}
