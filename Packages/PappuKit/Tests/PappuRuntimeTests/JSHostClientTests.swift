import Foundation
import PappuCore
import PappuDiagnostics
import PappuJSBridge
import PappuJSHost
@testable import PappuRuntime
import Synchronization
import Testing

/// A helper in this process: the real `JSHost` behind a connection that can be made to crash. What
/// the XPC transport adds — a process to kill and launchd to restart it — is `--check-js-host`'s.
final class InProcessJSHost: JSHostTransport {
    let connections = Mutex<[Connection]>([])

    var current: Connection? { connections.withLock { $0.last } }
    var opened: Int { connections.withLock { $0.count } }

    func connect(events: @escaping @Sendable (JSHostEvent) -> Void) async -> (any JSHostConnection)? {
        let connection = Connection(events: events)
        connections.withLock { $0.append(connection) }
        return connection
    }

    final class Connection: JSHostConnection {
        typealias Reply = @Sendable (Result<JSHostReply, JSHostGone>) -> Void

        private struct State {
            var gone = false
            var killed = false
            var outstanding: [UInt64: Reply] = [:]
            var next: UInt64 = 0
            var requests: [JSHostRequest] = []
        }

        private let host: JSHost
        private let state = Mutex(State())

        init(events: @escaping @Sendable (JSHostEvent) -> Void) {
            host = JSHost { name, line in events(.log(extensionName: name, line: line)) }
        }

        var wasKilled: Bool { state.withLock { $0.killed } }
        var loads: Int {
            state.withLock { $0.requests.filter { if case .load = $0 { true } else { false } }.count }
        }

        func send(_ request: JSHostRequest, reply: @escaping Reply) {
            let id = state.withLock { state -> UInt64? in
                guard !state.gone else { return nil }
                state.next += 1
                state.outstanding[state.next] = reply
                state.requests.append(request)
                return state.next
            }
            guard let id else { return reply(.failure(JSHostGone())) }
            host.handle(request) { answer in
                self.state.withLock { $0.outstanding.removeValue(forKey: id) }?(.success(answer))
            }
        }

        /// What the app sees when the helper dies: every request in flight fails at once.
        func crash() {
            let owed = state.withLock { state -> [Reply] in
                state.gone = true
                defer { state.outstanding = [:] }
                return Array(state.outstanding.values)
            }
            for reply in owed { reply(.failure(JSHostGone())) }
        }

        func kill() {
            state.withLock { $0.killed = true }
            crash()
        }

        func close() { crash() }
    }
}

@Suite struct JSHostClientTests {
    struct Setup {
        let transport = InProcessJSHost()
        let console = DebugConsole()
        let client: JSHostClient
        let package: URL

        init(files: [String: String] = [:], grace: Duration = .milliseconds(100)) throws {
            client = JSHostClient(transport: transport, console: console, grace: grace)
            package = FileManager.default.temporaryDirectory.appendingPathComponent("js-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            for (path, text) in files {
                let url = package.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
        }

        func job(
            _ script: String,
            owner: String = "ext-a",
            name: String = "Extension A",
            generation: String = "1",
            text: String = "hello"
        ) -> JavaScriptRunRequest {
            JavaScriptRunRequest(
                owner: owner,
                generation: generation,
                extensionName: name,
                directory: package,
                action: JavaScriptAction(source: .inline(script)),
                text: text,
                matchedText: text
            )
        }

        func run(_ job: JavaScriptRunRequest) async -> ScriptResult? {
            await client.start(job)?.result()
        }

        func kinds(_ source: String? = nil) -> [ConsoleEntry.Kind] {
            console.entries.filter { source == nil || $0.source == source }.map(\.kind)
        }
    }

    // MARK: Running

    @Test func runsAScriptAndReturnsItsString() async throws {
        let setup = try Setup(files: ["lib/shout.js": "module.exports = (s) => s.toUpperCase() + '!'"])
        #expect(await setup.run(setup.job("return require('./lib/shout')(popclip.input.text)")) == .returned("HELLO!"))
        #expect(setup.kinds() == [.returned])
        #expect(setup.console.entries.first?.text == "HELLO!")
    }

    @Test func aScriptFileRunsFromThePackage() async throws {
        let setup = try Setup(files: ["main.js": "return popclip.input.matchedText.length.toString()"])
        var job = setup.job("")
        job.action = JavaScriptAction(source: .file("main.js"))
        #expect(await setup.run(job) == .returned("5"))
    }

    /// JS-11: "settings error" and "not signed in" open the extension's settings.
    @Test func aSettingsErrorAsksForSettings() async throws {
        let setup = try Setup()
        #expect(await setup.run(setup.job("throw new Error('Settings error: no API key')")) == .needsSettings)
        #expect(await setup.run(setup.job("throw new Error('Not signed in')")) == .needsSettings)
        #expect(await setup.run(setup.job("throw new Error('Something else')")) == .failed)
        #expect(setup.console.entries.map(\.text) == ["Settings error: no API key", "Not signed in", "Something else"])
    }

