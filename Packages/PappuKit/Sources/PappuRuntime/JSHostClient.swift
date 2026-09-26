import Darwin
import Foundation
import PappuCore
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
///
/// **Describing a module (JS-12)** loads the extension as an action would and asks what its module
/// exported. A module that is still loading after `describeLimit` — one in a loop — is stopped the way
/// a script that will not yield is, by killing the helper.
///
/// **Host calls** (architecture §10.4) come from the helper on the same connection, each naming the
/// invocation it was made for. The client finds the run and hands the call to its `HostAPIDispatcher`,
/// which decides; a call for a run that has ended, or from an extension that is not the run's, is
/// refused here. Every refusal is written to the Debug Console by method and reason (SEC-7b).
///
/// **A cancelled run's world is not used again.** Its script may still be running in the helper — only
/// its answer was dropped — and it could reach the next invocation's `popclip`. So a cancel forgets that
/// the extension is loaded, and its next run loads a fresh world, which the old code cannot reach
/// (JS-15).
public final class JSHostClient: JavaScriptRunning, ModuleDescribing, CodeScanning, Sendable {
    /// SEC-1d: this many crashes inside `suspensionWindow` suspends the extension.
    public static let suspensionThreshold = 3
    public static let suspensionWindow: Duration = .seconds(600)
    /// JS-12: the longest a module may take to load and describe.
    public static let describeLimit: Duration = .seconds(5)

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
    private let moduleLimit: Duration
    private let sleeper: any InvocationSleeping
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())
    /// Extension names by owner, for the lines the helper sends with only an owner on them.
    private let names = Mutex<[String: String]>([:])

    public init(
        transport: any JSHostTransport = XPCJSHostTransport(),
        console: DebugConsole? = nil,
        grace: Duration = .milliseconds(500),
        describeLimit: Duration = JSHostClient.describeLimit,
        sleeper: any InvocationSleeping = SystemInvocationSleep(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.transport = transport
        self.console = console
        self.grace = grace
        moduleLimit = describeLimit
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
        guard let connection = await connect(),
              await load(owner: job.owner, generation: job.generation, extensionName: job.extensionName, directory: job.directory, on: connection)
        else { return nil }

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
            input: job.input,
            context: job.context,
            modifiers: job.modifiers,
            options: job.options,
            booleanOptions: job.booleanOptions,
            typeScript: job.action.isTypeScript,
            export: job.action.export
        ))) { reply in started.settle(reply) }
        return started
    }

    // MARK: Host calls (architecture §10.4)

    /// A host call from the helper: to the dispatcher of the run it names, or refused.
    private func served(_ call: JSHostCall, answer: @escaping @Sendable (JSHostAnswer) -> Void) {
        let job = state.withLock { $0.running[call.invocation] }
        guard let job, job.request.owner == call.extensionName else {
            refused(call, "The action is no longer running.", name: names.withLock { $0[call.extensionName] } ?? call.extensionName)
            return answer(.refused("The action is no longer running."))
        }
        guard let host = job.request.host else {
            refused(call, "Nothing here answers host calls.", name: job.request.extensionName)
            return answer(.refused("Nothing here answers host calls."))
        }
        Task {
            let reply = await host.perform(call)
            if case .refused(let why) = reply { self.refused(call, why, name: job.request.extensionName) }
            answer(reply)
        }
    }

    /// SEC-7b: the method and why, never what it was called with.
    private func refused(_ call: JSHostCall, _ why: String, name: String) {
        console?.add(.refused, from: name, "\(call.method): \(why)")
    }

    public func describe(_ module: ModuleDescribeRequest) async -> Result<ModuleExports, ModuleDescribeFailure> {
        names.withLock { $0[module.owner] = module.extensionName }
        guard !isSuspended(module.owner) else {
            return .failure(ModuleDescribeFailure("The extension is suspended until the app restarts."))
        }
        guard let connection = await connect() else {
            return .failure(ModuleDescribeFailure("The JavaScript helper did not start."))
        }
        guard await load(
            owner: module.owner,
            generation: module.generation,
            extensionName: module.extensionName,
            directory: module.directory,
            on: connection
        ) else {
            return .failure(ModuleDescribeFailure("The extension's code did not load."))
        }
        let entry: JSInvoke.Entry = switch module.module.source {
        case .inline(let text): .inline(text)
        case .file(let path): .file(path)
        }
        let request = JSHostRequest.describe(JSDescribe(
            extensionName: module.owner,
            generation: module.generation,
            entry: entry,
            typeScript: module.module.isTypeScript
        ))
        switch await ask(connection, request, within: moduleLimit) {
        case .answered(.success(.described(let description))):
            do {
                return .success(try ModuleExports(json: description.exports, functions: description.functions))
            } catch {
                return failed("What the module exported could not be read: \(error)", module)
            }
        case .answered(.success(.threw(let message))):
            return failed(message, module)
        case .answered(.success):
            return failed("The helper did not describe the module.", module)
        case .answered(.failure):
            lost(connection)
            return failed("The JavaScript helper stopped while it was loading the module.", module)
        case .timedOut:
            kill(connection, name: module.extensionName)
            return failed("The module was still loading after \(moduleLimit), and was stopped.", module)
        }
    }

    /// EXM-5f: the longest a scan may take before its code is taken to be unbounded.
    public static let scanLimit: Duration = .seconds(10)

    /// EXM-5f: every script in the package, and the manifest's own inline scripts, read by the helper for
    /// the host methods they reach. Nothing is run, so it needs no approval and loads no world. Nil when
    /// the package cannot be read, the helper does not start, or it does not answer in `scanLimit`: the
    /// analysis then treats the code as unbounded, which discloses more rather than less.
    public func scan(_ manifest: ExtensionManifest, in directory: URL) async -> CodeScan? {
        var sources: [JSScan.Source] = []
        switch await PackageSources.reading(directory) {
        case .success(let files):
            for (path, text) in files.sorted(by: { $0.key < $1.key }) where !path.lowercased().hasSuffix(".json") {
                sources.append(JSScan.Source(name: path, text: text, typeScript: path.lowercased().hasSuffix(".ts")))
            }
        case .failure:
            return nil
        }
        var inline: [(ScriptSource, Bool)] = manifest.actions.compactMap {
            if case .javaScript(let script) = $0.executor { (script.source, script.isTypeScript) } else { nil }
        }
        if let module = manifest.moduleSource { inline.append((module.source, module.isTypeScript)) }
        for (index, (source, typeScript)) in inline.enumerated() {
            if case .inline(let text) = source {
                sources.append(JSScan.Source(name: "inline \(index)", text: text, typeScript: typeScript))
            }
        }
        guard let connection = await connect() else { return nil }
        switch await ask(connection, .scan(JSScan(sources: sources)), within: Self.scanLimit) {
        case .answered(.success(.scanned(let report))):
            return CodeScan(
                methods: report.methods,
                // A reason this build does not know is still a reason.
                unbounded: report.unbounded.map { CodeScan.Unbounded(rawValue: $0) ?? .unreadable }
            )
        case .answered(.failure):
            lost(connection)
            return nil
        case .answered(.success), .timedOut:
            return nil
        }
    }

    private func failed(_ message: String, _ module: ModuleDescribeRequest) -> Result<ModuleExports, ModuleDescribeFailure> {
        console?.add(.loadFailed, from: module.extensionName, message)
        return .failure(ModuleDescribeFailure(message))
    }

    private enum Answer: Sendable {
        case answered(Result<JSHostReply, JSHostGone>)
        case timedOut
    }

    /// One request, and its reply or the end of `limit`, whichever comes first.
    private func ask(_ connection: any JSHostConnection, _ request: JSHostRequest, within limit: Duration) async -> Answer {
        let once = Once()
        let sleeper = self.sleeper
        return await withCheckedContinuation { continuation in
            connection.send(request) { reply in
                if once.claim() { continuation.resume(returning: .answered(reply)) }
            }
            Task {
                await sleeper.sleep(for: limit)
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    private final class Once: Sendable {
        private let claimed = Mutex(false)

        /// True the first time only.
        func claim() -> Bool {
            claimed.withLock { claimed in
                defer { claimed = true }
                return !claimed
            }
        }
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
        let opened = await transport.connect(
            events: { [weak self] event in self?.heard(event) },
            calls: { [weak self] call, answer in
                guard let self else { return answer(.refused("PappuClip is not listening.")) }
                self.served(call, answer: answer)
            }
        )
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

    private func load(
        owner: String,
        generation: String,
        extensionName: String,
        directory: URL,
        on connection: any JSHostConnection
    ) async -> Bool {
        let current = state.withLock { $0.connection === connection ? $0.loaded[owner] : nil }
        if current == generation { return true }
        let files: [String: String]
        switch await PackageSources.reading(directory) {
        case .success(let read): files = read
        case .failure:
            // No text: the window says the package could not be read, in its own words.
            console?.add(.loadFailed, from: extensionName)
            return false
        }
        let reply = await withCheckedContinuation { continuation in
            connection.send(.load(JSLoad(extensionName: owner, generation: generation, files: files))) {
                continuation.resume(returning: $0)
            }
        }
        switch reply {
        case .success(.loaded):
            state.withLock { if $0.connection === connection { $0.loaded[owner] = generation } }
            return true
        case .success(.loadFailed(let message)):
            console?.add(.loadFailed, from: extensionName, message)
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

    fileprivate func kill(_ connection: any JSHostConnection, name: String) {
        let current = state.withLock { state -> Bool in
            guard state.connection === connection else { return false }
            state.killed = true
            return true
        }
        guard current else { return }
        console?.add(.hung, from: name)
        connection.kill()
        lost(connection)
    }

    /// JS-15: the next run of `owner` on `connection` loads a fresh world, out of reach of whatever the
    /// cancelled one left running.
    fileprivate func forgetWorld(of owner: String, on connection: any JSHostConnection) {
        state.withLock { state in
            if state.connection === connection { state.loaded[owner] = nil }
        }
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
            client.forgetWorld(of: request.owner, on: connection)
            connection.send(.drop(invocation: id)) { _ in }
            let sleeper = client.sleeper, grace = client.grace
            Task { [weak self] in
                await sleeper.sleep(for: grace)
                guard let self, self.state.withLock({ $0.ended == nil }) else { return }
                self.client.kill(self.connection, name: self.request.extensionName)
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
    /// The same, and where the helper's host calls go (architecture §10.4). `calls` is given each call
    /// and something to answer it with, exactly once, on any queue.
    func connect(
        events: @escaping @Sendable (JSHostEvent) -> Void,
        calls: @escaping @Sendable (JSHostCall, @escaping @Sendable (JSHostAnswer) -> Void) -> Void
    ) async -> (any JSHostConnection)?
}

extension JSHostTransport {
    /// A transport that carries no host calls: the helper's every call is refused where it was made.
    public func connect(
        events: @escaping @Sendable (JSHostEvent) -> Void,
        calls: @escaping @Sendable (JSHostCall, @escaping @Sendable (JSHostAnswer) -> Void) -> Void
    ) async -> (any JSHostConnection)? {
        await connect(events: events)
    }
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
        await connect(events: events) { _, answer in answer(.refused("PappuClip is not listening.")) }
    }

    /// A host call is answered with `handoffReply`, from wherever its dispatcher finishes, so a call
    /// that waits on the user — a paste's verification, a Service — holds up nothing else.
    public func connect(
        events: @escaping @Sendable (JSHostEvent) -> Void,
        calls: @escaping @Sendable (JSHostCall, @escaping @Sendable (JSHostAnswer) -> Void) -> Void
    ) async -> (any JSHostConnection)? {
        let session: XPCSession
        let replies = DispatchQueue(label: "app.pappuclip.jshost.calls", attributes: .concurrent)
        do {
            session = try XPCSession(
                xpcService: serviceName,
                incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                    if let call = try? message.decode(as: JSHostCall.self) {
                        nonisolated(unsafe) let message = message
                        return message.handoffReply(to: replies) {
                            calls(call) { answer in message.reply(answer) }
                        }
                    }
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
