import Foundation
import PappuCore

/// Which other clipboard apps are on the Mac right now (ONB-6, ACT-10i).
///
/// Two booleans, filled in by `CoexistenceMonitor` from the running-application list through
/// `init(running:)`. They are separate questions: PopClip decides whether strategy 5 runs at all on the automatic
/// path, because two apps racing to simulate ⌘C is the one coexistence failure that loses the user's
/// clipboard; a clipboard manager decides only how long the settle is, because a manager reads and
/// sometimes rewrites after every copy and a quiet pasteboard therefore says less.
public struct Coexistence: Sendable, Equatable, Codable {
    public var popClipIsRunning: Bool
    public var clipboardManagerIsRunning: Bool

    public init(popClipIsRunning: Bool = false, clipboardManagerIsRunning: Bool = false) {
        self.popClipIsRunning = popClipIsRunning
        self.clipboardManagerIsRunning = clipboardManagerIsRunning
    }

    public static let none = Coexistence()

    /// PopClip's bundle identifier (ONB-6). *Unverified*, as the PRD marks it: confirm against an
    /// installed copy before M3's explanation screen names it to the user.
    public static let popClipBundleIDs: Set<String> = ["com.pilotmoon.popclip"]

    /// Apps that watch the general pasteboard and may read or rewrite it after every copy (ACT-10i).
    ///
    /// Launchers with an optional clipboard history — Alfred, Raycast — are on it although theirs may be
    /// turned off. Being on the list only lengthens the settle, which costs a few milliseconds when it is
    /// wrong; being missing from it shortens the settle when a manager *is* reading, which is the
    /// direction that misattributes a copy. *Unverified* identifiers, like PopClip's: the ACT-10i pass
    /// (`docs/checklists/clipboard-managers.md`) records each one it confirms.
    public static let clipboardManagerBundleIDs: Set<String> = [
        "org.p0deje.Maccy",
        "com.wiheads.paste",
        "com.wiheads.paste-setapp",
        "com.tapbots.Pastebot2Mac",
        "com.clipy-app.Clipy",
        "com.generalarcade.flycut",
        "com.fiplab.copyclip2",
        "com.runningwithcrayons.Alfred",
        "com.raycast.macos",
    ]

    /// What the set of running apps says, by bundle identifier.
    public init(running: Set<String>) {
        self.init(
            popClipIsRunning: !running.isDisjoint(with: Self.popClipBundleIDs),
            clipboardManagerIsRunning: !running.isDisjoint(with: Self.clipboardManagerBundleIDs)
        )
    }
}

/// Proof that ACT-10j was decided before a ⌘C was simulated (architecture §3.1, §5).
///
/// `ClipboardBroker.read` takes one and there is no other way in, and `init` is internal to this module
/// so `DetectionPolicyStore.syntheticCopyPermit` is the only thing that can make one. A code path that
/// simulates ⌘C in an app whose policy does not allow it on this route therefore does not compile,
/// which is a stronger statement than "the coordinator checks the policy first".
///
/// `~Copyable`, and consumed by the read: a permit names one attempt, and an attempt gets one ⌘C.
public struct SyntheticCopyPermit: ~Copyable, Sendable {
    public let attempt: AttemptID
    public let route: ActivationRoute
    public let target: TargetApp
    /// How far this app's ⌘C may move the change count (ACT-10e). Never empty: an empty range is how
    /// the policy says no, and then there is no permit.
    public let expectedDelta: CopyDelta
    /// Lengthens the settle. Carried on the permit rather than read later so that the whole transaction
    /// is decided from one reading of the world.
    public let clipboardManagerIsRunning: Bool

    init(
        attempt: AttemptID,
        route: ActivationRoute,
        target: TargetApp,
        expectedDelta: CopyDelta,
        clipboardManagerIsRunning: Bool
    ) {
        self.attempt = attempt
        self.route = route
        self.target = target
        self.expectedDelta = expectedDelta
        self.clipboardManagerIsRunning = clipboardManagerIsRunning
    }
}

extension DetectionPolicyStore {
    /// The one place a `SyntheticCopyPermit` comes from (ACT-10j, ACT-11a, ONB-6).
    ///
    /// - Returns: Nil when strategy 5 is not in this app's chain for this route — an unlisted app on the
    ///   automatic path, an app that copies the whole line when nothing is selected, PopClip running, a
    ///   user ceiling, or an empty `expectedCopyDelta`. Nil is not a failure and has no trace of its
    ///   own: `DetectionPolicy.chain(for:)` already left strategy 5 out, so the chain and the permit are
    ///   two readings of one decision and cannot disagree.
    public func syntheticCopyPermit(
        attempt: AttemptID,
        route: ActivationRoute,
        target: TargetApp,
        coexistence: Coexistence = .none
    ) -> SyntheticCopyPermit? {
        let policy = policy(for: target)
        let chain = policy.chain(for: route, popClipIsRunning: coexistence.popClipIsRunning)
        guard chain.contains(.syntheticCopy) else { return nil }
        return SyntheticCopyPermit(
            attempt: attempt,
            route: route,
            target: target,
            expectedDelta: policy.expectedCopyDelta,
            clipboardManagerIsRunning: coexistence.clipboardManagerIsRunning
        )
    }
}
