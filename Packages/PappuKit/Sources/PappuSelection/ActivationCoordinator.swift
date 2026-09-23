import CoreGraphics
import Foundation
import PappuAX
import PappuCore

/// The one place a selection attempt lives (architecture §4.3, §4.7).
///
/// Every route arrives here — the mouse tap through `GestureRecognizer`, the shortcut, AppleScript and
/// the URL scheme — and every one of them goes through the same steps: the gate, the app's detection
/// policy, the strategy chain, and then ACT-14's weighing of what came back. Nothing downstream decides
/// whether a bar appears; the coordinator does, and says so by minting an `AppearancePermit`.
///
/// It is an actor, and the work it does is reentrant on purpose: while a read is outstanding the tap
/// keeps being pumped, because the whole of ACT-16a is about what a *later* event does to an attempt
/// that has not finished yet.
public actor ActivationCoordinator {
    public struct Configuration: Sendable {
        public var gesture: GestureRecognizer.Configuration
        public var budgets: BudgetTable
        public var traceCapacity: Int

        public init(
            gesture: GestureRecognizer.Configuration = GestureRecognizer.Configuration(),
            budgets: BudgetTable = .initial,
            traceCapacity: Int = 64
        ) {
            self.gesture = gesture
            self.budgets = budgets
            self.traceCapacity = traceCapacity
        }
    }

    /// What mouse-down learned, before the gesture it belongs to is over (architecture §4.3).
    private struct Pending: Sendable {
        var target: TargetApp
        var focus: AXFocus
        var baseline: AXTextRange?
        /// The pre-evaluation's refusal, kept for the trace. The gate runs again at mouse-up, so this is
        /// never what refuses the attempt.
        var denial: PrivacyDenialReason?
    }

    private let gate: PrivacyGate
    private let policies: DetectionPolicyStore
    private let probe: AXFocusProbe
    private let reader: any SelectionReading
    private let presenter: any BarPresenting
    private let watcher: any AttemptWatching
    private let timing: any ActivationTiming
    private let frontmost: @Sendable () -> TargetApp?
    private let secureInputIsActive: @Sendable () -> Bool
    private let popClipIsRunning: @Sendable () -> Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    private let ids: IDSource<AttemptID>
    private let configuration: Configuration

    private var recogniser: GestureRecognizer
    private var preWork: Task<Pending?, Never>?
    private var inFlight: [AttemptID: Task<Void, Never>] = [:]
    /// Why each attempt stopped being current, read once by the attempt itself (ACT-16b).
    private var invalidations: [AttemptID: AttemptInvalidation] = [:]
    private var trace: AttemptTrace
    private var current: AttemptID?

    /// - Parameters:
    ///   - frontmost: The app a bar would be about. `NSWorkspace.frontmostApplication` in the app; there
    ///     is no default because PappuSelection does not depend on AppKit (architecture §15).
    ///   - popClipIsRunning: ONB-6's half of ACT-10j. `CoexistenceMonitor` in the app.
    ///   - watcher: The watchers of ACT-16a that live outside the coordinator. `AttemptWatcher` in the
    ///     app, whose notices come back through `watch(_:)`; nothing at all in a test that is about
    ///     something else.
    public init(
        gate: PrivacyGate,
        policies: DetectionPolicyStore,
        probe: AXFocusProbe,
        reader: any SelectionReading,
        presenter: any BarPresenting,
        watcher: any AttemptWatching = UnwatchedAttempts(),
        frontmost: @escaping @Sendable () -> TargetApp?,
        secureInputIsActive: @escaping @Sendable () -> Bool = { SecureInput.isActiveSystemWide },
        popClipIsRunning: @escaping @Sendable () -> Bool = { false },
        timing: any ActivationTiming = SystemActivationTiming(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        ids: IDSource<AttemptID> = IDSource(),
        configuration: Configuration = Configuration()
    ) {
        self.gate = gate
        self.policies = policies
        self.probe = probe
        self.reader = reader
        self.presenter = presenter
        self.watcher = watcher
        self.timing = timing
        self.frontmost = frontmost
        self.secureInputIsActive = secureInputIsActive
        self.popClipIsRunning = popClipIsRunning
        self.now = now
        self.ids = ids
        self.configuration = configuration
        recogniser = GestureRecognizer(configuration: configuration.gesture)
        trace = AttemptTrace(capacity: configuration.traceCapacity)
    }

    // MARK: Input

    /// Drives the coordinator from the tap service's stream. One task, for the life of the app.
    public func run(_ events: AsyncStream<EventTapService.Output>) async {
        for await output in events { handle(output) }
    }

    /// Everything the mouse tap saw, in the order it saw it.
    ///
    /// It returns as soon as the recogniser has been fed: an attempt runs in a task of its own, so the
    /// events that would invalidate it are never stuck behind it.
    public func handle(_ output: EventTapService.Output) {
        switch output {
        case .interrupted:
            // A tap was off. A mouse-up may have gone by unseen, so the gesture in progress is void and
            // so is anything it started (ACT-15, ACT-16a).
            let effect = recogniser.reset()
            preWork = nil
            invalidate(.tapInterrupted)
            if let effect { apply(effect) }

        case .pointer(let event):
            // The recogniser is fed first and synchronously, so that the order it sees events in is the
            // order they happened in whatever else is going on.
            let effect = recogniser.handle(event)
            switch event.kind {
            case .down:
                invalidate(.newerInput)
                startPreWork(at: event)
            case .scroll:
                // Scrolling is the user attending to something else; nothing pending is about the screen
                // they are looking at now.
                invalidate(.newerInput)
            case .dragged, .up:
                break
            }
            if let effect { apply(effect) }
        }
    }

    /// Drives the coordinator from the watchers' stream. One task, for the life of the app, as `run` is.
    public func watch(_ notices: AsyncStream<AttemptNotice>) async {
        for await notice in notices { invalidate(notice.reason, of: notice.attempt) }
    }

    /// The routes with no pointer: the shortcut (ACT-5, ACT-6a) and the scripting interfaces (SCR-1, SCR-2).
    public func activate(route: ActivationRoute) {
        start(route: route, candidate: nil)
    }

    /// ACT-16a, for the watchers that live outside this actor: the `AXObserver` on the focused element,
    /// `NSWorkspace`'s activation notices, and the settings that can pause or block an app mid-attempt.
    public func invalidate(_ reason: AttemptInvalidation) {
        guard let current else { return }
        invalidations[current] = reason
        self.current = nil
    }

    /// The same, for a watcher that saw something about one particular attempt. A notice takes a hop to
    /// get here, and by then the attempt it was raised for may be over and a newer one current; what
    /// happened to the old attempt is no reason to retire the new one.
    public func invalidate(_ reason: AttemptInvalidation, of attempt: AttemptID) {
        guard current == attempt else { return }
        invalidate(reason)
    }

    /// Waits for the attempt in flight, if there is one. The app uses it when it pauses or quits; the
    /// tests use it to know that an attempt is over.
    public func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    public var attempts: [AttemptRecord] { trace.all }
    public var lastAttempt: AttemptRecord? { trace.last }
    public var currentAttempt: AttemptID? { current }

    // MARK: Gestures

    private func apply(_ effect: GestureRecognizer.Effect) {
        switch effect {
        case .armLongPress(let press, let deadlineNs):
            timing.armLongPress(atNs: deadlineNs) { [weak self] in
                Task { await self?.longPressFired(press) }
            }
        case .disarmLongPress:
            timing.disarmLongPress()
        case .candidate(let candidate):
            begin(candidate)
        }
    }

    private func longPressFired(_ press: GestureRecognizer.PressID) {
        if let effect = recogniser.longPressTimerFired(press) { apply(effect) }
    }

    private func begin(_ candidate: GestureCandidate) {
        // ACT-7: ⌘ anywhere in the gesture means the user did not want a bar. It is recorded all the
        // same, because "why didn't it appear?" is a question the inspector answers (DIA-2).
        guard candidate.gesture != .suppressed else {
            var record = AttemptRecord(attempt: ids.next(), route: .automatic, gesture: .suppressed)
            record.verdict = .suppressed
            trace.append(record)
            return
        }
        start(route: .automatic, candidate: candidate)
    }

    // MARK: The attempt

    /// The attempt becomes the current one here, synchronously, so that a gesture that finishes later is
    /// never overtaken by one that finished first (ACT-16a).
    private func start(route: ActivationRoute, candidate: GestureCandidate?) {
        invalidate(.newerAttempt)
        let attempt = ids.next()
        current = attempt
        // The clock starts at mouse-up, or at the shortcut press (architecture §3.3). The candidate's own
        // timestamp is on the events' clock, which is not this one; what is lost between the two is the
        // tap callback handing the event over, which it does without reading anything else.
        let clock = AttemptClock(budgets: configuration.budgets, now: now)
        inFlight[attempt] = Task { [weak self] in
            await self?.run(attempt: attempt, route: route, candidate: candidate, clock: clock)
        }
    }

    private func run(
        attempt: AttemptID,
        route: ActivationRoute,
        candidate: GestureCandidate?,
        clock: AttemptClock
    ) async {
        var record = AttemptRecord(attempt: attempt, route: route, gesture: candidate?.gesture)

        // A deliberate route has no mouse-down of its own, and an old one belongs to a gesture the user
        // has since finished with, so it starts from what is true now.
        let pending = route.isDeliberate ? nil : await preWork?.value
        guard let target = pending?.target ?? frontmost() else {
            record.outcome = .refused
            record.verdict = .unreadable
            return await finish(record, clock)
        }
        record.pid = target.pid
        record.bundleID = target.bundleID

        let focus: AXFocus
        if let pending {
            focus = pending.focus
        } else {
            focus = await probe.focus(in: target)
        }
        record.fault = focus.fault

        // Secure input is read again here rather than taken from the pre-work: it is one cheap system
        // call, and it is the one thing in §S1 that can have become true during the gesture (ACT-12).
        let decision = gate.evaluate(
            route: route,
            target: target,
            secureInput: focus.secureInputState(systemWide: secureInputIsActive())
        )
        record.denial = decision.denial?.reason
        guard let permit = decision.permit() else { return await finish(record, clock) }

        let policy = policies.policy(for: target)
        let chain = policy.chain(for: route, popClipIsRunning: popClipIsRunning())
        // ACT-11a: an app whose policy says no automatic bar is read only when the user asks.
        guard route.isDeliberate || policy.autoAppear, !chain.isEmpty else {
            record.verdict = .policyDisallows
            return await finish(record, clock)
        }

        // From here the attempt can be retired from outside: another app coming forward means the user
        // is elsewhere, whether the read has answered yet or not (ACT-16a).
        await watcher.arm(attempt, in: target)
        let read = await reader.read(permit, attempt: attempt, chain: chain, clock: clock)
        // And from here what the attempt holds is a copy of something that can move under it.
        await watcher.readReturned(for: attempt)
        record.strategy = read.strategy
        record.outcome = read.outcome
        record.characters = read.text?.count

        // Everything past this point has an effect, so the attempt has to still be the one the user is
        // waiting for (ACT-16b). A read that arrives late is recorded and dropped.
        if current == attempt, clock.isPastHardCutoff { invalidate(.hardCutoff) }
        if let reason = invalidations[attempt] {
            record.invalidation = reason
            if reason == .hardCutoff { record.verdict = .outOfBudget }
            return await finish(record, clock)
        }

        let verdict = ActivationRules.verdict(for: ActivationSignals(
            route: route,
            gesture: candidate?.gesture,
            focus: focus,
            baseline: pending?.baseline,
            read: read
        ))
        record.verdict = verdict
        guard verdict.showsBar else { return await finish(record, clock) }

        let presentation = AttemptPresentation(
            attempt: attempt,
            route: route,
            target: target,
            verdict: verdict,
            text: read.text,
            range: read.range,
            bounds: read.bounds,
            pointer: candidate?.releaseLocation,
            dragDirection: candidate?.gesture.dragDirection,
            strategy: read.strategy
        )
        await presenter.show(presentation, permit: AppearancePermit(
            attempt: attempt,
            route: route,
            target: target,
            remaining: max(.zero, configuration.budgets.hardCutoff - clock.elapsed)
        ))
        record.showedBar = true
        await finish(record, clock)
    }

    private func finish(_ record: AttemptRecord, _ clock: AttemptClock) async {
        var record = record
        record.elapsed = clock.elapsed
        invalidations[record.attempt] = nil
        inFlight[record.attempt] = nil
        trace.append(record)
        await watcher.disarm(record.attempt)
    }

    // MARK: Mouse-down pre-work

    private func startPreWork(at event: PointerEvent) {
        preWork = Task { [weak self] in await self?.makePending(at: event) ?? nil }
    }

    /// Architecture §4.3, all of it off the latency budget: the app and its policy, the gate's steps 1–3,
    /// and the baseline range. The gate runs here as well as at mouse-up because the baseline is a read
    /// and a read needs a permit.
    private func makePending(at event: PointerEvent) async -> Pending? {
        guard let target = frontmost() else { return nil }
        let focus = await probe.focus(in: target, at: event.location)
        var pending = Pending(target: target, focus: focus)
        let decision = gate.evaluate(
            route: .automatic,
            target: target,
            secureInput: focus.secureInputState(systemWide: secureInputIsActive())
        )
        pending.denial = decision.denial?.reason
        if let permit = decision.permit() {
            pending.baseline = try? await probe.baselineRange(permit).get()
            // Off the latency budget, as everything else here is: registering with this app now leaves
            // the attempt the gesture may become with nothing to do but set a flag (ACT-16a).
            await watcher.prepare(for: target)
        }
        return pending
    }
}

extension Gesture {
    /// BAR-3's half of a gesture: which way the user dragged, when they dragged at all.
    var dragDirection: DragDirection? {
        switch self {
        case .dragSelect(let direction): direction
        case .multiClick, .shiftClick, .longPress, .suppressed: nil
        }
    }
}
