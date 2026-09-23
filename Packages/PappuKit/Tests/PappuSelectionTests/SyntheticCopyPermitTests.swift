import Foundation
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

private let target = TargetApp(pid: 501, bundleID: "com.example.editor")
private let attempt = AttemptID(rawValue: 7)

/// Allows strategy 5 on every route, so a test that takes it away is taking away one thing.
private let permissive = DetectionPolicy(
    strategies: [.ax],
    autoAppear: true,
    autoSyntheticCopy: true,
    hotkeySyntheticCopy: true,
    quiescence: true
)

private func store(
    _ policy: DetectionPolicy = permissive,
    ceilings: DetectionCeilings = .none
) -> DetectionPolicyStore {
    DetectionPolicyStore(DetectionPolicies(default: policy), ceilings: ceilings)
}

/// The permit's own delta, or nil when there was no permit — everything a test can learn about a value
/// it is not allowed to keep. `#expect(permit != nil)` cannot be written about a non-copyable value,
/// and that is the point of one: there is nowhere to put it but the read that consumes it.
private func grantedDelta(_ permit: consuming SyntheticCopyPermit?) -> CopyDelta? {
    guard let granted = consume permit else { return nil }
    return granted.expectedDelta
}

private func isGranted(_ permit: consuming SyntheticCopyPermit?) -> Bool {
    grantedDelta(consume permit) != nil
}

/// ACT-10j. `DetectionPolicyStore.syntheticCopyPermit` is the only thing on the Mac that can make a
/// `SyntheticCopyPermit`, and `ClipboardBroker.read` cannot be called without one, so every one of
/// these refusals is a simulated ⌘C that does not compile rather than one somebody remembered to skip.
@Suite struct SyntheticCopyPermitTests {
    @Test func theShippedDefaultRefusesTheAutomaticPathAndAllowsTheShortcut() {
        let unlisted = store(DetectionPolicy(
            strategies: [.ax, .webkitMarkers],
            autoAppear: true,
            autoSyntheticCopy: false,
            hotkeySyntheticCopy: true,
            quiescence: true
        ))

        let automatic = isGranted(unlisted.syntheticCopyPermit(attempt: attempt, route: .automatic, target: target))
        let shortcut = isGranted(unlisted.syntheticCopyPermit(attempt: attempt, route: .hotkey, target: target))

        #expect(!automatic)
        #expect(shortcut)
    }

    /// The shortcut, AppleScript and the URL scheme are one case: the user asked by name, so a moment's
    /// use of their clipboard is something they set off (safety spec §S1).
    @Test(arguments: ActivationRoute.allCases)
    func everyDeliberateRouteMayHaveOneAndTheAutomaticPathMayNot(route: ActivationRoute) {
        let deliberateOnly = store(DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: false,
            hotkeySyntheticCopy: true,
            quiescence: true
        ))

