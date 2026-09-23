import Foundation
import PappuAX
import PappuCore
import PappuSelection

/// What an action run is asked to do, at the moment the user clicks (architecture §8.1).
///
/// The selection text is here because the snapshot needs its digest and the action needs the text, and
/// it goes no further: `InvocationManager` keeps the digest and the length, never the string.
public struct InvocationRequest: Sendable {
    /// The attempt whose bar the user clicked. Kept so that a record can be read against an
    /// `AttemptRecord` and so that a stale bar's click can be recognised.
    public var attempt: AttemptID
    public var route: ActivationRoute
    public var target: TargetApp
    /// The action's identifier, as `ActionKey` spells it —
    /// `app.pappuclip.builtin.paste#paste`. An identifier, not a title, because a title can carry
    /// the user's own words.
    public var action: String
    /// Whether this run may end in host-controlled text going into the destination — a `paste-result`
    /// action, Cut, Paste, or anything whose result the bar will offer Replace and Insert for
    /// (BAR-17, RUN-2e).
    ///
    /// It decides whether the key tap is held for the run (RUN-2g, ACT-19), so an action that *might*
    /// let the user paste the result later says true here and not at click time: a tap installed after
    /// the fact has seen nothing, and a quiescence verification would be a guess.
    public var mayMutate: Bool
    public var text: String?
    public var range: AXTextRange?
    public var strategy: SelectionStrategyKind?

    public init(
        attempt: AttemptID,
        route: ActivationRoute,
        target: TargetApp,
        action: String,
        mayMutate: Bool,
        text: String? = nil,
        range: AXTextRange? = nil,
        strategy: SelectionStrategyKind? = nil
    ) {
        self.attempt = attempt
        self.route = route
        self.target = target
        self.action = action
        self.mayMutate = mayMutate
        self.text = text
        self.range = range
        self.strategy = strategy
    }
}

/// Who is running the work, which decides what cancellation can promise (RUN-3d, RUN-3e).
public enum WorkOwnership: String, Sendable, Codable, CaseIterable {
    /// In our process, or a child process we spawned: a shell script, a JavaScript task, a URL fetch.
    /// These can be stopped, and cancellation waits a moment for them to stop.
    case owned
    /// Something another process is doing on our behalf: AppleScript in the target app, a Shortcut, a
    /// Service. These can be asked and nothing more (RUN-3e).
    case delegated
}

/// What asking the work to stop achieved.
public enum WorkCancellation: String, Sendable, Codable, CaseIterable {
    /// It is not running any more, and it did not finish.
    case stopped
    /// The request was delivered and the answer is unknown, which is the best a delegated action can
    /// do. Never reported as stopped, because the effect may already have happened.
    case askedToStop
    /// It was already past the point of no return.
    case mayHaveCompleted
    /// There is no way to stop this kind of work at all.
    case cannotStop
}

/// The seam between the lifecycle and the things that actually run: a script process, a JavaScript
/// task, an AppleScript send. `InvocationManager` knows only this much about any of them.
public protocol CancellableWork: Sendable {
    var ownership: WorkOwnership { get }
    /// Asked once. It must return without waiting on anything it cannot bound — for delegated work the
    /// manager does not wait for it at all.
    func cancel() async -> WorkCancellation
}

/// Waiting, behind a seam so the cancellation grace does not make a test take two seconds.
public protocol InvocationSleeping: Sendable {
    func sleep(for duration: Duration) async
}

public struct SystemInvocationSleep: InvocationSleeping {
    public init() {}

