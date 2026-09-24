import Darwin
import Foundation
import PappuDiagnostics
import PappuJSBridge
import Synchronization
import XPC

/// The app's side of `PappuClipJSHost.xpc` (architecture §10, SEC-1a, SEC-1b, SEC-1d).
///
/// **One connection, opened when first needed, and each extension loaded into it once.** An
/// extension is loaded the first time one of its actions runs on a connection, with the text of its
/// package's scripts, and again whenever its approved bytes change. A new connection — after a crash
/// or a kill — starts with nothing loaded, and loads again as it is used.
///
/// **A crash fails what was running and nothing else** (SEC-1d). Every request in flight on the
/// connection is answered with a failure the moment the helper goes, the connection is forgotten,
/// and the next action opens another; launchd starts a new helper for it. Each extension that had
/// code running is charged with the crash in the Debug Console, and one that crashes the helper
/// `suspensionThreshold` times inside `suspensionWindow` is not run again until the app restarts.
///
/// **Cancelling is a drop, then a kill.** The helper is asked to stop waiting for the invocation,
/// which it does at once unless the script is busy on its world's queue — a loop that never yields.
/// If the drop is not answered within `grace`, the helper is killed: that stops the loop, and
/// everything else in flight with it. The work is ours and it has stopped, so it is `owned` (RUN-3d).
public final class JSHostClient: JavaScriptRunning, Sendable {
    /// SEC-1d: this many crashes inside `suspensionWindow` suspends the extension.
    public static let suspensionThreshold = 3
    public static let suspensionWindow: Duration = .seconds(600)

    private struct State {
        var connection: (any JSHostConnection)?
        /// What is loaded on `connection`, by owner: the generation.
        var loaded: [String: String] = [:]
        /// The jobs in flight on `connection`.
        var running: [UInt64: Job] = [:]
        /// Set once the app killed the helper on purpose, so the jobs it takes down with it are not
        /// charged with a crash.
        var killed = false
        var nextInvocation: UInt64 = 0
        var crashes: [String: [ContinuousClock.Instant]] = [:]
        var suspended: Set<String> = []
    }

