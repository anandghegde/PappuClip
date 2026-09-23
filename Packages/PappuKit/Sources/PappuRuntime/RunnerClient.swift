import Darwin
import Foundation
import PappuRunnerBridge
import Synchronization
import XPC

/// The app's side of `PappuClipRunner.xpc`: AppleScripts and Services (§8.4, architecture §9.5).
///
/// **One session, opened when first needed.** Its first message asks the Runner for its process
/// identifier, because cancelling means killing that process: a script waiting on an app that will
/// never answer cannot be interrupted any other way (RUN-3d). The next job opens a new session, and
/// launchd starts a new Runner for it.
///
/// **Killing the Runner stops every job in it.** Only one runs at a time in practice — the Runner
/// runs them on its main thread, and the bar runs one action at a time — so the job that is killed
/// is the job that was cancelled.
///
/// **Both kinds of job are `delegated`.** The script and the Service are stopped, but what they
/// asked another app to do may already be done, so a cancel says `askedToStop` and never `stopped`
/// (RUN-3e).
public final class RunnerClient: AppleScriptRunning, ServiceRunning, Sendable {
    fileprivate struct Connection: @unchecked Sendable {
        let session: XPCSession
        let processID: pid_t
    }

    private let serviceName: String
    private let connection = Mutex<Connection?>(nil)

    public init(serviceName: String = RunnerService.name) {
        self.serviceName = serviceName
    }

    /// An `XPCSession` released while it is still open is API misuse, and libxpc stops the process
    /// for it. The app's client lives as long as the app; a shorter-lived one closes its session here.
    deinit {
        connection.withLock { $0 }?.session.cancel(reason: "The client went away.")
    }

    public func start(_ job: AppleScriptRunRequest) async -> (any ScriptRun)? {
        let source: AppleScriptJob.Source = switch job.source {
        case .text(let text): .text(text)
        case .file(let url): .file(url.path)
        }
        return await start(.appleScript(AppleScriptJob(source: source, handler: job.handler, arguments: job.arguments)))
    }

    public func start(service name: String, text: String) async -> (any ScriptRun)? {
        await start(.service(ServiceJob(name: name, text: text)))
    }

    private func start(_ request: RunnerRequest) async -> (any ScriptRun)? {
        guard let connection = await connect() else { return nil }
        let job = Job(connection: connection, client: self)
        do {
            try connection.session.send(request) { (result: Result<RunnerReply, any Error>) in
                job.settle(result)
            }
        } catch {
            drop(connection)
            return nil
        }
        return job
    }

    /// The open session, or a new one with the Runner's process identifier learned.
    private func connect() async -> Connection? {
        if let open = connection.withLock({ $0 }) { return open }
        guard let session = try? XPCSession(xpcService: serviceName) else { return nil }
        let identity: RunnerReply? = await withCheckedContinuation { continuation in
            do {
                try session.send(RunnerRequest.identify) { (result: Result<RunnerReply, any Error>) in
                    continuation.resume(returning: try? result.get())
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard case .identity(let processID) = identity else {
            session.cancel(reason: "The Runner did not say who it is.")
            return nil
        }
        let opened = Connection(session: session, processID: processID)
        return connection.withLock { current in
            // Two jobs that both found no session: the first one's is kept.
            if let current {
                session.cancel(reason: "Another session was opened first.")
                return current
            }
            current = opened
            return opened
        }
    }

    /// Forgets a session that has been killed or has failed, so the next job opens another.
    fileprivate func drop(_ dropped: Connection) {
        connection.withLock { current in
            if current?.processID == dropped.processID { current = nil }
        }
        dropped.session.cancel(reason: "Dropped.")
    }

    fileprivate func kill(_ connection: Connection) {
        _ = Darwin.kill(connection.processID, SIGKILL)
        drop(connection)
    }

    /// One request in flight.
    private final class Job: ScriptRun, Sendable {
        private struct State {
            var ended: ScriptResult?
            var cancelled = false
            var waiters: [CheckedContinuation<ScriptResult, Never>] = []
        }

        let ownership = WorkOwnership.delegated
        private let connection: Connection
        private let client: RunnerClient
        private let state = Mutex(State())

        init(connection: Connection, client: RunnerClient) {
            self.connection = connection
            self.client = client
        }

        func result() async -> ScriptResult {
            await withCheckedContinuation { waiter in
                let ended = state.withLock { state -> ScriptResult? in
                    if state.ended == nil { state.waiters.append(waiter) }
                    return state.ended
                }
                if let ended { waiter.resume(returning: ended) }
            }
        }

        func cancel() async -> WorkCancellation {
            let running = state.withLock { state -> Bool in
                guard state.ended == nil else { return false }
                state.cancelled = true
                return true
            }
            guard running else { return .mayHaveCompleted }
            client.kill(connection)
            end(.stopped)
            return .askedToStop
        }

        func settle(_ reply: Result<RunnerReply, any Error>) {
            switch reply {
            case .success(.returned(let text)): end(.returned(text))
            case .success(.failed(let failure)): end(Self.result(for: failure))
            case .success(.identity): end(.failed)
            case .failure:
                // The Runner went away: killed by a cancel, or crashed. Either way this session is done.
                client.drop(connection)
                end(state.withLock { $0.cancelled } ? .stopped : .failed)
            }
        }

        static func result(for failure: RunnerFailure) -> ScriptResult {
            switch failure.number {
            case RunnerFailure.needsSettings: .needsSettings
            case RunnerFailure.automationDenied: .automationDenied
            default: .failed
            }
        }

        private func end(_ result: ScriptResult) {
            let waiters = state.withLock { state -> [CheckedContinuation<ScriptResult, Never>] in
                guard state.ended == nil else { return [] }
                state.ended = result
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: result) }
        }
    }
}
