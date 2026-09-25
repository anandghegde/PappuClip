import Foundation
import PappuJSBridge
import Synchronization
import XPC

/// The helper's entry point: accept the app's session and hand each request to `JSHost`.
///
/// **Replies are handed off, never made in line.** Spike 5 measured what answering in the session's
/// handler costs: every extension waits behind the slowest (549 ms of queueing behind one busy VM).
/// Each request is handed to a queue of its own and answered from wherever its world settles it —
/// possibly long after, for a script that awaits, or from a `drop`.
///
/// **Log lines and host calls go back on the session that loaded the extension.** A log line expects no
/// reply; a host call (`JSHostCall`) does, and its answer goes back to the world that asked. The app
/// opens one session for its actions; a second — `--check-js-host` asking who the helper is — loads
/// nothing and so hears nothing.
public enum JSHostListener {
    /// Never returns. `App/PappuClipJSHost/main.swift` calls it and nothing else.
    public static func run() -> Never {
        let owners = Mutex<[String: SessionRef]>([:])
        let host = JSHost(
            call: { call, answer in
                guard let session = owners.withLock({ $0[call.extensionName]?.session }) else {
                    return answer(.refused("PappuClip is not listening."))
                }
                do {
                    try session.send(call) { (result: Result<JSHostAnswer, any Error>) in
                        answer((try? result.get()) ?? .failed("PappuClip did not answer."))
                    }
                } catch {
                    answer(.failed("PappuClip could not be asked."))
                }
            },
            log: { name, line in
                let session = owners.withLock { $0[name]?.session }
                try? session?.send(JSHostEvent.log(extensionName: name, line: line))
            }
        )
        let replies = DispatchQueue(label: "app.pappuclip.jshost.replies", attributes: .concurrent)
        do {
            let listener = try XPCListener(service: JSHostService.name) { request in
                // The handler needs its own session, which `accept` returns only after taking it.
                let this = SessionRef()
                let (decision, session) = request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                    guard let request = try? message.decode(as: JSHostRequest.self) else {
                        return JSHostReply.badRequest("Undecodable request.")
                    }
                    if case .load(let load) = request {
                        owners.withLock { $0[load.extensionName] = this }
                    }
                    nonisolated(unsafe) let message = message
                    return message.handoffReply(to: replies) {
                        host.handle(request) { reply in message.reply(reply) }
                    }
                }
                this.set(session)
                return decision
            }
            withExtendedLifetime(listener) { dispatchMain() }
        } catch {
            fatalError("The JavaScript helper could not listen: \(error)")
        }
    }
}

private final class SessionRef: Sendable {
    private let held = Mutex<XPCSessionBox?>(nil)

    var session: XPCSession? { held.withLock { $0?.session } }

    func set(_ session: XPCSession) {
        held.withLock { $0 = XPCSessionBox(session: session) }
    }
}

private struct XPCSessionBox: @unchecked Sendable {
    let session: XPCSession
}
