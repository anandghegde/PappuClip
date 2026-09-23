import Foundation

/// The broker's clock, its waiting, and its way of walking away from a call that may never return.
///
/// It is one seam and not three because the race suite needs all three to move together: a test that
/// can advance the clock but not decide when a blocked read comes back can only script half a race.
/// `ScriptedPasteboard` in PappuTestSupport is the other implementation, and it is a virtual clock —
/// which is why the broker never reads `ContinuousClock.now` itself.
public protocol ClipboardScheduling: Sendable {
    var now: ContinuousClock.Instant { get }

    /// Waits. Zero or less returns at once, and no wait is ever cancelled into an error: a transaction
    /// that stopped waiting half way through would leave the pasteboard in whatever state it was in.
    func sleep(for duration: Duration) async

    /// Runs work that **may block for as long as another app likes**, somewhere the caller can leave it.
    ///
    /// M0 spike 6 watched `data(forType:)` sit on a hung lazy provider for twelve seconds with no way to
    /// cancel it, so this is the only shape that is honest: the work is put where abandoning it costs one
    /// thread and nothing else, and `false` means *it is still running*, not that it stopped.
    ///
    /// - Returns: False when `work` had not finished by `limit`.
    func run(within limit: Duration, _ work: @escaping @Sendable () -> Void) async -> Bool
}

/// The app's clock: `ContinuousClock`, `Task.sleep`, and one thread per blocking call.
///
/// A thread per call is not free — it is tens of microseconds — but it is charged only against the
/// clipboard fallback's 270 ms read stage, twice per transaction, and it is the only way to have a
/// deadline over a call that cannot be cancelled.
public struct SystemClipboardScheduling: ClipboardScheduling {
    public init() {}

    public var now: ContinuousClock.Instant { .now }

    public func sleep(for duration: Duration) async {
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }

    public func run(within limit: Duration, _ work: @escaping @Sendable () -> Void) async -> Bool {
        guard limit > .zero else { return false }
        // One slot, so the abandoned thread's `yield` has somewhere to go and does not block on exit.
        let (done, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        Thread.detachNewThread {
            work()
            continuation.yield(())
            continuation.finish()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in done { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
