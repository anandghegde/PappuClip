import Darwin
import Foundation
import Synchronization

/// A process PappuClip starts on an action's behalf, and can stop (RUN-3d).
///
/// The Shortcut runner and the shell-script runner both use it, which is why it
/// knows nothing about either: an executable, its arguments, an environment, a working directory and
/// some bytes for standard input go in; the exit status and both outputs come out.
///
/// **Stopping.** `cancel` sends SIGTERM, gives the process `terminationGrace` to go, and then sends
/// SIGKILL, so it returns in bounded time whatever the process does — `CancellableWork` asks that of
/// every implementation. What the answer *means* depends on `ownership`: a process that did the work
/// itself was stopped; a process that only asked someone else to do it (`shortcuts` asking the
/// Shortcuts daemon) was stopped, and whether the work it asked for was is not something we can know,
/// which is RUN-3e's `askedToStop`.
///
/// Signals go to the process's group, so what it started stops with it.
///
/// **Output is read while the process runs**, rather than after it exits: a pipe holds 64 KB, and a
/// process that writes more than that into a pipe nobody is reading never exits.
///
/// **The exit is the end, give or take `outputDrain`.** A pipe reaches its end when the last process
/// holding it lets go, and that need not be the one we started: a script that backgrounds a daemon
/// hands the daemon its standard output. Waiting for the end of the pipe would wait for the daemon.
/// So once the process has exited, what arrives within `outputDrain` is kept and the pipes are then
/// closed on our side, whether or not anyone else still holds them.
public final class ChildProcess: CancellableWork, @unchecked Sendable {
    /// What to start.
    public struct Launch: Sendable, Equatable {
        public var executable: URL
        public var arguments: [String]
        /// Nil inherits ours.
        public var environment: [String: String]?
        public var workingDirectory: URL?
        public var standardInput: Data?

        public init(
            executable: URL,
            arguments: [String] = [],
            environment: [String: String]? = nil,
            workingDirectory: URL? = nil,
            standardInput: Data? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.standardInput = standardInput
        }
    }

    /// How it ended.
    public struct Result: Sendable, Equatable {
        /// The exit status, or the signal number when `signalled`.
        public var status: Int32
        public var signalled: Bool
        public var standardOutput: Data
        public var standardError: Data
        /// `cancel` was asked before it ended, so whatever it printed is not an answer.
        public var cancelled: Bool

        public var succeeded: Bool { !signalled && !cancelled && status == 0 }
    }

    public let ownership: WorkOwnership
    public let processID: pid_t
    private let process: Process
    private let completion: Task<Result, Never>
    private let cancelled = Locked(false)
    private let terminationGrace: Duration
    private let isGroupLeader: Bool

    /// Starts the process. Throws what `Process.run` throws: a missing executable, a permission.
    public init(
        _ launch: Launch,
        ownership: WorkOwnership = .owned,
        terminationGrace: Duration = .milliseconds(500),
        outputDrain: Duration = .milliseconds(250)
    ) throws {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        if let environment = launch.environment { process.environment = environment }
        if let directory = launch.workingDirectory { process.currentDirectoryURL = directory }
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let collector = Collector()
        process.terminationHandler = { _ in collector.exited(drain: outputDrain) }
        try process.run()

        for (pipe, isError) in [(output, false), (error, true)] {
            collector.read(pipe.fileHandleForReading, isError: isError)
        }
        // Written off this thread for the same reason the outputs are read off it: a process that
        // does not read its input until it has written its output would otherwise wait on us forever.
        let bytes = launch.standardInput
        DispatchQueue.global(qos: .userInitiated).async {
            if let bytes, !bytes.isEmpty { try? input.fileHandleForWriting.write(contentsOf: bytes) }
            try? input.fileHandleForWriting.close()
        }

        let cancelled = self.cancelled
        self.process = process
        self.processID = process.processIdentifier
        self.isGroupLeader = getpgid(process.processIdentifier) == process.processIdentifier
        self.ownership = ownership
        self.terminationGrace = terminationGrace
        self.completion = Task {
            let outputs = await collector.outputs()
            return Result(
                status: process.terminationStatus,
                signalled: process.terminationReason == .uncaughtSignal,
                standardOutput: outputs.output,
                standardError: outputs.error,
                cancelled: cancelled.withLock { $0 }
            )
        }
    }

    /// Waits for it to end, however it ends.
    public func result() async -> Result {
        await completion.value
    }

    public func cancel() async -> WorkCancellation {
        guard process.isRunning else { return .mayHaveCompleted }
        cancelled.withLock { $0 = true }
        signal(SIGTERM)

        let deadline = ContinuousClock.now + terminationGrace
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Unconditionally, once the grace is over: the process may have gone and left a child of its
        // own behind, still holding the output pipes open, and the result waits on those pipes.
        signal(SIGKILL)

        return switch ownership {
        case .owned: .stopped
        case .delegated: .askedToStop
        }
    }
}

extension ChildProcess {
    /// Signals the process and everything it started. `Process` makes each child the leader of a
    /// process group of its own, so the group is the process's ID negated; a shell script's
    /// `sleep` or `curl` is in it, and would otherwise outlive a cancelled script.
    private func signal(_ number: Int32) {
        if isGroupLeader { kill(-processID, number) } else { kill(processID, number) }
    }
}

/// Both outputs, and the rule for when they are complete: the process has exited, and either both
/// pipes have reached their end or the drain after the exit has run out.
private final class Collector: Sendable {
    private struct State {
        var output = Data()
        var error = Data()
        var openPipes = 2
        var exited = false
        var drained = false
        var finished = false
        var handles: [FileHandle] = []
        var waiter: CheckedContinuation<(output: Data, error: Data), Never>?
    }

    private let state = Mutex(State())

    func read(_ handle: FileHandle, isError: Bool) {
        state.withLock { $0.handles.append(handle) }
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            state.withLock { state in
                guard !state.finished else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.openPipes -= 1
                } else if isError {
                    state.error.append(data)
                } else {
                    state.output.append(data)
                }
            }
            settle()
        }
    }

    func exited(drain: Duration) {
        state.withLock { $0.exited = true }
        settle()
        DispatchQueue.global().asyncAfter(deadline: .now() + drain.timeInterval) { [self] in
            state.withLock { $0.drained = true }
            settle()
        }
    }

    func outputs() async -> (output: Data, error: Data) {
        await withCheckedContinuation { waiter in
            state.withLock { $0.waiter = waiter }
            settle()
        }
    }

    /// Hands the outputs over once they are complete, exactly once.
    private func settle() {
        let ready: (CheckedContinuation<(output: Data, error: Data), Never>, (output: Data, error: Data), [FileHandle])? =
            state.withLock { state in
                guard !state.finished, state.exited, state.openPipes == 0 || state.drained,
                      let waiter = state.waiter else { return nil }
                state.finished = true
                state.waiter = nil
                return (waiter, (state.output, state.error), state.handles)
            }
        guard let (waiter, outputs, handles) = ready else { return }
        for handle in handles {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        waiter.resume(returning: outputs)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A `Mutex` that closures can share: the mutex is not copyable, so it is held by reference.
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<T: Sendable>(_ body: (inout sending Value) throws -> sending T) rethrows -> T {
        try mutex.withLock(body)
    }
}
