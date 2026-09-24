import Foundation
import PappuApp
import PappuAX
import PappuCore
import PappuRuntime
import PappuSelection
import PappuSurfaces
import Synchronization

// The bridge's own edges, and only those. The runtime's fakes stay in PappuRuntimeTests because they
// stand in for seams that module owns; these are the smallest things that will hold an
// `InvocationManager` and the two runners up while the bridge is the thing under test.

/// The bar, as much of it as an invocation can see.
@MainActor
final class RecordingBar: InvocationReporting {
    enum Event: Sendable, Equatable {
        case reported(BarFeedbackState)
        case dismissed(BarDismissalReason)
    }

    private(set) var events: [Event] = []

    var states: [BarFeedbackState] {
        events.compactMap {
            if case .reported(let state) = $0 { return state }
            return nil
        }
    }

    var dismissals: [BarDismissalReason] {
        events.compactMap {
            if case .dismissed(let reason) = $0 { return reason }
            return nil
        }
    }

    func report(_ state: BarFeedbackState) { events.append(.reported(state)) }
    func dismiss(_ reason: BarDismissalReason) { events.append(.dismissed(reason)) }
}

/// An app with nothing to take hold of, which is the ordinary case for the three built-ins that need no
/// verification. The two that do are `BuiltinRunnerTests`' subject, not this one's.
final class AbsentDestination: DestinationProbing {
    func capture(_ target: TargetApp) async -> DestinationHandle? { nil }

    func look(
        for handle: DestinationHandle?,
        in target: TargetApp,
        frontmost: TargetApp?,
        permit: consuming ReadPermit
    ) async -> DestinationEvidence {
        DestinationEvidence()
    }

    func release(_ handle: DestinationHandle) async {}
}

/// Every wait, taken at once. The durations are kept so a test can say what was asked for rather than
/// how long it took.
final class InstantSleep: InvocationSleeping {
    private let asked = Mutex<[Duration]>([])

    var durations: [Duration] { asked.withLock { $0 } }

    func sleep(for duration: Duration) async {
        asked.withLock { $0.append(duration) }
    }
}

/// Accepts everything and remembers it, like `NSWorkspace` on a good day.
final class RecordingURLOpener: URLOpening {
    private let asked = Mutex<[URL]>([])

    var urls: [URL] { asked.withLock { $0 } }

    func open(_ requests: [URLOpenRequest]) async -> Int {
        asked.withLock { $0.append(contentsOf: requests.map(\.url)) }
        return requests.count
    }
}

/// The trust database as a thing that can be poked: `fire()` is the notification arriving, and the
/// subscription count is how the "start twice does not subscribe twice" contract is asserted.
final class FakeTrustWatcher: AccessibilityTrustWatching {
    private let state = Mutex<(starts: Int, stops: Int, fire: (@Sendable () -> Void)?)>((0, 0, nil))

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }

    func start(_ fire: @escaping @Sendable () -> Void) {
        state.withLock { state in
            state.starts += 1
            state.fire = fire
        }
    }

    func stop() {
        state.withLock { state in
            state.stops += 1
            state.fire = nil
        }
    }

    /// The system saying "something about Accessibility trust changed". It never says whose.
    func fire() {
        state.withLock { $0.fire }?()
    }
}

/// `AXIsProcessTrusted`, as something a test can change under a running monitor.
final class FakeTrust: Sendable {
    private let trusted: Mutex<Bool>

    init(_ trusted: Bool) {
        self.trusted = Mutex(trusted)
    }

    var isTrusted: Bool { trusted.withLock { $0 } }

    func set(_ new: Bool) {
        trusted.withLock { $0 = new }
    }

    var reader: @Sendable () -> Bool { { self.isTrusted } }
}

/// Every onboarding state the store announced, in order. A class rather than a local `Mutex` because the
/// monitor's tests need it alongside three other things a scene holds.
final class RecordingOnboarding: Sendable {
    private let seen = Mutex<[OnboardingState]>([])

    var states: [OnboardingState] { seen.withLock { $0 } }
    var grants: [AccessibilityGrant] { states.map(\.grant) }

    func note(_ state: OnboardingState) {
        seen.withLock { $0.append(state) }
    }
}

/// A key-press poster that sends nothing and counts what it was asked to send.
final class CountingKeyPresses: SyntheticKeyPressPosting {
    private let asked = Atomic<Int>(0)

    var count: Int { asked.load(ordering: .relaxed) }

    func post(_ combo: KeyCombo, to delivery: KeyPressDelivery) -> Bool {
        asked.add(1, ordering: .relaxed)
        return true
    }
}

/// Shortcuts that all answer the same thing at once.
struct AnsweringShortcuts: ShortcutRunning {
    var answer: ShortcutResult = .returned("the answer")

    func start(_ name: String, input: String) -> (any ShortcutRun)? {
        Run(answer: answer)
    }

    struct Run: ShortcutRun {
        let answer: ShortcutResult
        var ownership: WorkOwnership { .delegated }
        func cancel() async -> WorkCancellation { .mayHaveCompleted }
        func result() async -> ShortcutResult { answer }
    }
}

/// Shell scripts, AppleScripts and Services that all answer the same thing at once.
struct AnsweringScripts: ShellScriptRunning, AppleScriptRunning, ServiceRunning {
    var answer: ScriptResult = .returned("the answer")

    func start(_ job: ShellScriptJob) async -> (any ScriptRun)? { Run(answer: answer) }
    func start(_ job: AppleScriptRunRequest) async -> (any ScriptRun)? { Run(answer: answer) }
    func start(service name: String, text: String) async -> (any ScriptRun)? { Run(answer: answer) }

    struct Run: ScriptRun {
        let answer: ScriptResult
        var ownership: WorkOwnership { .owned }
        func cancel() async -> WorkCancellation { .mayHaveCompleted }
        func result() async -> ScriptResult { answer }
    }
}

/// What the bridge asked of the user after a script, and for which action, in order — and what the
/// bar had been told by then.
@MainActor
final class RecordingAttention: AttentionPresenting {
    private(set) var presented: [(attention: ExtensionRunner.Attention, action: String)] = []
    private(set) var barStatesBefore: [[BarFeedbackState]] = []
    private weak var bar: RecordingBar?

    init(bar: RecordingBar) {
        self.bar = bar
    }

    func present(_ attention: ExtensionRunner.Attention, for action: String, owner: String?) {
        presented.append((attention, action))
        barStatesBefore.append(bar?.states ?? [])
    }
}

/// What the bar's Install Extension offer handed on, and what the bar had been told by then.
@MainActor
final class RecordingInstaller: SelectionInstalling {
    private(set) var installed: [String] = []
    private(set) var barEventsBefore: [[RecordingBar.Event]] = []
    private weak var bar: RecordingBar?

    init(bar: RecordingBar) {
        self.bar = bar
    }

    func installExtension(fromSelection text: String) async {
        installed.append(text)
        barEventsBefore.append(bar?.events ?? [])
    }
}
