import Foundation
import PappuRunnerBridge
@testable import PappuRunnerHost
import Testing

/// §8.4 AppleScript and Service, as the Runner executes them. In this process rather than over XPC:
/// the transport is `RunnerClient`'s, and what is tested here is what a request does. None of these
/// scripts talks to another app, so none needs Automation consent.
@MainActor
@Suite struct RunnerHostTests {
    @Test func aScriptReturnsText() {
        #expect(RunnerHost.handle(.appleScript(AppleScriptJob(source: .text(#"return "hello""#)))) == .returned("hello"))
    }

    @Test func aNumberComesBackAsText() {
        #expect(RunnerHost.handle(.appleScript(AppleScriptJob(source: .text("return 6 * 7")))) == .returned("42"))
    }

    @Test func aScriptThatReturnsNothingReturnsNil() {
        #expect(RunnerHost.handle(.appleScript(AppleScriptJob(source: .text("set x to 1\nset x to x")))) == .returned("1"))
        #expect(RunnerHost.handle(.appleScript(AppleScriptJob(source: .text("-- nothing")))) == .returned(nil))
    }

    /// §8.4: error 502 is the extension asking for its settings.
    @Test func error502IsKept() {
        let reply = RunnerHost.handle(.appleScript(AppleScriptJob(source: .text(#"error "No API key" number 502"#))))
        guard case .failed(let failure) = reply else {
            Issue.record("Expected a failure, got \(reply)")
            return
        }
        #expect(failure.number == RunnerFailure.needsSettings)
        #expect(failure.message == "No API key")
    }

    @Test func aScriptThatDoesNotCompileFails() {
        let reply = RunnerHost.handle(.appleScript(AppleScriptJob(source: .text("set to to to"))))
        guard case .failed(let failure) = reply else {
            Issue.record("Expected a failure, got \(reply)")
            return
        }
        #expect(failure.number != RunnerFailure.needsSettings)
    }

    /// `appleScriptCall`: the handler is called with its arguments in order, whatever case its name
    /// was written in.
    @Test func aHandlerIsCalledWithItsArguments() {
        let source = """
        on joinUp(firstPart, secondPart)
            return firstPart & "+" & secondPart
        end joinUp
        """
        let reply = RunnerHost.handle(.appleScript(AppleScriptJob(source: .text(source), handler: "joinUp", arguments: ["a", "b"])))
        #expect(reply == .returned("a+b"))
    }

    @Test func aScriptFileRuns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pappu-\(UUID().uuidString).applescript")
        try "on run\n    return \"from a file\"\nend run\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(RunnerHost.handle(.appleScript(AppleScriptJob(source: .file(file.path)))) == .returned("from a file"))
    }

    @Test func aMissingFileFails() {
        let reply = RunnerHost.handle(.appleScript(AppleScriptJob(source: .file("/nonexistent/script.scpt"))))
        guard case .failed = reply else {
            Issue.record("Expected a failure, got \(reply)")
            return
        }
    }

    @Test func aListReadsOnePerLine() {
        #expect(RunnerHost.handle(.appleScript(AppleScriptJob(source: .text(#"return {"a", "b"}"#)))) == .returned("a\nb"))
    }

    @Test func aServiceNobodyProvidesFails() {
        let reply = RunnerHost.handle(.service(ServiceJob(name: "PappuClip Test/No Such Service", text: "x")))
        #expect(reply == .failed(RunnerFailure(
            number: RunnerFailure.serviceNotPerformed,
            message: "No Service called PappuClip Test/No Such Service took the text."
        )))
    }

    @Test func identifyNamesThisProcess() {
        #expect(RunnerHost.handle(.identify) == .identity(processID: ProcessInfo.processInfo.processIdentifier))
    }

    /// What goes over the wire comes back as it went.
    @Test func messagesRoundTrip() throws {
        let requests: [RunnerRequest] = [
            .identify,
            .appleScript(AppleScriptJob(source: .file("/a.scpt"), handler: "h", arguments: ["x"])),
            .service(ServiceJob(name: "Make Sticky", text: "t")),
        ]
        for request in requests {
            #expect(try JSONDecoder().decode(RunnerRequest.self, from: JSONEncoder().encode(request)) == request)
        }
    }
}