    private let transport: any JSHostTransport
    private let console: DebugConsole?
    private let grace: Duration
    private let sleeper: any InvocationSleeping
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())
    /// Extension names by owner, for the lines the helper sends with only an owner on them.
    private let names = Mutex<[String: String]>([:])

    public init(
        transport: any JSHostTransport = XPCJSHostTransport(),
        console: DebugConsole? = nil,
        grace: Duration = .milliseconds(500),
        sleeper: any InvocationSleeping = SystemInvocationSleep(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.transport = transport
        self.console = console
        self.grace = grace
        self.sleeper = sleeper
        self.now = now
    }

    deinit {
        state.withLock { $0.connection }?.close()
    }

    public func start(_ job: JavaScriptRunRequest) async -> (any ScriptRun)? {
        names.withLock { $0[job.owner] = job.extensionName }
        guard !isSuspended(job.owner) else {
            console?.add(.suspended, from: job.extensionName)
            return nil
        }
        guard let connection = await connect(), await load(job, on: connection) else { return nil }

        let entry: JSInvoke.Entry = switch job.action.source {
        case .inline(let text): .inline(text)
        case .file(let path): .file(path)
        }
        let started = state.withLock { state -> Job? in
            guard state.connection === connection else { return nil }
            state.nextInvocation += 1
            let run = Job(id: state.nextInvocation, request: job, connection: connection, client: self)
            state.running[run.id] = run
            return run
        }
        guard let started else { return nil }
        connection.send(.invoke(JSInvoke(
            invocation: started.id,
            extensionName: job.owner,
            generation: job.generation,
            entry: entry,
            input: JSInput(text: job.text, matchedText: job.matchedText),
            options: job.options,
            typeScript: job.action.isTypeScript
        ))) { reply in started.settle(reply) }
        return started
    }

    /// Whether the helper is running, for the checks.
    public var isConnected: Bool {
        state.withLock { $0.connection != nil }
    }

    public func isSuspended(_ owner: String) -> Bool {
        state.withLock { $0.suspended.contains(owner) }
    }

    // MARK: Connecting and loading

    private func connect() async -> (any JSHostConnection)? {
        if let open = state.withLock({ $0.connection }) { return open }
        let opened = await transport.connect { [weak self] event in self?.heard(event) }
        guard let opened else { return nil }
        return state.withLock { state in
            // Two actions that both found no connection: the first one's is kept.
            if let current = state.connection {
                opened.close()
                return current
            }
            state.connection = opened
            state.loaded = [:]
            state.killed = false
            return opened
        }
    }

    private func load(_ job: JavaScriptRunRequest, on connection: any JSHostConnection) async -> Bool {
        let current = state.withLock { $0.connection === connection ? $0.loaded[job.owner] : nil }
        if current == job.generation { return true }
        let files: [String: String]
        switch PackageSources.read(job.directory) {
        case .success(let read): files = read
        case .failure:
            // No text: the window says the package could not be read, in its own words.
            console?.add(.loadFailed, from: job.extensionName)
            return false
        }
        let reply = await withCheckedContinuation { continuation in
            connection.send(.load(JSLoad(extensionName: job.owner, generation: job.generation, files: files))) {
                continuation.resume(returning: $0)
            }
        }
        switch reply {
        case .success(.loaded):
            state.withLock { if $0.connection === connection { $0.loaded[job.owner] = job.generation } }
            return true
        case .success(.loadFailed(let message)):
            console?.add(.loadFailed, from: job.extensionName, message)
            return false
        case .success:
            return false
        case .failure:
            lost(connection)
            return false
        }
    }

    private func heard(_ event: JSHostEvent) {
        switch event {
        case .log(let owner, let line):
            console?.add(.printed, from: names.withLock { $0[owner] } ?? owner, line)
        }
    }

    // MARK: Losing the helper

    /// Forgets a connection that has gone, and charges the extensions that were running in it.
    fileprivate func lost(_ connection: any JSHostConnection) {
        let (charged, killed) = state.withLock { state -> ([Job], Bool) in
            guard state.connection === connection else { return ([], true) }
            state.connection = nil
            state.loaded = [:]
            let running = Array(state.running.values)
            state.running = [:]
            return (running, state.killed)
        }
        connection.close()
        guard !killed else { return }
        let owners = Set(charged.filter { !$0.wasCancelled }.map(\.request.owner))
        for owner in owners.sorted() {
            charge(owner, name: charged.first { $0.request.owner == owner }?.request.extensionName ?? owner)
        }
    }

    private func charge(_ owner: String, name: String) {
        console?.add(.crashed, from: name)
        let at = now()
        let suspended = state.withLock { state -> Bool in
            var recent = (state.crashes[owner] ?? []).filter { $0.duration(to: at) < Self.suspensionWindow }
            recent.append(at)
            state.crashes[owner] = recent
            guard recent.count >= Self.suspensionThreshold, !state.suspended.contains(owner) else { return false }
            state.suspended.insert(owner)
            return true
        }
        if suspended { console?.add(.suspended, from: name) }
    }

    fileprivate func kill(_ connection: any JSHostConnection, for job: Job) {
        let current = state.withLock { state -> Bool in
            guard state.connection === connection else { return false }
            state.killed = true
            return true
        }
        guard current else { return }
        console?.add(.hung, from: job.request.extensionName)
        connection.kill()
        lost(connection)
    }

    fileprivate func finished(_ job: Job) {
        state.withLock { _ = $0.running.removeValue(forKey: job.id) }
    }

    fileprivate func report(_ result: ScriptResult, message: String?, for job: Job) {
        let name = job.request.extensionName
        switch result {
        case .returned(let text): console?.add(.returned, from: name, text ?? "")
        case .stopped: console?.add(.stopped, from: name)
        case .needsSettings, .failed, .automationDenied:
            if let message { console?.add(.threw, from: name, message) }
        }
    }

    // MARK: One invocation

    fileprivate final class Job: ScriptRun, Sendable {
        private struct State {
            var ended: ScriptResult?
            var cancelled = false
            var waiters: [CheckedContinuation<ScriptResult, Never>] = []
        }

        let ownership = WorkOwnership.owned
        let id: UInt64
        let request: JavaScriptRunRequest
        private let connection: any JSHostConnection
        private let client: JSHostClient
        private let state = Mutex(State())

        init(id: UInt64, request: JavaScriptRunRequest, connection: any JSHostConnection, client: JSHostClient) {
            self.id = id
            self.request = request
            self.connection = connection
            self.client = client
        }

        var wasCancelled: Bool { state.withLock { $0.cancelled } }

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
            connection.send(.drop(invocation: id)) { _ in }
            let sleeper = client.sleeper, grace = client.grace
            Task { [weak self] in
                await sleeper.sleep(for: grace)
                guard let self, self.state.withLock({ $0.ended == nil }) else { return }
                self.client.kill(self.connection, for: self)
                self.end(.stopped, message: nil)
            }
            _ = await result()
            return .stopped
        }

        func settle(_ reply: Result<JSHostReply, JSHostGone>) {
            switch reply {
            case .success(.returned(let text)): end(.returned(text), message: nil)
            case .success(.threw(let message)): end(JavaScriptFailure.result(forThrown: message), message: message)
            case .success(.dropped): end(.stopped, message: nil)
            case .success: end(.failed, message: nil)
            case .failure:
                // The helper went away: a crash, or a kill for a script that would not stop. The
                // client decides which, and whom to charge, before this job says how it ended.
                client.lost(connection)
                end(wasCancelled ? .stopped : .failed, message: nil)
            }
        }

        private func end(_ result: ScriptResult, message: String?) {
            let waiters = state.withLock { state -> [CheckedContinuation<ScriptResult, Never>]? in
                guard state.ended == nil else { return nil }
                state.ended = result
                defer { state.waiters = [] }
                return state.waiters
            }
            guard let waiters else { return }
            client.finished(self)
            client.report(result, message: message, for: self)
            for waiter in waiters { waiter.resume(returning: result) }
        }
    }
}

