import Foundation
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import Synchronization

// The runtime's fakes live in its own test target rather than in PappuTestSupport, for the same reason
// the bar's do: they stand in for seams only this module has, and a fake in the shared target is a fake
// every other target has to read past.

/// A destination that answers what the test tells it to answer.
///
/// It also records what it was asked and what it was holding, which is how the leak test knows an
/// invocation gave its element back.
final class FakeDestinationProbe: DestinationProbing {
    struct Look: Sendable, Equatable {
        var handle: DestinationHandle?
        var target: TargetApp
        var frontmost: TargetApp?
        /// From the permit it was handed. A look with no permit cannot be written down, because it
        /// cannot be made.
        var route: ActivationRoute
    }

    private struct State {
        var evidence: DestinationEvidence
        var captures = true
        var next: UInt64 = 1
        var held: Set<DestinationHandle> = []
        var looks: [Look] = []
        var released: [DestinationHandle] = []
        var hold: Gate?
    }

    private let state: Mutex<State>

    init(_ evidence: DestinationEvidence = DestinationEvidence()) {
        state = Mutex(State(evidence: evidence))
    }

    /// What the next look finds.
    var evidence: DestinationEvidence {
        get { state.withLock { $0.evidence } }
        set { state.withLock { $0.evidence = newValue } }
    }

    /// An app with nothing to take hold of: no tree, no focused element.
    func capturesNothing() {
        state.withLock { $0.captures = false }
    }

    /// Makes the next look suspend until the gate is opened, which is how a test gets between the
    /// verification and its answer — where cancellation actually lands.
    func holdLooks(until gate: Gate) {
        state.withLock { $0.hold = gate }
    }

    var looks: [Look] { state.withLock { $0.looks } }
    var heldCount: Int { state.withLock { $0.held.count } }
    var released: [DestinationHandle] { state.withLock { $0.released } }

    func capture(_ target: TargetApp) async -> DestinationHandle? {
        state.withLock { state in
            guard state.captures else { return nil }
            let handle = DestinationHandle(rawValue: state.next)
            state.next += 1
            state.held.insert(handle)
            return handle
        }
    }

    func look(
        for handle: DestinationHandle?,
        in target: TargetApp,
        frontmost: TargetApp?,
        permit: consuming ReadPermit
    ) async -> DestinationEvidence {
        let route = permit.route
        let hold = state.withLock { state -> Gate? in
            state.looks.append(Look(handle: handle, target: target, frontmost: frontmost, route: route))
            return state.hold
        }
        await hold?.wait()
        return state.withLock { $0.evidence }
    }

    func release(_ handle: DestinationHandle) async {
        state.withLock { state in
            state.held.remove(handle)
            state.released.append(handle)
        }
    }
}

/// The taps, as much of them as the runtime can see: a number that goes up when the user does
/// something, and a lease that says whether keys are visible at all.
final class FakeInput: InputEpochReading {
    private struct State {
        var epoch: UInt64 = 0
        var keyTapAvailable = true
        var open = 0
        var taken = 0
        var stopped = 0
    }

    private let state = Mutex(State())

    init(keyTapAvailable: Bool = true) {
        state.withLock { $0.keyTapAvailable = keyTapAvailable }
    }

    var inputEpoch: InputEpoch { InputEpoch(rawValue: state.withLock { $0.epoch }) }

    /// The user pressed a key or clicked, outside our own surfaces.
    func happened(_ times: Int = 1) {
        state.withLock { $0.epoch += UInt64(times) }
    }

    /// How many leases are open now, and how many were ever taken.
    var openLeases: Int { state.withLock { $0.open } }
    var leasesTaken: Int { state.withLock { $0.taken } }
    var leasesStopped: Int { state.withLock { $0.stopped } }

    func watchInput() -> (any InputWatch)? {
        let granted: Bool = state.withLock { state in
            guard state.keyTapAvailable else { return false }
            state.open += 1
            state.taken += 1
            return true
        }
        guard granted else { return nil }
        return Lease { self.giveBack() }
    }

    private func giveBack() {
        state.withLock { state in
            state.open -= 1
            state.stopped += 1
        }
    }

