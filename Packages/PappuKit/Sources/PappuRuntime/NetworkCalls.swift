import Foundation
import PappuCore
import PappuJSBridge
import Synchronization

/// `httpRequest`: the only network a script has (JS-8, SEC-1c, SEC-6, architecture §10.5).
///
/// The helper is sandboxed without the network, so a script's `XMLHttpRequest` — and axios, and
/// anything else built on it — is a host call, and the app makes the request. Everything that decides
/// whether it may is here, in `perform`, after the dispatcher has checked the run and the grant:
///
/// - The extension must have the `network` entitlement. With `networkHosts` nothing more is needed;
///   without them, the `network` grant is, which `gate(for:in:)` tells the dispatcher.
/// - The address must pass `NetworkPolicy`: one of the declared hosts, and https unless it is local.
///   A redirect is asked the same question before it is followed, and one that fails ends the request.
///
/// Refusals name the rule and never the address, since the address may carry the selected text.
///
/// **What the request carries.** Only what the script set. The session is ephemeral, with no cookie
/// store, no credential store and no cache, so a script sees no one else's cookies and leaves none; a
/// `Cookie` or `Host` header it sets is dropped, as a browser drops it.
public struct NetworkHostCalls: HostCallHandling {
    public static let method = "httpRequest"
    /// The most a response body may be: it crosses to the helper as base64 in one message.
    public static let bodyLimit = 16 << 20
    /// A request's longest wait, which is also the wait when the script sets none.
    public static let timeoutLimit: Duration = .seconds(120)

    private let fetcher: any HTTPFetching
    private let manager: InvocationManager?

    /// - Parameter manager: Where a request in flight is attached to its invocation, so that cancelling
    ///   the invocation cancels the request (RUN-3d). Nil in tests that do not cancel.
    public init(fetcher: any HTTPFetching = URLSessionHTTPFetcher(), manager: InvocationManager? = nil) {
        self.fetcher = fetcher
        self.manager = manager
    }

    public var methods: Set<String> { [Self.method] }

    public func gate(for method: String, in run: HostAPIDispatcher.Run) -> GatedCapability? {
        // No entitlement at all is `perform`'s refusal, which says so, rather than a grant nobody offered.
        guard let policy = run.action?.network else { return nil }
        return policy.hosts == nil ? .network : nil
    }

    struct Request: Decodable {
        var method: String
        var url: String
        var headers: [[String]] = []
        /// Base64, or nil for no body.
        var body: String?
        /// Milliseconds; zero or missing for the longest wait.
        var timeout: Double?

