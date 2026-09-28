import Darwin
import Foundation
import PappuCore
import PappuExtensions
import PappuJSBridge
import Synchronization

/// Where the helper's host calls go: a run's `HostAPIDispatcher`, or a sign-in's `SignInHost`.
public protocol HostCallServing: Sendable {
    func perform(_ call: JSHostCall) async -> JSHostAnswer
}

extension HostAPIDispatcher: HostCallServing {}

// MARK: - The callback listener

/// §8.10: where the browser comes back to after a sign-in. One request, on the loopback address, within a
/// time limit.
///
/// It listens on 127.0.0.1 alone, on a port the system picks, so nothing off the machine can reach it and
/// no port is reserved. The first `GET /callback` it receives is the answer: its query parameters are
/// kept, the browser is told it can close the tab, and the socket is closed, so nothing arrives after it.
/// Any other path is answered 404 and the listener waits on. It ends — with `timedOut` or `cancelled` —
/// if no callback came, and either way the socket is closed then too.
public final class LoopbackCallbackListener: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case couldNotListen
        case timedOut
        case cancelled
        /// `callback` was asked for a second time: the listener answers one flow.
        case alreadyUsed
    }

    public static let path = "/callback"
    /// The most of a request that is read; a callback's request line is far shorter.
    static let requestLimit = 16 << 10

    public let port: UInt16
    /// `info.redirect`.
    public var redirect: URL { URL(string: "http://127.0.0.1:\(port)\(Self.path)")! }

    private let socket: Int32
    private let queue = DispatchQueue(label: "app.pappuclip.signin.listener")
    private let lock = NSLock()
    private var source: (any DispatchSourceRead)?
    private var outcome: Result<[String: String], Failure>?
    private var waiter: CheckedContinuation<[String: String], any Error>?
    private var waited = false

    public init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.couldNotListen }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        var named = sockaddr_in()
        var namedLength = length
        let got = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &namedLength) }
        }
        guard bound == 0, listen(fd, 8) == 0, got == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            close(fd)
            throw Failure.couldNotListen
        }
        socket = fd
        port = UInt16(bigEndian: named.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    /// The callback's query parameters, once it comes. Throws `timedOut` after `timeout`, `cancelled` if
    /// `cancel` came first, and `alreadyUsed` when asked again.
    public func callback(timeout: Duration) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(.timedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if waited {
                lock.unlock()
                return continuation.resume(throwing: Failure.alreadyUsed)
            }
            waited = true
            if let outcome {
                lock.unlock()
                return continuation.resume(with: outcome.mapError { $0 as any Error })
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// Stops listening. A wait in progress ends with `cancelled`.
    public func cancel() {
        finish(.failure(.cancelled))
    }

    /// The first outcome is the one; the socket closes with it.
    private func finish(_ result: Result<[String: String], Failure>) {
        lock.lock()
        guard outcome == nil else { return lock.unlock() }
        outcome = result
        let waiter = self.waiter
        self.waiter = nil
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.cancel()
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    private func acceptAll() {
        while true {
            lock.lock()
            let done = outcome != nil
            lock.unlock()
            if done { return }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < Self.requestLimit, received.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        let line = String(decoding: received, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == Self.path
        else {
            respond(client, status: "404 Not Found", body: "Not found.")
            return
        }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        respond(client, status: "200 OK", body: "Signed in. You can close this tab and go back to PappuClip.")
        finish(.success(parameters))
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let page = "<!doctype html><meta charset=\"utf-8\"><title>PappuClip</title><p>\(body)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + page
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            sent += count
        }
    }
}

// MARK: - What a sign-in's JavaScript may call

/// The host calls `auth` makes (§8.10): `flow` as `authFlow`, the secret it resolves with as
/// `authSecret`, and `httpRequest` under the same rules as an action's. Nothing else: there is no
/// selection to act on and no bar to show, so every other method is refused.
final class SignInHost: HostCallServing {
    static let flow = "authFlow"
    static let secret = "authSecret"

    private let request: SignInRequest
    private let listener: LoopbackCallbackListener
    private let opener: any URLOpening
    private let network: NetworkHostCalls
    private let timeout: Duration

    private struct State {
        var flowed = false
        var secret: String?
        var ended: SignInOutcome?
    }
    private let state = Mutex(State())

    init(request: SignInRequest, listener: LoopbackCallbackListener, opener: any URLOpening, network: NetworkHostCalls, timeout: Duration) {
        self.request = request
        self.listener = listener
        self.opener = opener
        self.network = network
        self.timeout = timeout
    }

    /// The secret `auth` resolved with, once it has.
    var secret: String? { state.withLock { $0.secret } }
    /// How the flow ended, when the callback never came.
    var ended: SignInOutcome? { state.withLock { $0.ended } }

    struct Flow: Decodable {
        var url: String
        var params: [String: String]
        var expect: [String]
    }

    func perform(_ call: JSHostCall) async -> JSHostAnswer {
        let arguments = Data(call.arguments.utf8)
        switch call.method {
        case Self.flow:
            guard let given = try? JSONDecoder().decode(Flow.self, from: arguments) else {
                return .refused("flow was not given what it takes.")
            }
            return await flow(given)
        case Self.secret:
            struct Secret: Decodable { var secret: String }
            guard let given = try? JSONDecoder().decode(Secret.self, from: arguments), !given.secret.isEmpty else {
                return .refused("The auth function returned no secret.")
            }
            state.withLock { $0.secret = given.secret }
            return .done
        case NetworkHostCalls.method:
            if request.network?.hosts == nil, request.network != nil, !request.gates.contains(.network) {
                return .refused("httpRequest needs the network permission, which this extension does not have.")
            }
            do {
                return try await network.request(arguments, policy: request.network, invocation: nil)
            } catch is DecodingError {
                return .refused("httpRequest was not given what it takes.")
            } catch let refusal as HostCallRefusal {
                return .refused(refusal.message)
            } catch {
                return .failed("httpRequest did not work.")
            }
        default:
            return .refused("\(call.method) is not available while signing in.")
        }
    }

    /// Opens the service's page with `params` added, and waits for the browser to come back.
    private func flow(_ given: Flow) async -> JSHostAnswer {
        guard state.withLock({ state -> Bool in
            defer { state.flowed = true }
            return !state.flowed
        }) else { return .refused("flow may be called once in a sign-in.") }
        guard var components = URLComponents(string: given.url),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return .refused("flow was not given an address it may open.") }
        if !given.params.isEmpty {
            components.queryItems = (components.queryItems ?? []) + given.params.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        guard let url = components.url else { return .refused("flow was not given an address it may open.") }
        guard await opener.open([URLOpenRequest(url: url)]) == 1 else {
            listener.cancel()
            return .failed("The sign-in page could not be opened.")
        }
        let received: [String: String]
        do {
            received = try await listener.callback(timeout: timeout)
        } catch LoopbackCallbackListener.Failure.timedOut {
            state.withLock { $0.ended = .timedOut }
            return .refused("The sign-in timed out.")
        } catch {
            state.withLock { $0.ended = .cancelled }
            return .refused("The sign-in was cancelled.")
        }
        let wanted = given.expect.isEmpty ? received : received.filter { given.expect.contains($0.key) }
        if let missing = given.expect.first(where: { received[$0] == nil }) {
            return .refused("The sign-in did not send back \(missing).")
        }
        return .value(String(decoding: (try? JSONEncoder().encode(wanted)) ?? Data("{}".utf8), as: UTF8.self))
    }
}

// MARK: - Signing in

/// Runs a module extension's `auth` in the JavaScript helper and keeps the secret it gives (§8.10).
///
/// **Steps.** A loopback listener is opened and its address is `info.redirect`; the module's `auth` runs
/// in the extension's own world, approved bytes only, with `SignInHost` answering its calls; `flow`
/// opens the service's page in the browser and waits for the callback; the secret the function resolves
/// with is handed over as a host call — never as the run's result, which the Debug Console shows — and
/// is written to the Keychain under the extension's identity and instance (SEC-8a).
///
/// **Ending.** The callback wait has `callbackTimeout`, and the whole run `limit`. `cancelSignIn` closes
/// the listener and stops the run. Each ends as `timedOut` or `cancelled`, with nothing stored and any
/// earlier secret left as it was.
public final class ExtensionSignIn: SigningIn {
    private let javaScript: any JavaScriptRunning
    private let secrets: any SecretStore
    private let opener: any URLOpening
    private let network: NetworkHostCalls
    private let callbackTimeout: Duration
    private let limit: Duration

    private final class Attempt: @unchecked Sendable {
        let listener: LoopbackCallbackListener
        private let lock = NSLock()
        private var run: (any ScriptRun)?
        private var cancelled = false

        init(listener: LoopbackCallbackListener) {
            self.listener = listener
        }

        var wasCancelled: Bool { lock.withLock { cancelled } }

        /// False when a cancel came first; the run is then stopped here.
        func started(_ run: any ScriptRun) -> Bool {
            lock.withLock {
                self.run = run
                return !cancelled
            }
        }

        func cancel() async {
            let run = lock.withLock { () -> (any ScriptRun)? in
                cancelled = true
                return self.run
            }
            listener.cancel()
            _ = await run?.cancel()
        }
    }
    private let attempts = Mutex<[LocalIdentity: Attempt]>([:])

    public init(
        javaScript: any JavaScriptRunning,
        secrets: any SecretStore,
        opener: any URLOpening = SystemURLOpener(),
        fetcher: any HTTPFetching = URLSessionHTTPFetcher(),
        callbackTimeout: Duration = .seconds(300),
        limit: Duration = .seconds(360)
    ) {
        self.javaScript = javaScript
        self.secrets = secrets
        self.opener = opener
        network = NetworkHostCalls(fetcher: fetcher)
        self.callbackTimeout = callbackTimeout
        self.limit = limit
    }

    public func signIn(_ request: SignInRequest) async -> SignInOutcome {
        guard let listener = try? LoopbackCallbackListener() else {
            return .failed("PappuClip could not listen for the sign-in to finish.")
        }
        let attempt = Attempt(listener: listener)
        let fresh = attempts.withLock { attempts -> Bool in
            guard attempts[request.owner] == nil else { return false }
            attempts[request.owner] = attempt
            return true
        }
        guard fresh else {
            listener.cancel()
            return .failed("A sign-in is already in progress.")
        }
        defer {
            listener.cancel()
            attempts.withLock { attempts in
                if attempts[request.owner] === attempt { attempts[request.owner] = nil }
            }
        }

        let host = SignInHost(request: request, listener: listener, opener: opener, network: network, timeout: callbackTimeout)
        let job = JavaScriptRunRequest(
            owner: request.owner.description,
            generation: request.generation,
            extensionName: request.name,
            directory: request.directory,
            action: JavaScriptAction(source: request.module.source, isTypeScript: request.module.isTypeScript),
            input: JSInput(text: "", matchedText: ""),
            host: host,
            auth: JSAuthInfo(
                username: request.username,
                password: request.password,
                redirect: listener.redirect.absoluteString,
                name: request.name,
                identifier: request.identifier
            )
        )
        guard let run = await javaScript.start(job) else {
            return .failed("The extension's JavaScript could not be started.")
        }
        guard attempt.started(run) else {
            _ = await run.cancel()
            return .cancelled
        }
        let limit = self.limit
        let watch = Task {
            try await Task.sleep(for: limit)
            listener.cancel()
            _ = await run.cancel()
        }
        let result = await run.result()
        watch.cancel()

        if attempt.wasCancelled { return .cancelled }
        if let ended = host.ended { return ended }
        switch result {
        case .returned:
            guard let secret = host.secret else { return .failed("The auth function returned no secret.") }
            do {
                try secrets.setAuthSecret(secret, of: request.instance, owner: request.owner)
                return .signedIn
            } catch {
                return .failed("The Keychain did not keep the sign-in.")
            }
        case .stopped:
            return .timedOut
        default:
            return .failed("The sign-in did not finish. The Debug Console says why.")
        }
    }

    public func cancelSignIn(for owner: LocalIdentity) async {
        let attempt = attempts.withLock { $0[owner] }
        await attempt?.cancel()
    }
}
