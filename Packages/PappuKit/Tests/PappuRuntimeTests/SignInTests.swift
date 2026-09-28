import Foundation
import PappuCore
import PappuDiagnostics
import PappuExtensions
import PappuJSBridge
@testable import PappuRuntime
import Synchronization
import Testing

/// §8.10: the loopback listener the browser comes back to.
@Suite struct LoopbackCallbackListenerTests {
    static func get(_ url: URL) async -> Int? {
        let session = URLSession(configuration: .ephemeral)
        guard let (_, response) = try? await session.data(from: url) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    @Test func theCallbackIsHeardOnceOnTheLoopbackAddress() async throws {
        let listener = try LoopbackCallbackListener()
        #expect(listener.port != 0)
        #expect(listener.redirect.absoluteString == "http://127.0.0.1:\(listener.port)/callback")

        // Another path is not the callback: 404, and the listener waits on.
        #expect(await Self.get(URL(string: "http://127.0.0.1:\(listener.port)/favicon.ico")!) == 404)
        #expect(await Self.get(URL(string: listener.redirect.absoluteString + "?code=abc&state=s%20t")!) == 200)
        #expect(try await listener.callback(timeout: .seconds(5)) == ["code": "abc", "state": "s t"])

        // One-shot: the socket is closed, and the answer is not given twice.
        #expect(await Self.get(URL(string: listener.redirect.absoluteString + "?code=again")!) == nil)
        await #expect(throws: LoopbackCallbackListener.Failure.alreadyUsed) { try await listener.callback(timeout: .seconds(1)) }
    }

    @Test func noCallbackInTimeIsATimeoutAndTheSocketCloses() async throws {
        let listener = try LoopbackCallbackListener()
        let start = ContinuousClock.now
        await #expect(throws: LoopbackCallbackListener.Failure.timedOut) { try await listener.callback(timeout: .milliseconds(150)) }
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(await Self.get(listener.redirect) == nil)
    }

    @Test func aCancelEndsTheWait() async throws {
        let listener = try LoopbackCallbackListener()
        let waited = Task { try await listener.callback(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        await #expect(throws: LoopbackCallbackListener.Failure.cancelled) { try await waited.value }
    }

    @Test func eachListenerHasItsOwnPort() throws {
        let (a, b) = (try LoopbackCallbackListener(), try LoopbackCallbackListener())
        #expect(a.port != b.port)
    }
}

/// §8.10 end to end: the module's `auth` runs in the real helper, `flow` opens a page whose "browser"
/// comes back to the listener, and the secret lands in the Keychain under the extension's identity.
@Suite struct ExtensionSignInTests {
    /// A browser: it opens the page and, if told to, goes straight back to `redirect_uri` with `reply`.
    final class Browser: URLOpening {
        let opened = Mutex<[URL]>([])
        let reply: String?

        init(reply: String?) {
            self.reply = reply
        }

        func open(_ requests: [URLOpenRequest]) async -> Int {
            opened.withLock { $0 += requests.map(\.url) }
            guard let reply, let url = requests.first?.url,
                  let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
                  let back = URL(string: redirect + "?" + reply)
            else { return requests.count }
            Task { _ = await LoopbackCallbackListenerTests.get(back) }
            return requests.count
        }
    }

    static let module = """
    exports.actions = [{ title: 'Go', code: (input, options) => options.authsecret }];
    exports.auth = async (info, flow) => {
      const { code } = await flow('https://svc.example/authorize', { client_id: 'c', redirect_uri: info.redirect }, ['code']);
      return 'token-' + code + '-' + info.username + '-' + info.identifier;
    };
    """

    struct Setup {
        let secrets = InMemorySecretStore()
        let console = DebugConsole()
        let client: JSHostClient
        let package: URL

        init(module: String = ExtensionSignInTests.module) throws {
            client = JSHostClient(transport: InProcessJSHost(), console: console)
            package = FileManager.default.temporaryDirectory.appendingPathComponent("signin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data(module.utf8).write(to: package.appendingPathComponent("Config.js"))
        }

        func request(owner: LocalIdentity = LocalIdentity(), instance: InstanceID = InstanceID()) -> SignInRequest {
            SignInRequest(
                owner: owner,
                instance: instance,
                generation: "1",
                name: "Service",
                identifier: "com.example.service",
                directory: package,
                module: ModuleSource(source: .file("Config.js"), isTypeScript: false),
                username: "ann"
            )
        }

        func signIn(_ browser: Browser, timeout: Duration = .seconds(10)) -> ExtensionSignIn {
            ExtensionSignIn(javaScript: client, secrets: secrets, opener: browser, callbackTimeout: timeout)
        }
    }

    @Test func authCompletesAgainstALoopbackFlowAndTheSecretIsScopedToTheExtension() async throws {
        let setup = try Setup()
        let browser = Browser(reply: "code=xyz")
        let request = setup.request()
        #expect(await setup.signIn(browser).signIn(request) == .signedIn)
        #expect(setup.secrets.authSecret(of: request.instance, owner: request.owner) == "token-xyz-ann-com.example.service")

        let opened = try #require(browser.opened.withLock { $0.first })
        let query = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(opened.host() == "svc.example")
        #expect(query.contains(URLQueryItem(name: "client_id", value: "c")))
        #expect(query.first { $0.name == "redirect_uri" }?.value?.hasPrefix("http://127.0.0.1:") == true)

        // SEC-8a: another extension, or another install of the same identifier, or another instance, reads nothing.
        #expect(setup.secrets.authSecret(of: request.instance, owner: LocalIdentity()) == nil)
        #expect(setup.secrets.authSecret(of: InstanceID(), owner: request.owner) == nil)
        // An option of the same name is not the auth secret.
        #expect(setup.secrets.secret("authsecret", of: request.instance, owner: request.owner) == nil)
        // The secret never reaches the Debug Console.
        #expect(!setup.console.entries.contains { $0.text.contains("token-") })
    }

    @Test func aTimedOutFlowFailsCleanly() async throws {
        let setup = try Setup()
        let request = setup.request()
        try setup.secrets.setAuthSecret("earlier", of: request.instance, owner: request.owner)
        #expect(await setup.signIn(Browser(reply: nil), timeout: .milliseconds(200)).signIn(request) == .timedOut)
        #expect(setup.secrets.authSecret(of: request.instance, owner: request.owner) == "earlier")
    }

    @Test func aCancelledFlowFailsCleanly() async throws {
        let setup = try Setup()
        let request = setup.request()
        let signIn = setup.signIn(Browser(reply: nil))
        async let outcome = signIn.signIn(request)
        try await Task.sleep(for: .milliseconds(300))
        await signIn.cancelSignIn(for: request.owner)
        #expect(await outcome == .cancelled)
        #expect(setup.secrets.authSecret(of: request.instance, owner: request.owner) == nil)
    }

    @Test func aCallbackWithoutTheExpectedParameterFails() async throws {
        let setup = try Setup()
        let request = setup.request()
        #expect(await setup.signIn(Browser(reply: "error=access_denied")).signIn(request)
            == .failed("The sign-in did not finish. The Debug Console says why."))
        #expect(setup.secrets.authSecret(of: request.instance, owner: request.owner) == nil)
    }

    /// Nothing but `flow`, the secret and `httpRequest` is served while signing in.
    @Test func otherHostMethodsAreRefused() async throws {
        let setup = try Setup(module: "exports.auth = async () => { try { await popclip.copyText('x') } catch (e) { return 'refused: ' + e.message } }")
        let request = setup.request()
        #expect(await setup.signIn(Browser(reply: nil)).signIn(request) == .signedIn)
        #expect(setup.secrets.authSecret(of: request.instance, owner: request.owner) == "refused: copyText is not available while signing in.")
    }

    /// `httpRequest` from `auth` is checked as an action's is: no entitlement, no request.
    @Test func httpRequestFollowsTheExtensionsNetworkRules() async throws {
        let setup = try Setup()
        let host = SignInHost(
            request: setup.request(),
            listener: try LoopbackCallbackListener(),
            opener: Browser(reply: nil),
            network: NetworkHostCalls(),
            timeout: .seconds(1)
        )
        let call = JSHostCall(invocation: 1, extensionName: "x", method: "httpRequest", arguments: #"{"method":"GET","url":"https://svc.example/token"}"#)
        #expect(await host.perform(call) == .refused("httpRequest needs the network entitlement, which this extension does not have."))
    }
}
