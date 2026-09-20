import Foundation
import JavaScriptCore
import XPC

// The JavaScript helper of spike 5: JavaScriptCore in a sandboxed XPC service with no JIT entitlement,
// one virtual machine per extension (architecture §10.1), spoken to over `XPCSession` with `Codable`
// messages (§10.2). Throwaway; what is kept is what it measured.

enum HelperClock {
    static let start = ContinuousClock.now
}

func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
}

/// What JavaScript threw, as text.
struct ScriptFailure: Error {
    let message: String
}

/// One extension's JavaScript world. Nothing is shared with another (SEC-1b): its own virtual machine,
/// so its own heap and garbage collector, and its own queue, because a `JSVirtualMachine` runs one thread at a time.
final class ExtensionVM: @unchecked Sendable {
    let queue: DispatchQueue
    private let context: JSContext
    private var exception: String?

    init(id: String, hostCall: @escaping @Sendable (String, String) -> String) {
        queue = DispatchQueue(label: "vm.\(id)", qos: .userInteractive)
        context = JSContext(virtualMachine: JSVirtualMachine())
        context.name = id
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }

        // The blocking form of a host call: this VM's thread waits for the app's answer.
        let call: @convention(block) (String, String) -> String = { hostCall($0, $1) }
        context.setObject(call, forKeyedSubscript: "hostCall" as NSString)
        let print: @convention(block) (String) -> Void = { _ in }
        context.setObject(print, forKeyedSubscript: "print" as NSString)
        context.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
    }

    // Everything below runs on `queue`, where the host puts it.

    /// - Returns: The exception, if evaluating threw.
    func load(_ source: String) -> String? {
        exception = nil
        context.evaluateScript(source)
        return exception
    }

    /// Calls the population function the way PopClip does: `actions(input, options, context)`.
    func populate(text: String) -> Result<[String], ScriptFailure> {
        exception = nil
        guard let actions = context.objectForKeyedSubscript("module")?.objectForKeyedSubscript("exports")?
            .objectForKeyedSubscript("actions"), !actions.isUndefined
        else { return .failure(ScriptFailure(message: "module.exports.actions is missing")) }
        let input: [String: Any] = ["text": text, "matchedText": text, "html": "", "markdown": text]
        let environment: [String: Any] = [
            "appName": "Fixture", "appIdentifier": "com.example.fixture", "browserUrl": "", "browserTitle": "",
            "hasFormatting": false, "canPaste": true, "canCopy": true, "canCut": true,
        ]
        let result = actions.call(withArguments: [input, [String: Any](), environment])
        if let exception { return .failure(ScriptFailure(message: exception)) }
        let titles = (result?.toArray() ?? []).compactMap { ($0 as? [String: Any])?["title"] as? String }
        return .success(titles)
    }

    func evaluate(_ script: String) -> Result<String, ScriptFailure> {
        exception = nil
        let value = context.evaluateScript(script)
        if let exception { return .failure(ScriptFailure(message: exception)) }
        return .success(value?.toString() ?? "")
    }
}

final class Host: @unchecked Sendable {
    private let lock = NSLock()
    private var machines: [String: ExtensionVM] = [:]
    private var peer: XPCSession?

    func setPeer(_ session: XPCSession) {
        lock.withLock { peer = session }
    }

    /// Work for a VM is handed to that VM's queue and answered from there, so the session's queue is
    /// free again at once: a slow extension holds up itself and nobody else.
    func handle(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let start = ContinuousClock.now
        guard let request = try? message.decode(as: JSHostRequest.self) else { return JSHostReply.failure("undecodable request") }

        @Sendable func finish(_ reply: JSHostReply) -> JSHostReply {
            var reply = reply
            reply.helperMs = milliseconds(since: start)
            return reply
        }
        func onQueue(of machine: ExtensionVM, _ work: @escaping @Sendable () -> JSHostReply) -> (any Encodable)? {
            nonisolated(unsafe) let message = message
            return message.handoffReply(to: machine.queue) { message.reply(finish(work())) }
        }

        switch request.kind {
        case .ping:
            return finish(JSHostReply())

        case .status:
            return finish(JSHostReply(status: status()))

        case .load:
            guard let id = request.extensionID, let source = request.source else { return JSHostReply.failure("load needs an id and a source") }
            let machine = ExtensionVM(id: id) { [weak self] method, argument in self?.callHost(method, argument) ?? "" }
            lock.withLock { machines[id] = machine }
            return onQueue(of: machine) {
                machine.load(source).map(JSHostReply.failure) ?? JSHostReply()
            }

        case .populate:
            guard let machine = machine(for: request) else { return JSHostReply.failure("no such extension") }
            let text = request.input ?? ""
            return onQueue(of: machine) {
                switch machine.populate(text: text) {
                case .success(let titles): JSHostReply(actionTitles: titles)
                case .failure(let failure): .failure(failure.message)
                }
            }

        case .evaluate:
            guard let machine = machine(for: request) else { return JSHostReply.failure("no such extension") }
            let script = request.script ?? ""
            return onQueue(of: machine) {
                switch machine.evaluate(script) {
                case .success(let value): JSHostReply(value: value)
                case .failure(let failure): .failure(failure.message)
                }
            }

        case .evaluateInLine:
            guard let machine = machine(for: request) else { return JSHostReply.failure("no such extension") }
            let script = request.script ?? ""
            return machine.queue.sync {
                switch machine.evaluate(script) {
                case .success(let value): finish(JSHostReply(value: value))
                case .failure(let failure): JSHostReply.failure(failure.message)
                }
            }

        case .unloadAll:
            lock.withLock { machines.removeAll() }
            return finish(JSHostReply())

        case .exit:
            // After the reply has gone.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { exit(0) }
            return finish(JSHostReply())
        }
    }

    private func machine(for request: JSHostRequest) -> ExtensionVM? {
        lock.withLock { request.extensionID.flatMap { machines[$0] } }
    }

    private func callHost(_ method: String, _ argument: String) -> String {
        guard let peer = lock.withLock({ peer }) else { return "" }
        let reply: JSHostCallReply? = try? peer.sendSync(JSHostCall(method: method, argument: argument))
        return reply?.value ?? ""
    }

    // MARK: What the helper can see of itself

    private func status() -> JSHostStatus {
        JSHostStatus(
            pid: getpid(),
            footprintBytes: Self.footprint(),
            vmCount: lock.withLock { machines.count },
            uptimeMs: milliseconds(since: HelperClock.start),
            sandboxContainer: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            jitMemoryAvailable: Self.jitMemoryAvailable(),
            loopbackConnectErrno: Self.loopbackConnectErrno(),
            canReadOutsideContainer: Self.canReadRealHome()
        )
    }

    private static func footprint() -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    /// JavaScriptCore's JIT needs memory that is writable and executable, which the kernel only gives
    /// a hardened process that has `com.apple.security.cs.allow-jit`. Asking is the direct test.
    private static func jitMemoryAvailable() -> Bool {
        let size = 16_384
        let pointer = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0)
        guard let pointer, pointer != MAP_FAILED else { return false }
        munmap(pointer, size)
        return true
    }

    private static func loopbackConnectErrno() -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 ? 0 : errno
    }

    private static func canReadRealHome() -> Bool {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: String(cString: directory))) != nil
    }
}

_ = HelperClock.start
let host = Host()
let listener = try XPCListener(service: JSHostService.name) { request in
    let (decision, session) = request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in host.handle(message) }
    host.setPeer(session)
    return decision
}
withExtendedLifetime(listener) { dispatchMain() }
