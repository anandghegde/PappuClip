import Dispatch

/// The one isolation domain that makes Accessibility calls (architecture §14).
///
/// Every AX call blocks until the target app answers or the messaging timeout expires, and the app on
/// the other end may be wedged. Two rules follow, and this actor is both of them:
///
/// - **Serial.** One call at a time, so a slow app delays only the next AX call and nothing else.
/// - **Off the cooperative pool.** A blocked cooperative thread is one of a handful shared by the whole
///   program; blocking them is how a Swift concurrency program deadlocks. `AXSerialExecutor` runs the
///   actor's jobs on a dedicated `DispatchQueue` instead, where a thread that waits on another process
///   costs nothing but itself.
///
/// Types that hold AX state are annotated `@AXActor` and share this executor, so `AXFocusProbe` and the
/// strategies that follow it are one queue between them.
@globalActor
public actor AXActor {
    public static let shared = AXActor()

    private static let executor = AXSerialExecutor()

    public nonisolated var unownedExecutor: UnownedSerialExecutor { Self.executor.asUnownedSerialExecutor() }

    private init() {}
}

/// A serial executor over a `DispatchQueue`, so `AXActor`'s jobs never run on a cooperative thread.
///
/// `userInitiated` because an attempt has 70 ms for its read (PRD §11.1) and the queue's thread is
/// competing with whatever else the Mac is doing.
private final class AXSerialExecutor: SerialExecutor {
    private let queue = DispatchQueue(
        label: "app.pappuclip.accessibility",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
