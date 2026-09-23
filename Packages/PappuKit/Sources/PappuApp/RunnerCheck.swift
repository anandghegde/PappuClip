import Foundation
import PappuRuntime

/// M2 week 4's "done when", against the real `PappuClipRunner.xpc`: a hung AppleScript is cancelled
/// promptly, and the next script runs in a fresh Runner. `PappuClip --check-runner` prints it and
/// quits. Only a built app can run it — an embedded XPC service answers no one but its app — so it
/// is here and not in a test.
public enum RunnerCheck {
    public struct Line: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func run(_ client: RunnerClient = RunnerClient()) async -> [Line] {
        let clock = ContinuousClock()
        var lines: [Line] = []

        var began = clock.now
        let first = await client.start(AppleScriptRunRequest(source: .text(#"return "ready""#)))
        let ready = await first?.result()
        lines.append(Line(name: "a script returns", passed: ready == .returned("ready"), detail: "\(String(describing: ready)) in \(clock.now - began)"))

        let hung = await client.start(AppleScriptRunRequest(source: .text("delay 30\nreturn \"too late\"")))
        try? await Task.sleep(for: .milliseconds(500))
        began = clock.now
        let cancellation = await hung?.cancel()
        let stopped = await hung?.result()
        let cancelTime = clock.now - began
        lines.append(Line(
            name: "a hung script cancels",
            passed: cancellation == .askedToStop && stopped == .stopped && cancelTime < .seconds(1),
            detail: "\(String(describing: cancellation)), \(String(describing: stopped)) in \(cancelTime)"
        ))

        began = clock.now
        let next = await client.start(AppleScriptRunRequest(source: .text(#"return "again""#)))
        let again = await next?.result()
        // Up to 10 s here: the Runner was killed within 10 s of its launch, and launchd does not start a
        // job again sooner than that after its last start. A Runner up for longer comes back at once.
        lines.append(Line(name: "the next script runs (launchd may hold it up to 10 s)", passed: again == .returned("again"), detail: "\(String(describing: again)) in \(clock.now - began)"))

        let settings = await client.start(AppleScriptRunRequest(source: .text(#"error "No key" number 502"#)))
        let asked = await settings?.result()
        lines.append(Line(name: "error 502 asks for settings", passed: asked == .needsSettings, detail: String(describing: asked)))
        return lines
    }
}