    private final class Lease: InputWatch {
        private let onStop: @Sendable () -> Void
        private let done = Atomic<Bool>(false)

        init(_ onStop: @escaping @Sendable () -> Void) {
            self.onStop = onStop
        }

        func stop() {
            guard done.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
            onStop()
        }
    }
}

/// Something the invocation started. `hangs` is the script process that ignores the signal.
final class FakeWork: CancellableWork {
    let ownership: WorkOwnership
    private let answer: WorkCancellation
    private let hangs: Bool
    private let asked = Atomic<Int>(0)

    init(_ ownership: WorkOwnership, answers: WorkCancellation = .stopped, hangs: Bool = false) {
        self.ownership = ownership
        answer = answers
        self.hangs = hangs
    }

    var timesAsked: Int { asked.load(ordering: .relaxed) }

    func cancel() async -> WorkCancellation {
        asked.wrappingAdd(1, ordering: .relaxed)
        if hangs {
            // Stops when the manager gives up waiting and cancels the group.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        }
        return answer
    }
}

/// The cancellation grace, without the wait.
final class FakeSleep: InvocationSleeping {
    enum Behaviour: Sendable {
        /// The grace is already over: whatever the owned work is doing, it is too late.
        case expiresAtOnce
        /// The grace is longer than the work takes, which is the ordinary case.
        case outlastsTheWork
    }

    private let behaviour: Behaviour
    private let slept = Mutex<[Duration]>([])

    init(_ behaviour: Behaviour = .outlastsTheWork) {
        self.behaviour = behaviour
    }

    var durations: [Duration] { slept.withLock { $0 } }

    func sleep(for duration: Duration) async {
        slept.withLock { $0.append(duration) }
        switch behaviour {
        case .expiresAtOnce:
            return
        case .outlastsTheWork:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }
}

// MARK: Shorthands

let editor = TargetApp(pid: 501, bundleID: "com.example.editor")
let terminal = TargetApp(pid: 777, bundleID: "com.example.terminal")

/// Everything allowed, so that a test that takes one thing away is taking one thing away.
let permissivePolicy = DetectionPolicy(
    strategies: [.ax],
    autoAppear: true,
    autoSyntheticCopy: true,
    hotkeySyntheticCopy: true,
    quiescence: true
)

func policies(quiescence: Bool = true) -> DetectionPolicyStore {
    DetectionPolicyStore(
        DetectionPolicies(default: DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: true,
            hotkeySyntheticCopy: true,
            quiescence: quiescence
        )),
        ceilings: .none
    )
}

/// The evidence a well-behaved text field gives when nothing has moved.
func settled(range: AXTextRange? = AXTextRange(location: 10, length: 5), text: String? = "selected") -> DestinationEvidence {
    DestinationEvidence(
        isFrontmost: true,
        sameWindow: true,
        sameElement: true,
        isEditable: true,
        range: range,
        text: text.map(TextDigest.init)
    )
}

/// Waits for something a fire-and-forget task does, without a sleep long enough to slow the suite.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A place for a test to stand in the middle of an await.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for one in waiting { one.resume() }
        waiting = []
    }
}

/// One mutable value the test and the code under test can both see. A `Mutex` cannot be passed as a
/// parameter or stored in a copyable struct, and a scenario needs to hand the same "which app is in
/// front" to a verifier and then change it.
final class Box<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var current: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// `NSWorkspace`, as a list of what it was asked to open.
///
/// It answers "yes" by default and can be told to refuse, which is the difference between Search
/// opening a tab and Search reporting that it did not.
final class FakeURLOpener: URLOpening {
    private struct State {
        var requests: [URLOpenRequest] = []
        var accepts = true
    }

    private let state = Mutex(State())

    init(accepts: Bool = true) {
        state.withLock { $0.accepts = accepts }
    }

    /// Every request, flattened, in the order they were made — which is the order the tabs appear in.
    var requests: [URLOpenRequest] { state.withLock { $0.requests } }
    var urls: [URL] { requests.map(\.url) }

    func open(_ requests: [URLOpenRequest]) async -> Int {
        state.withLock { state in
            state.requests.append(contentsOf: requests)
            return state.accepts ? requests.count : 0
        }
    }
}