        enum CodingKeys: String, CodingKey { case method, url, headers, body, timeout }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            url = try container.decode(String.self, forKey: .url)
            headers = try container.decodeIfPresent([[String]].self, forKey: .headers) ?? []
            body = try container.decodeIfPresent(String.self, forKey: .body)
            timeout = try container.decodeIfPresent(Double.self, forKey: .timeout)
        }
    }

    /// What `XMLHttpRequest` settles to.
    struct Response: Encodable {
        var status: Int
        var statusText: String
        var headers: [String: String]
        var url: String
        var body: String
    }

    /// Headers a script may not set, as a browser's `XMLHttpRequest` may not: they are the transport's,
    /// or they would carry what the ephemeral session is there to keep out.
    static let forbiddenHeaders: Set<String> = [
        "accept-charset", "accept-encoding", "connection", "content-length", "cookie", "cookie2", "date",
        "expect", "host", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade", "via",
    ]

    public func perform(_ method: String, arguments: Data, for run: HostAPIDispatcher.Run) async throws -> JSHostAnswer {
        let given = try JSONDecoder().decode(Request.self, from: arguments)
        guard let policy = run.action?.network else {
            throw HostCallRefusal("httpRequest needs the network entitlement, which this extension does not have.")
        }
        guard let url = URL(string: given.url) else {
            throw HostCallRefusal("httpRequest was not given an address it may request.")
        }
        if let why = policy.refusal(for: url) { throw HostCallRefusal(why) }
        let verb = given.method.uppercased()
        guard !verb.isEmpty, verb.allSatisfy({ $0.isASCII && $0.isLetter }), !["CONNECT", "TRACE", "TRACK"].contains(verb) else {
            throw HostCallRefusal("httpRequest was not given a method it makes.")
        }
        var body: Data?
        if let encoded = given.body {
            guard let data = Data(base64Encoded: encoded) else { throw HostCallRefusal("httpRequest was not given what it takes.") }
            body = data
        }
        let headers = given.headers.compactMap { pair -> (String, String)? in
            guard pair.count == 2, !Self.forbiddenHeaders.contains(pair[0].lowercased()),
                  !pair[0].lowercased().hasPrefix("proxy-"), !pair[0].lowercased().hasPrefix("sec-")
            else { return nil }
            return (pair[0], pair[1])
        }
        let limit = Double(Self.timeoutLimit.components.seconds)
        let seconds = given.timeout.map { $0 > 0 ? min($0 / 1000, limit) : limit } ?? limit
        let fetch = HTTPFetch(url: url, method: verb, headers: headers, body: body, timeout: seconds)

        let task = Task { try await fetcher.fetch(fetch, policy: policy) }
        if let manager, await !manager.attach(FetchWork(task: task), to: run.invocation) {
            task.cancel()
            throw HostCallRefusal("The action is no longer running.")
        }
        let fetched: HTTPFetched
        do {
            fetched = try await task.value
        } catch HTTPFetchFailure.timedOut {
            return .value(#"{"timedOut":true}"#)
        } catch HTTPFetchFailure.redirectRefused {
            throw HostCallRefusal("httpRequest was redirected to an address the extension may not reach.")
        } catch HTTPFetchFailure.tooLarge {
            return .failed("httpRequest's response was larger than PappuClip passes to a script.")
        } catch HTTPFetchFailure.cancelled {
            throw HostCallRefusal("The action is no longer running.")
        } catch {
            return .failed("httpRequest could not reach the server.")
        }
        let response = Response(
            status: fetched.status,
            statusText: HTTPURLResponse.localizedString(forStatusCode: fetched.status),
            headers: fetched.headers,
            url: fetched.url.absoluteString,
            body: fetched.body.base64EncodedString()
        )
        return .value(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
    }

    /// A request in flight, as the invocation sees it: ours, and stopped by cancelling it.
    private struct FetchWork: CancellableWork {
        let task: Task<HTTPFetched, any Error>
        var ownership: WorkOwnership { .owned }

        func cancel() async -> WorkCancellation {
            task.cancel()
            return .stopped
        }
    }
}

/// One request, already checked against the policy.
public struct HTTPFetch: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [Header]
    public var body: Data?
    /// Seconds.
    public var timeout: Double

    public struct Header: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public init(url: URL, method: String, headers: [(String, String)] = [], body: Data? = nil, timeout: Double = 60) {
        self.url = url
        self.method = method
        self.headers = headers.map { Header(name: $0.0, value: $0.1) }
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPFetched: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    /// Where the response came from, after any redirects.
    public var url: URL
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], url: URL, body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.url = url
        self.body = body
    }
}

public enum HTTPFetchFailure: Error, Sendable, Equatable {
    case timedOut
    /// A redirect to an address the policy refuses. It was not followed.
    case redirectRefused
    case tooLarge
    case cancelled
    case unreachable
}

/// Makes a request `NetworkHostCalls` has allowed. A seam so that no test reaches the network, and so
/// that a test can see a refused request never got this far.
public protocol HTTPFetching: Sendable {
    /// `policy` is asked again for every redirect before it is followed.
    func fetch(_ request: HTTPFetch, policy: NetworkPolicy) async throws -> HTTPFetched
}

/// The app's: an ephemeral `URLSession` with nothing kept between requests.
public final class URLSessionHTTPFetcher: HTTPFetching {
    private let session: URLSession

    /// - Parameter protocolClasses: For tests, `URLProtocol`s that answer in place of the network.
    public init(protocolClasses: [AnyClass] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func fetch(_ request: HTTPFetch, policy: NetworkPolicy) async throws -> HTTPFetched {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        urlRequest.httpBody = request.body
        let redirects = RedirectCheck(policy: policy)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: redirects)
        } catch let error as URLError {
            if redirects.refused { throw HTTPFetchFailure.redirectRefused }
            switch error.code {
            case .timedOut: throw HTTPFetchFailure.timedOut
            case .cancelled: throw HTTPFetchFailure.cancelled
            default: throw HTTPFetchFailure.unreachable
            }
        } catch is CancellationError {
            throw HTTPFetchFailure.cancelled
        }
        if redirects.refused { throw HTTPFetchFailure.redirectRefused }
        guard let http = response as? HTTPURLResponse else { throw HTTPFetchFailure.unreachable }
        guard data.count <= NetworkHostCalls.bodyLimit else { throw HTTPFetchFailure.tooLarge }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return HTTPFetched(status: http.statusCode, headers: headers, url: http.url ?? request.url, body: data)
    }
}

/// Asks the policy about every redirect before it is followed, and ends the request at one it refuses.
final class RedirectCheck: NSObject, URLSessionTaskDelegate, Sendable {
    let policy: NetworkPolicy
    private let refusedState = Mutex(false)

    init(policy: NetworkPolicy) {
        self.policy = policy
    }

    var refused: Bool { refusedState.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, policy.refusal(for: url) == nil else {
            refusedState.withLock { $0 = true }
            task.cancel()
            return nil
        }
        return request
    }
}
