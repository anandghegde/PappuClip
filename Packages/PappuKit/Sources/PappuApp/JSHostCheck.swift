import Darwin
import Foundation
import PappuCore
import PappuDiagnostics
import PappuJSBridge
import PappuRuntime

/// M3 week 1's "done when", against the real `PappuClipJSHost.xpc`: two extensions cannot see each
/// other's globals, and killing the helper mid-action fails that action and nothing else.
/// `PappuClip --check-js-host` prints it and quits. As with `RunnerCheck`, only a built app can reach
/// an embedded XPC service, so it is here and not in a test.
///
/// It also checks the two things about XPC the in-process tests cannot: that the helper's replies may
/// come after the message handler has returned (every JavaScript reply does), and that killing the
/// helper fails the requests still in flight.
public enum JSHostCheck {
    public typealias Line = RunnerCheck.Line

    public static func run() async -> [Line] {
        let clock = ContinuousClock()
        let console = DebugConsole()
        let client = JSHostClient(console: console)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("js-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try? Data("module.exports = (s) => s.toUpperCase()".utf8).write(to: package.appendingPathComponent("shout.js"))
        defer { try? FileManager.default.removeItem(at: package) }

        func job(_ script: String, owner: String = "check-a") -> JavaScriptRunRequest {
            JavaScriptRunRequest(
                owner: owner,
                generation: "1",
                extensionName: owner,
                directory: package,
                action: JavaScriptAction(source: .inline(script)),
                text: "hello",
                matchedText: "hello"
            )
        }
        func run(_ script: String, owner: String = "check-a") async -> ScriptResult? {
            await client.start(job(script, owner: owner))?.result()
        }

        var lines: [Line] = []
        var began = clock.now
        let first = await run("print('from the helper'); return require('./shout')(popclip.input.text)")
        let printed = console.entries.contains { $0.kind == .printed && $0.text == "from the helper" }
        lines.append(Line(
            name: "a script returns, and its print reaches the console",
            passed: first == .returned("HELLO") && printed,
            detail: "\(String(describing: first)), printed: \(printed), in \(clock.now - began)"
        ))

        _ = await run("globalThis.secret = 'a'; return 'set'")
        let seen = await run("return typeof secret", owner: "check-b")
        let own = await run("return secret")
        lines.append(Line(
            name: "one extension cannot see another's globals (SEC-1b)",
            passed: seen == .returned("undefined") && own == .returned("a"),
            detail: "b sees \(String(describing: seen)), a sees \(String(describing: own))"
        ))

        let reached = await run("""
            if (typeof fetch !== 'undefined' || typeof process !== 'undefined') return 'reached'
            try { require('fs'); return 'fs' } catch (e) { return 'none' }
            """)
        lines.append(Line(
            name: "no network, process or file system (JS-1)",
            passed: reached == .returned("none"),
            detail: String(describing: reached)
        ))

        let waiting = await client.start(job("await new Promise(() => {})"))
        began = clock.now
        let dropped = await waiting?.cancel()
        let hung = console.entries.contains { $0.kind == .hung }
        lines.append(Line(
            name: "a waiting script is dropped without a restart",
            passed: dropped == .stopped && !hung && client.isConnected,
            detail: "\(String(describing: dropped)) in \(clock.now - began), restarted: \(hung)"
        ))

        // The done-when: the helper is killed from outside while an action waits in it.
        let before = await helperProcessID()
        let doomed = await client.start(job("await new Promise(() => {})"))
        if let before { _ = Darwin.kill(before, SIGKILL) }
        began = clock.now
        let crashed = await doomed?.result()
        let charged = console.entries.contains { $0.kind == .crashed && $0.source == "check-a" }
        lines.append(Line(
            name: "killing the helper fails the action in it (SEC-1d)",
            passed: before != nil && crashed == .failed && charged,
            detail: "pid \(before.map(String.init) ?? "unknown"), \(String(describing: crashed)) in \(clock.now - began)"
        ))

        began = clock.now
        let again = await run("return 'again'", owner: "check-b")
        let after = await helperProcessID()
        // Up to 10 s: launchd does not start a job again sooner than that after its last start.
        lines.append(Line(
            name: "the next action runs in a new helper (launchd may hold it up to 10 s)",
            passed: again == .returned("again") && after != nil && after != before,
            detail: "\(String(describing: again)) in \(clock.now - began), pid \(after.map(String.init) ?? "unknown")"
        ))

        // A loop that never yields cannot be dropped; after the grace period the client kills it.
        let busy = await client.start(job("while (true) {}", owner: "check-b"))
        try? await Task.sleep(for: .milliseconds(200))
        began = clock.now
        let cancelled = await busy?.cancel()
        let ended = await busy?.result()
        let restarted = console.entries.contains { $0.kind == .hung && $0.source == "check-b" }
        let stopTime = clock.now - began
        lines.append(Line(
            name: "a script that will not yield is stopped by a restart",
            passed: cancelled == .stopped && ended == .stopped && restarted && stopTime < .seconds(1),
            detail: "\(String(describing: ended)) in \(stopTime), restarted: \(restarted)"
        ))
        return lines
    }

    /// Asks the helper who it is, over a session of the check's own: an XPC service has one process
    /// per app, so this is the one the client is talking to.
    private static func helperProcessID() async -> Int32? {
        guard let connection = await XPCJSHostTransport().connect(events: { _ in }) else { return nil }
        defer { connection.close() }
        let reply = await withCheckedContinuation { continuation in
            connection.send(.identify) { continuation.resume(returning: $0) }
        }
        guard case .success(.identity(let processID)) = reply else { return nil }
        return processID
    }
}
