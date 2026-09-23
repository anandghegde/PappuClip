import Foundation
import PappuCore
import Synchronization

/// Settings held in memory. A test can hand the same one to a second store to play a relaunch, and
/// can look at `keys` to check that resuming leaves nothing behind.
public final class FakeSettingsStorage: SettingsStorage {
    private let values = Mutex<[String: Data]>([:])

    public init(_ initial: [String: Data] = [:]) {
        values.withLock { $0 = initial }
    }

    public var keys: Set<String> { values.withLock { Set($0.keys) } }

    public func data(forKey key: String) -> Data? { values.withLock { $0[key] } }

    public func set(_ data: Data?, forKey key: String) {
        values.withLock { $0[key] = data }
    }
}

/// A wall clock a test moves by hand, for the absolute expiry of a timed pause (ACT-18).
public final class ManualDateSource: Sendable {
    private let date: Mutex<Date>

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        date = Mutex(start)
    }

    public var now: Date { date.withLock { $0 } }

    public func advance(by interval: TimeInterval) {
        date.withLock { $0 += interval }
    }

    public var reader: @Sendable () -> Date {
        { self.now }
    }
}
