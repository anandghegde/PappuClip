import AppKit
import Foundation
import PappuRunnerBridge
import XPC

/// The Runner's entry point: accept the app's sessions and answer each request on the main thread.
public enum RunnerListener {
    /// Never returns. `App/PappuClipRunner/main.swift` calls it and nothing else.
    public static func run() -> Never {
        // Services are an AppKit feature and want an application object, though never a window.
        MainActor.assumeIsolated { _ = NSApplication.shared }
        do {
            let listener = try XPCListener(service: RunnerService.name) { request in
                request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                    guard let request = try? message.decode(as: RunnerRequest.self) else {
                        return RunnerReply.failed(RunnerFailure(number: RunnerFailure.badRequest, message: "Undecodable request."))
                    }
                    if request == .identify { return RunnerReply.identity(processID: ProcessInfo.processInfo.processIdentifier) }
                    // Handed to the main queue and answered from there, so that the next request —
                    // an `identify` from a new session, say — is not stuck behind a script that hangs.
                    nonisolated(unsafe) let message = message
                    return message.handoffReply(to: .main) {
                        message.reply(MainActor.assumeIsolated { RunnerHost.handle(request) })
                    }
                }
            }
            withExtendedLifetime(listener) { RunLoop.main.run() }
        } catch {
            fatalError("The Runner could not listen: \(error)")
        }
        exit(0)
    }
}
