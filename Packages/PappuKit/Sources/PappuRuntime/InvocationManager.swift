import Foundation
import PappuAX
import PappuCore
import PappuSelection

/// Where an invocation is, as anything outside it can see (RUN-3a).
public enum InvocationState: Sendable, Equatable {
    case running
    case finished(InvocationOutcome)
    case invalidated(InvocationInvalidation)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The one place an action run lives (architecture §8, safety spec §S3).
///
/// It owns four things and nothing else: the immutable snapshot of where the text came from (RUN-1a),
/// the list of what has changed since (RUN-1b, RUN-1c), the state that says whether the run is still
/// live (RUN-3a), and the handles that must be given back when it ends — the destination elements the
/// probe is holding and the key tap lease the quiescence tier needs (RUN-2g, ACT-19).
///
/// It does no verification of its own: `DestinationVerifier` decides, and the manager's part is to
/// make sure nothing can ask for a verification — or keep a permit — for a run that is no longer live.
/// The two rules that matter are both enforced here rather than promised:
///
/// - **Cancellation is synchronous.** `cancel` flips the state before its first `await`, so an
///   invocation cannot be verified, mutate, or report success after the user pressed Escape, however
///   the tasks interleave (RUN-3a–3c).
/// - **The snapshot is never written to.** There is no API that changes one. A world that moved is
///   recorded beside it as a `DestinationChange`, and read by nobody who decides anything (RUN-1b).
public actor InvocationManager {
    /// Everything a live run holds. Gone the moment it ends, which is what releases the lease and the
    /// destination element.
    private struct Live {
        var request: InvocationRequest
        var snapshot: DestinationSnapshot
        var watch: (any InputWatch)?
        var work: [any CancellableWork] = []
        var started: ContinuousClock.Instant
    }

    private let verifier: DestinationVerifier
    private let probe: any DestinationProbing
    private let epochs: any InputEpochReading
    private let timing: InvocationTiming
    private let sleeper: any InvocationSleeping
    private let now: @Sendable () -> ContinuousClock.Instant
    private let ids: IDSource<InvocationID>

    private var live: [InvocationID: Live] = [:]
    private var states: [InvocationID: InvocationState] = [:]
    private var trace: InvocationTrace
    /// RUN-1c. True between an explicit surface taking focus and giving it back.
    private var ownSurfaceHasFocus = false

    public init(
        verifier: DestinationVerifier,
        probe: any DestinationProbing,
        epochs: any InputEpochReading,
        timing: InvocationTiming = .initial,
        sleeper: any InvocationSleeping = SystemInvocationSleep(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        ids: IDSource<InvocationID> = IDSource(),
        traceCapacity: Int = 32
    ) {
        self.verifier = verifier
        self.probe = probe
        self.epochs = epochs
        self.timing = timing
        self.sleeper = sleeper
        self.now = now
        self.ids = ids
        trace = InvocationTrace(capacity: traceCapacity)
    }

    // MARK: Starting

    /// RUN-1a. Takes the snapshot and starts the run.
    ///
    /// The order inside is deliberate. The key tap lease is taken *before* the epoch is read, so that
    /// the number the snapshot carries is a number the tap was already watching; the other order leaves
    /// a window in which a keystroke lands in neither the old epoch nor the tap's count. A run that may
    /// not mutate takes no lease and carries no epoch, because an epoch with no key tap behind it is
    /// only two thirds of an answer and would read as one (RUN-2g).
    public func begin(_ request: InvocationRequest) async -> InvocationID {
        let invocation = ids.next()
        let started = now()

        var watch: (any InputWatch)?
        var epoch: InputEpoch?
        if request.mayMutate {
            watch = epochs.watchInput()
            if watch != nil { epoch = epochs.inputEpoch }
        }

        let handle = await probe.capture(request.target)

        let snapshot = DestinationSnapshot(
            attempt: request.attempt,
            route: request.route,
            target: request.target,
            handle: handle,
            range: request.range,
            text: request.text.map(TextDigest.init),
            strategy: request.strategy,
            epoch: epoch,
            taken: started
        )

        live[invocation] = Live(request: request, snapshot: snapshot, watch: watch, started: started)
        states[invocation] = .running

        var record = InvocationRecord(
            invocation: invocation,
            attempt: request.attempt,
            route: request.route,
            action: request.action,
            target: request.target,
            mayMutate: request.mayMutate
        )
        record.characters = request.text?.count
        record.strategy = request.strategy
        record.watchedInput = watch != nil
        trace.append(record)

        return invocation
    }

    // MARK: Verifying

    /// RUN-2a. The only way to earn the right to write text into the destination.
    ///
    /// Called before every host-controlled effect and again at click time for Replace and Insert
    /// (RUN-2e) — the same call each time, and each one recorded.
    ///
    /// The state is checked twice: once before looking, and once after, because looking suspends and
    /// the user's Escape key does not wait its turn. Without the second check a permit could outlive
    /// the invocation it belongs to by exactly the length of one Accessibility round trip (RUN-3b).
    public func verifyDestination(of invocation: InvocationID) async -> DestinationVerification {
        guard let snapshot = live[invocation]?.snapshot else {
            return .blocked(
                DestinationBlock(
                    invocation: invocation,
                    target: target(of: invocation),
                    failures: [.invocationNotRunning]
                )
            )
        }

        let verification = await verifier.verify(invocation, against: snapshot)

        guard live[invocation] != nil else {
            // Cancelled while we were looking. The permit inside dies here, unspent.
            let target = snapshot.target
            trace.update(invocation) {
                $0.verifications.append(.unverifiable)
                $0.failure = .invocationNotRunning
            }
            return .blocked(
                DestinationBlock(invocation: invocation, target: target, failures: [.invocationNotRunning])
            )
        }

        trace.update(invocation) { record in
            record.verifications.append(verification.tier)
            if let block = verification.block {
                record.failure = block.primary
                record.denial = block.denial ?? record.denial
                record.fault = block.fault ?? record.fault
            }
        }

        return verification
    }

    /// The snapshot as it was taken. Read-only on purpose: there is no setter anywhere (RUN-1b).
    public func snapshot(of invocation: InvocationID) -> DestinationSnapshot? {
        live[invocation]?.snapshot
    }

    // MARK: What changed since (RUN-1b, RUN-1c)

    /// Records something the watchers saw. It changes no decision; see `DestinationChange`.
    ///
    /// A focus change reported while a PappuClip surface has focus is recorded as RUN-1c's own case
    /// instead, so a watcher that only knows "focus moved" cannot make our own bar look like a new
    /// destination.
    public func noticed(_ change: DestinationChange, for invocation: InvocationID? = nil) {
        let change = (change == .focusChanged && ownSurfaceHasFocus) ? .focusEnteredOwnSurface : change
        let targets = invocation.map { [$0] } ?? Array(live.keys)
        for id in targets where live[id] != nil {
            trace.update(id) { $0.changes.append(change) }
        }
    }

    /// RUN-1c. The user opened one of our surfaces and focus went into it — the bar's own field, the
    /// inspector. The destination has not changed; the keyboard has moved, and that is all.
    public func focusEnteredOwnSurface() {
        ownSurfaceHasFocus = true
        noticed(.focusEnteredOwnSurface)
    }

    public func focusLeftOwnSurface() {
        ownSurfaceHasFocus = false
        noticed(.focusLeftOwnSurface)
    }

    public var focusIsInOwnSurface: Bool { ownSurfaceHasFocus }

    /// What has changed since the snapshot, for the bar's explanation and the inspector.
    public func changes(for invocation: InvocationID) -> [DestinationChange] {
        trace[invocation]?.changes ?? []
    }

    // MARK: Work

    /// Registers something that can be stopped, so that cancelling the invocation cancels it too
    /// (RUN-3d). Returns false for a run that has already ended, whose caller should stop the work it
    /// just started.
    @discardableResult
    public func attach(_ work: any CancellableWork, to invocation: InvocationID) -> Bool {
        guard live[invocation] != nil else { return false }
        live[invocation]?.work.append(work)
        return true
    }

    // MARK: Ending

    /// RUN-3b, RUN-3c: the gate a late result passes before anything is done with it.
    public func accepts(_ invocation: InvocationID) -> Bool {
        live[invocation] != nil
    }

    /// Records that text actually went into the destination, for the record and for RUN-4's reporting.
    public func noteMutation(of invocation: InvocationID) {
        trace.update(invocation) { $0.mutated = true }
    }

    /// Ends a run that got where it was going.
    ///
    /// - Returns: False when the invocation was already cancelled, paused or revoked, which is the
    ///   caller's signal to throw the result away rather than show it (RUN-3c).
    @discardableResult
    public func finish(_ invocation: InvocationID, outcome: InvocationOutcome) async -> Bool {
        guard let ended = live.removeValue(forKey: invocation) else { return false }
        states[invocation] = .finished(outcome)
        ended.watch?.stop()
        trace.update(invocation) { record in
            record.outcome = outcome
            record.elapsed = ended.started.duration(to: now())
        }
        if let handle = ended.snapshot.handle { await probe.release(handle) }
        return true
    }

    /// RUN-3a–3e. Invalidates the run and stops what it started.
    ///
    /// Everything that makes the run un-live happens before the first `await`: the state, the lease,
    /// the list of work. What comes after is only the asking and the waiting, and by then no effect
    /// this invocation asks for can be granted.
    @discardableResult
    public func cancel(
        _ invocation: InvocationID,
        reason: InvocationInvalidation = .cancelled
    ) async -> CancellationReport {
        guard let ended = live.removeValue(forKey: invocation) else {
            return CancellationReport(invocation: invocation, reason: reason, alreadyEnded: true)
        }
        states[invocation] = .invalidated(reason)
        ended.watch?.stop()
        trace.update(invocation) { record in
            record.invalidation = reason
            record.elapsed = ended.started.duration(to: now())
        }

        var report = await stop(ended.work, reason: reason, of: invocation)
        if let handle = ended.snapshot.handle { await probe.release(handle) }
        report.invocation = invocation
        trace.update(invocation) { $0.cancellation = report }
        return report
    }

    /// RUN-3f. Pause and revocation take everything in flight, on the same path as cancellation.
    @discardableResult
    public func invalidateAll(_ reason: InvocationInvalidation) async -> [CancellationReport] {
        var reports: [CancellationReport] = []
        for invocation in live.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            reports.append(await cancel(invocation, reason: reason))
        }
        return reports
    }

    /// Asks the work to stop: owned work is waited for, up to the grace; delegated work is asked and
    /// reported as possibly complete, because that is the truth (RUN-3d, RUN-3e).
    private func stop(
        _ work: [any CancellableWork],
        reason: InvocationInvalidation,
        of invocation: InvocationID
    ) async -> CancellationReport {
        var report = CancellationReport(invocation: invocation, reason: reason)
        let delegated = work.filter { $0.ownership == .delegated }
        let owned = work.filter { $0.ownership == .owned }

        for one in delegated {
            report.asked += 1
            report.mayHaveCompleted = true
            // Asked, never waited for: a Shortcut or an AppleScript send can take as long as it likes,
            // and cancellation must not (RUN-3e).
            Task { _ = await one.cancel() }
        }

        guard !owned.isEmpty else { return report }

        let grace = timing.cancellationGrace
        let sleeper = sleeper
        let outcomes: [WorkCancellation]? = await withTaskGroup(of: [WorkCancellation]?.self) { group in
            group.addTask {
                await withTaskGroup(of: WorkCancellation.self) { inner in
                    for one in owned { inner.addTask { await one.cancel() } }
                    var results: [WorkCancellation] = []
                    for await outcome in inner { results.append(outcome) }
                    return results
                }
            }
            group.addTask {
                await sleeper.sleep(for: grace)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let outcomes else {
            // The grace ran out. We stop waiting and say so rather than hold the UI (RUN-3e).
            report.asked += owned.count
            report.graceExpired = true
            report.mayHaveCompleted = true
            return report
        }

        for outcome in outcomes {
            switch outcome {
            case .stopped: report.stopped += 1
            case .askedToStop: report.asked += 1
            case .mayHaveCompleted:
                report.asked += 1
                report.mayHaveCompleted = true
            case .cannotStop:
                report.unstoppable += 1
                report.mayHaveCompleted = true
            }
        }
        return report
    }

    // MARK: Looking in

    public func state(of invocation: InvocationID) -> InvocationState? {
        states[invocation]
    }

    /// Oldest first, for the inspector (DIA-2).
    public var records: [InvocationRecord] { trace.all }
    public var lastRecord: InvocationRecord? { trace.last }

    public func record(of invocation: InvocationID) -> InvocationRecord? {
        trace[invocation]
    }

    public var runningInvocations: [InvocationID] {
        live.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private func target(of invocation: InvocationID) -> TargetApp {
        if let record = trace[invocation], let pid = record.pid {
            return TargetApp(pid: pid, bundleID: record.bundleID)
        }
        return TargetApp(pid: 0, bundleID: nil)
    }
}