    @Test func printReachesTheDebugConsoleUnderTheExtensionsName() async throws {
        let setup = try Setup()
        _ = await setup.run(setup.job("print('hi from a')"))
        let printed = setup.console.entries.filter { $0.kind == .printed }
        #expect(printed.map(\.source) == ["Extension A"])
        #expect(printed.map(\.text) == ["hi from a"])
    }

    @Test func anExtensionIsLoadedOncePerGeneration() async throws {
        let setup = try Setup()
        _ = await setup.run(setup.job("globalThis.n = (globalThis.n || 0) + 1"))
        #expect(await setup.run(setup.job("return String(n)")) == .returned("1"))
        #expect(setup.transport.current?.loads == 1)
        #expect(await setup.run(setup.job("return typeof n", generation: "2")) == .returned("undefined"))
        #expect(setup.transport.current?.loads == 2)
    }

    // MARK: SEC-1d

    /// The done-when of M3 week 1: killing the helper mid-action fails that action and nothing else.
    @Test func aCrashFailsTheRunningActionAndTheNextOneRuns() async throws {
        let setup = try Setup()
        let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        setup.transport.current?.crash()
        #expect(await hanging.result() == .failed)
        #expect(setup.kinds("Extension A") == [.crashed])

        // A new helper, the extension loaded into it again, and another extension unaffected.
        #expect(await setup.run(setup.job("return 'again'")) == .returned("again"))
        #expect(await setup.run(setup.job("return 'b'", owner: "ext-b", name: "Extension B")) == .returned("b"))
        #expect(setup.transport.opened == 2)
        #expect(setup.kinds("Extension B") == [.returned])
    }

    @Test func aCrashIsChargedOnlyToWhatWasRunning() async throws {
        let setup = try Setup()
        _ = await setup.run(setup.job("return 'b'", owner: "ext-b", name: "Extension B"))
        let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        setup.transport.current?.crash()
        _ = await hanging.result()
        #expect(setup.kinds("Extension A") == [.crashed])
        #expect(setup.kinds("Extension B") == [.returned])
    }

    @Test func anExtensionThatKeepsCrashingIsSuspended() async throws {
        let setup = try Setup()
        for _ in 0..<JSHostClient.suspensionThreshold {
            let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
            setup.transport.current?.crash()
            _ = await hanging.result()
        }
        #expect(setup.client.isSuspended("ext-a"))
        #expect(await setup.client.start(setup.job("return 'x'")) == nil)
        #expect(setup.kinds("Extension A").filter { $0 == .suspended }.count == 2)
        // Another extension is not.
        #expect(await setup.run(setup.job("return 'b'", owner: "ext-b", name: "Extension B")) == .returned("b"))
    }

    // MARK: Cancelling

    @Test func cancelDropsAScriptThatIsWaiting() async throws {
        let setup = try Setup()
        let hanging = try #require(await setup.client.start(setup.job("await new Promise(() => {})")))
        #expect(await hanging.cancel() == .stopped)
        #expect(await hanging.result() == .stopped)
        #expect(setup.transport.current?.wasKilled == false)
        #expect(setup.kinds() == [.stopped])
    }

    @Test func cancelKillsTheHelperForAScriptThatWillNotYield() async throws {
        let setup = try Setup(grace: .milliseconds(50))
        let busy = try #require(await setup.client.start(setup.job(
            "const end = Date.now() + 1500; while (Date.now() < end) {}; return 'finished'"
        )))
        let first = try #require(setup.transport.current)
        #expect(await busy.cancel() == .stopped)
        #expect(await busy.result() == .stopped)
        #expect(first.wasKilled)
        #expect(setup.kinds() == [.hung, .stopped])
        #expect(!setup.client.isSuspended("ext-a"))
    }

    @Test func cancellingAFinishedRunSaysSo() async throws {
        let setup = try Setup()
        let run = try #require(await setup.client.start(setup.job("return 'x'")))
        _ = await run.result()
        #expect(await run.cancel() == .mayHaveCompleted)
    }

    // MARK: The package

    @Test func onlyScriptsInsideThePackageAreSent() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).js")
        try Data("secret".utf8).write(to: outside)
        let setup = try Setup(files: ["a.js": "1", "data.json": "{}", "notes.txt": "no", ".hidden.js": "no"])
        try FileManager.default.createSymbolicLink(at: setup.package.appendingPathComponent("link.js"), withDestinationURL: outside)
        let files = try PackageSources.read(setup.package).get()
        #expect(Set(files.keys) == ["a.js", "data.json"])
    }

    @Test func settingsPrefixesAreCaseInsensitive() {
        #expect(JavaScriptFailure.result(forThrown: "SETTINGS ERROR: key") == .needsSettings)
        #expect(JavaScriptFailure.result(forThrown: "not signed in to the service") == .needsSettings)
        #expect(JavaScriptFailure.result(forThrown: "Error: settings error") == .failed)
    }
}
