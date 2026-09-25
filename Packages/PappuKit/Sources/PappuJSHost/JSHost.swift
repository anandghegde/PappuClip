import Darwin
import Foundation
import PappuJSBridge
import Synchronization

/// The helper's dispatcher: one `ExtensionVM` per extension, and the lifecycle of each (architecture
/// §10.1, §10.2).
///
/// It knows nothing of XPC. `JSHostListener` feeds it requests from the app's session; the tests feed
/// it the same requests in-process, which is how isolation is tested without a helper bundle.
///
/// **The lifecycle.** `load` makes a fresh world and replaces any the extension had — an update, or a
/// reload after the app changed its mind about the files — and answers everything the old one still
/// owed `dropped`. `invoke` runs in the world at the generation it names, or is answered `notLoaded`,
/// and so does `describe`, which runs a module extension's module and answers what it exported (JS-12).
/// `drop` answers an invocation now and discards whatever it settles to later. `unload` forgets the
/// world. Each of these runs on the world's own queue, so they happen in the order they were sent and
/// never while its script is running — which is also why a script stuck in a loop cannot be dropped
/// from in here, and the app kills the helper instead (§9.5). A script waiting in a synchronous host
/// call is the one exception, and a `drop` ends that wait from outside the queue first.
///
/// **Host calls** (architecture §10.4) go out through `call`, with the extension's name filled in by
/// the world rather than by its script, and come back to the world that asked.
public final class JSHost: Sendable {
    public typealias Reply = @Sendable (JSHostReply) -> Void
    public typealias Call = @Sendable (JSHostCall, @escaping @Sendable (JSHostAnswer) -> Void) -> Void

    private let machines = Mutex<[String: ExtensionVM]>([:])
    /// Which world each unsettled invocation is running in, so a `drop` can find it.
    private let running = Mutex<[UInt64: ExtensionVM]>([:])
    private let log: @Sendable (String, String) -> Void
    private let call: Call
    private let qos: DispatchQoS

    /// - Parameters:
    ///   - qos: What each world's queue runs at. The helper's own is `userInitiated`: an action is
    ///     something a person just asked for. A helper run inside a test process runs lower, so that a
    ///     script spinning in it cannot outrank the test's own timers.
    ///   - call: Sends a host call to the app, and gives its answer back exactly once, on any queue.
    ///     Without one, every call is refused.
    ///   - log: A line printed by an extension, with the extension's name. Called on that extension's
    ///     queue.
    public init(
        qos: DispatchQoS = .userInitiated,
        call: @escaping Call = { _, answer in answer(.refused("There is no app to ask.")) },
        log: @escaping @Sendable (_ extensionName: String, _ line: String) -> Void
    ) {
        self.qos = qos
        self.call = call
        self.log = log
    }

    /// Answers `request` by calling `reply` exactly once — now, later, and on any queue.
    public func handle(_ request: JSHostRequest, reply: @escaping Reply) {
        switch request {
        case .identify:
            reply(.identity(processID: getpid()))

        case .load(let load):
            let name = load.extensionName
            let machine = ExtensionVM(load: load, qos: qos, host: call) { [log] line in log(name, line) }
            let replaced = machines.withLock { machines in
                defer { machines[name] = machine }
                return machines[name]
            }
            replaced?.interruptAll()
            replaced?.queue.async { replaced?.abandon() }
            machine.queue.async {
                if let failure = machine.prepare() {
                    self.machines.withLock { if $0[name] === machine { $0[name] = nil } }
                    reply(.loadFailed(failure))
                } else {
                    reply(.loaded)
                }
            }

        case .invoke(let invocation):
            let machine = machines.withLock { $0[invocation.extensionName] }
            guard let machine, machine.generation == invocation.generation else { return reply(.notLoaded) }
            let id = invocation.invocation
            running.withLock { $0[id] = machine }
            machine.queue.async {
                machine.invoke(invocation) { answer in
                    self.running.withLock { if $0[id] === machine { $0[id] = nil } }
                    reply(answer)
                }
            }

        case .describe(let request):
            let machine = machines.withLock { $0[request.extensionName] }
            guard let machine, machine.generation == request.generation else { return reply(.notLoaded) }
            machine.queue.async { reply(machine.describeModule(request)) }

        case .drop(let id):
            guard let machine = running.withLock({ $0.removeValue(forKey: id) }) else { return reply(.dropped) }
            machine.interrupt(id)
            machine.queue.async {
                machine.drop(id)
                reply(.dropped)
            }

        case .unload(let name):
            guard let machine = machines.withLock({ $0.removeValue(forKey: name) }) else { return reply(.unloaded) }
            machine.interruptAll()
            machine.queue.async {
                machine.abandon()
                reply(.unloaded)
            }
        }
    }

    /// The extensions with a world, for tests and the helper's own diagnostics.
    public var loaded: Set<String> {
        machines.withLock { Set($0.keys) }
    }
}