    public func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// Why an invocation stopped being live (RUN-3a, RUN-3f).
///
/// One list, because the spec asks pause and revocation to invalidate "in the same way" as
/// cancellation: same path, same rejection of late results, different word in the record.
public enum InvocationInvalidation: String, Sendable, Codable, CaseIterable {
    /// The user cancelled: Escape, the bar's stop control, clicking away from a running action.
    case cancelled
    /// ACT-18. Pause invalidates whatever is in flight (RUN-3f).
    case paused
    /// SEC-4, SEC-5: a capability or an extension was revoked under the running action.
    case revoked
    /// A hard block turned on, or secure input began, while the action was running (ACT-12, ACT-17a).
    case privacyStateChanged
    /// The app we were acting on went away.
    case targetGone
    /// The app is quitting.
    case shuttingDown
}

/// How a run ended when it was allowed to end by itself.
public enum InvocationOutcome: String, Sendable, Codable, CaseIterable {
    /// The action ran and its effect, if any, was applied.
    case completed
    /// The action ran and the result could not be written where it came from, so it was offered for
    /// explicit copy instead (RUN-2c).
    case blocked
    /// The action itself failed: a script exited non-zero, a fetch timed out.
    case failed
}

/// What the world did while the invocation was in flight (RUN-1b, RUN-1c).
///
/// These are *recorded*, never acted on: nothing here retargets anything, and nothing here cancels
/// anything. Verification at execution time is what decides, and it decides by looking, not by
/// remembering. They are here so the inspector can say why a verification failed, and so a bar can
/// tell the user their window moved before they press Replace.
public enum DestinationChange: String, Sendable, Codable, CaseIterable {
    case applicationActivated
    case windowChanged
    case focusChanged
    case selectionChanged
    case secureInputBegan
    /// RUN-1c: focus went into a PappuClip surface the user opened on purpose — the bar's own text
    /// field, the inspector. That is not a new destination, and it is not `focusChanged`.
    case focusEnteredOwnSurface
    case focusLeftOwnSurface
}

/// What `cancel` achieved, in the words the UI needs (RUN-3e).
///
/// Nothing here promises rollback, and `mayHaveCompleted` is deliberately sticky: anything delegated,
/// anything that said so, and anything owned that did not stop inside the grace all set it.
public struct CancellationReport: Sendable, Equatable {
    public var invocation: InvocationID
    public var reason: InvocationInvalidation
    /// It was already finished or already invalidated, so cancellation had nothing to stop. Still a
    /// success: the state it wanted is the state it found.
    public var alreadyEnded: Bool
    public var stopped: Int
    public var asked: Int
    public var unstoppable: Int
    /// The external effect may already have happened, and PappuClip cannot say (RUN-3e).
    public var mayHaveCompleted: Bool
    /// Owned work did not stop within `InvocationTiming.cancellationGrace`, so we stopped waiting.
    public var graceExpired: Bool

    public init(
        invocation: InvocationID,
        reason: InvocationInvalidation,
        alreadyEnded: Bool = false,
        stopped: Int = 0,
        asked: Int = 0,
        unstoppable: Int = 0,
        mayHaveCompleted: Bool = false,
        graceExpired: Bool = false
    ) {
        self.invocation = invocation
        self.reason = reason
        self.alreadyEnded = alreadyEnded
        self.stopped = stopped
        self.asked = asked
        self.unstoppable = unstoppable
        self.mayHaveCompleted = mayHaveCompleted
        self.graceExpired = graceExpired
    }
}

/// One action run as the inspector will tell it (DIA-2), and on the same terms as `AttemptRecord`:
/// codes, identifiers, counts and durations, and no field the selection could be written into.
///
/// The snapshot's digest is *not* here. It is a hash, but a hash of a short answer is a lookup away
/// from the answer, and a diagnostics file is a thing people send to strangers.
public struct InvocationRecord: Sendable, Equatable {
    public var invocation: InvocationID
    public var attempt: AttemptID
    public var route: ActivationRoute
    public var action: String
    public var pid: pid_t?
    public var bundleID: String?
    /// How much text the action was given. Never what it said.
    public var characters: Int?
    public var strategy: SelectionStrategyKind?
    public var mayMutate: Bool
    /// Whether the key tap was actually held for this run. False for a run that may mutate means the
    /// grant is missing, and that the quiescence tier is out of reach (RUN-2g).
    public var watchedInput: Bool = false
    /// Every verification this run asked for, in order, as the tier each one reached. A run that
    /// verifies at execution and again at a Replace click has two (RUN-2e), and `.unverifiable` is a
    /// verification that happened and said no.
    public var verifications: [DestinationTier] = []
    /// The first failure of the last verification that failed.
    public var failure: DestinationFailure?
    public var denial: PrivacyDenialReason?
    public var fault: AXFault?
    public var changes: [DestinationChange] = []
    public var mutated = false
    public var invalidation: InvocationInvalidation?
    public var outcome: InvocationOutcome?
    public var cancellation: CancellationReport?
    public var elapsed: Duration = .zero

    public init(
        invocation: InvocationID,
        attempt: AttemptID,
        route: ActivationRoute,
        action: String,
        target: TargetApp,
        mayMutate: Bool
    ) {
        self.invocation = invocation
        self.attempt = attempt
        self.route = route
        self.action = action
        pid = target.pid
        bundleID = target.bundleID
        self.mayMutate = mayMutate
    }

    /// The best tier the run ever reached, or nil for a run that never asked.
    public var highestTier: DestinationTier? {
        verifications.max()
    }
}

/// The last few runs, in a fixed-size ring, for the same reason `AttemptTrace` is one.
public struct InvocationTrace: Sendable {
    public let capacity: Int
    private var records: [InvocationRecord] = []

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ record: InvocationRecord) {
        records.append(record)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }

    public mutating func update(_ invocation: InvocationID, _ change: (inout InvocationRecord) -> Void) {
        guard let index = records.lastIndex(where: { $0.invocation == invocation }) else { return }
        change(&records[index])
    }

    /// Oldest first.
    public var all: [InvocationRecord] { records }
    public var last: InvocationRecord? { records.last }

    public subscript(invocation: InvocationID) -> InvocationRecord? {
        records.last { $0.invocation == invocation }
    }
}