        let granted = isGranted(deliberateOnly.syntheticCopyPermit(attempt: attempt, route: route, target: target))
        #expect(granted == route.isDeliberate)
    }

    /// One reading of the world, carried on the permit, so the broker cannot decide the settle from a
    /// different answer than the one the policy was read against (ACT-10d).
    @Test func thePermitSaysWhichAttemptAndAppAndWorldItIsFor() {
        let world = Coexistence(popClipIsRunning: false, clipboardManagerIsRunning: true)
        guard let permit = store(DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: true,
            hotkeySyntheticCopy: true,
            quiescence: true,
            expectedCopyDelta: .oneOrTwo
        )).syntheticCopyPermit(attempt: attempt, route: .hotkey, target: target, coexistence: world) else {
            Issue.record("this policy allows strategy 5 on the shortcut")
            return
        }

        let (named, route, app) = (permit.attempt, permit.route, permit.target)
        let (delta, manager) = (permit.expectedDelta, permit.clipboardManagerIsRunning)

        #expect(named == attempt)
        #expect(route == .hotkey)
        #expect(app == target)
        #expect(delta == .oneOrTwo)
        #expect(manager)
    }

    /// An empty delta is how a policy says "never here" in one field instead of two, and it says it on
    /// every route: no count change would be attributable, so there is nothing a ⌘C could tell us.
    @Test(arguments: ActivationRoute.allCases)
    func noPermitWhereThereIsNoDeltaToExpect(route: ActivationRoute) {
        let mute = store(DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: true,
            hotkeySyntheticCopy: true,
            quiescence: true,
            expectedCopyDelta: .none
        ))

        let granted = isGranted(mute.syntheticCopyPermit(attempt: attempt, route: route, target: target))

        #expect(!granted)
    }

    /// ONB-6. Two apps simulating ⌘C at once is the one coexistence failure that loses the user's
    /// clipboard, and it can only happen where neither of them was asked.
    @Test func popClipTakesThePermitFromTheAutomaticPathAndNowhereElse() {
        let running = Coexistence(popClipIsRunning: true)

        let automatic = isGranted(store().syntheticCopyPermit(
            attempt: attempt, route: .automatic, target: target, coexistence: running))
        let shortcut = isGranted(store().syntheticCopyPermit(
            attempt: attempt, route: .hotkey, target: target, coexistence: running))

        #expect(!automatic)
        #expect(shortcut)
    }

    /// SEC-9, RUN-2h. A ceiling is spent on the policy it restricts, so it can take the permit away in
    /// either of the two fields that grant it, and cannot hand one out in either.
    @Test func aUserCeilingCanOnlyTakeThePermitAway() {
        let byFlag = store(ceilings: DetectionCeilings(
            global: DetectionPolicyRecord(hotkeySyntheticCopy: false)))
        let withoutTheFlag = isGranted(byFlag.syntheticCopyPermit(attempt: attempt, route: .hotkey, target: target))
        #expect(!withoutTheFlag)

        let byDelta = store(ceilings: DetectionCeilings(
            apps: ["com.example.editor": DetectionPolicyRecord(expectedCopyDelta: CopyDelta.none)]))
        let withoutADelta = isGranted(byDelta.syntheticCopyPermit(attempt: attempt, route: .hotkey, target: target))
        #expect(!withoutADelta)

        // And the other direction, which is the one that matters: a ceiling asking for more than the
        // policy allows changes nothing at all.
        let asksForMore = store(
            DetectionPolicy(
                strategies: [.ax],
                autoAppear: true,
                autoSyntheticCopy: false,
                hotkeySyntheticCopy: true,
                quiescence: true
            ),
            ceilings: DetectionCeilings(global: DetectionPolicyRecord(
                autoSyntheticCopy: true, expectedCopyDelta: CopyDelta(minimum: 0, maximum: 9)))
        )
        let stillRefused = isGranted(asksForMore.syntheticCopyPermit(
            attempt: attempt, route: .automatic, target: target))
        let stillOne = grantedDelta(asksForMore.syntheticCopyPermit(
            attempt: attempt, route: .hotkey, target: target))

        #expect(!stillRefused)
        #expect(stillOne == .one)
    }

    /// The property the two readings of ACT-10j rest on: `chain(for:)` decides whether strategy 5 runs
    /// and `syntheticCopyPermit` decides whether it may, and they cannot disagree — over every policy
    /// shape, route and coexistence below. A permit also never carries an empty delta, so the broker
    /// has no case to handle for one.
    @Test func theChainAndThePermitAreTwoReadingsOfOneDecision() {
        var rng = Seeded(state: 0x9E11_1770)
        let deltas: [CopyDelta] = [.one, .oneOrTwo, .none, CopyDelta(minimum: 2, maximum: 3)]

        for _ in 0..<60 {
            let policy = DetectionPolicy(
                strategies: [.ax],
                autoAppear: rng.bool(),
                autoSyntheticCopy: rng.bool(),
                hotkeySyntheticCopy: rng.bool(),
                quiescence: rng.bool(),
                copiesLineWhenEmpty: rng.bool(),
                expectedCopyDelta: rng.pick(deltas)
            )
            let world = Coexistence(
                popClipIsRunning: rng.bool(),
                clipboardManagerIsRunning: rng.bool()
            )

            for route in ActivationRoute.allCases {
                let chain = policy.chain(for: route, popClipIsRunning: world.popClipIsRunning)
                let delta = grantedDelta(store(policy).syntheticCopyPermit(
                    attempt: attempt, route: route, target: target, coexistence: world))
                let why = "\(policy) on \(route) with \(world)"

                #expect((delta != nil) == chain.contains(.syntheticCopy), "\(why)")
                if let delta {
                    #expect(delta == policy.expectedCopyDelta, "\(why)")
                    #expect(!delta.isEmpty, "\(why)")
                }
            }
        }
    }
}