// MARK: - Transport

/// The helper went away before it answered.
public struct JSHostGone: Error, Equatable {
    public init() {}
}

/// How the client reaches a helper. The app's is XPC; the tests' runs `JSHost` in this process and
/// can be made to crash.
public protocol JSHostTransport: Sendable {
    /// Opens a connection to a helper, starting one if need be.
    /// - Parameter events: What the helper says unasked. Called on any queue.
    func connect(events: @escaping @Sendable (JSHostEvent) -> Void) async -> (any JSHostConnection)?
}

public protocol JSHostConnection: AnyObject, Sendable {
    /// `reply` is called exactly once: with the helper's answer, or with `JSHostGone` the moment the
    /// helper goes away — killed, crashed, or this connection closed.
    func send(_ request: JSHostRequest, reply: @escaping @Sendable (Result<JSHostReply, JSHostGone>) -> Void)
    /// Stops the helper now, whatever it is doing.
    func kill()
    /// Lets go of the helper. Anything in flight fails.
    func close()
}

/// `PappuClipJSHost.xpc`, over `XPCSession`.
public struct XPCJSHostTransport: JSHostTransport {
    private let serviceName: String

    public init(serviceName: String = JSHostService.name) {
        self.serviceName = serviceName
    }

    public func connect(events: @escaping @Sendable (JSHostEvent) -> Void) async -> (any JSHostConnection)? {
        let session: XPCSession
        do {
            session = try XPCSession(
                xpcService: serviceName,
                incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                    if let event = try? message.decode(as: JSHostEvent.self) { events(event) }
                    return nil
                },
                cancellationHandler: nil
            )
        } catch {
            return nil
        }
        let connection = XPCJSHostConnection(session: session)
        let identity = await withCheckedContinuation { continuation in
            connection.send(.identify) { continuation.resume(returning: $0) }
        }
        guard case .success(.identity(let processID)) = identity else {
            connection.close()
            return nil
        }
        connection.processID.withLock { $0 = processID }
        return connection
    }
}

final class XPCJSHostConnection: JSHostConnection, @unchecked Sendable {
    private let session: XPCSession
    let processID = Mutex<pid_t>(0)

    init(session: XPCSession) {
        self.session = session
    }

    /// An `XPCSession` released while it is still open is API misuse, and libxpc stops the process for
    /// it.
    deinit {
        session.cancel(reason: "The connection went away.")
    }

    func send(_ request: JSHostRequest, reply: @escaping @Sendable (Result<JSHostReply, JSHostGone>) -> Void) {
        do {
            try session.send(request) { (result: Result<JSHostReply, any Error>) in
                reply(result.mapError { _ in JSHostGone() })
            }
        } catch {
            reply(.failure(JSHostGone()))
        }
    }

    func kill() {
        let processID = processID.withLock { $0 }
        if processID > 0 { _ = Darwin.kill(processID, SIGKILL) }
        close()
    }

    func close() {
        session.cancel(reason: "Closed.")
    }
}
