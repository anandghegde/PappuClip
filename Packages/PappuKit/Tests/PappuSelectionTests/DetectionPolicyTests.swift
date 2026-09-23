import Foundation
import PappuCore
import PappuSelection
import PappuTestSupport
import Testing

/// The default of architecture §4.6, written out here so a change to the shipped file cannot quietly
/// change what these tests mean.
private let fallback = DetectionPolicy(
    strategies: [.ax, .webkitMarkers, .axEnable, .appleScript],
    autoAppear: true,
    autoSyntheticCopy: false,
    hotkeySyntheticCopy: true,
    quiescence: true
)

private func document(
    apps: [String: DetectionPolicyRecord] = [:],
    prefixes: [String: DetectionPolicyRecord] = [:],
    default policy: DetectionPolicy = fallback
) -> DetectionPolicies {
    DetectionPolicies(default: policy, apps: apps, prefixes: prefixes)
}

private let orderedKinds: [SelectionStrategyKind] = [.ax, .webkitMarkers, .axEnable, .appleScript]
private let enablings: [AXTreeEnabling?] = [nil, .manualAccessibility, .enhancedUserInterface, .both]
/// Overlapping, disjoint, empty and nested, so the intersection has something to do in every case.
private let deltas: [CopyDelta] = [.one, .oneOrTwo, .none, CopyDelta(minimum: 2, maximum: 3)]

private func samplePolicies(_ count: Int, seed: UInt64 = 0x5EED_1A11) -> [DetectionPolicy] {
    var rng = Seeded(state: seed)
    return (0..<count).map { _ in
        DetectionPolicy(
            strategies: orderedKinds.filter { _ in rng.bool() },
            autoAppear: rng.bool(),
            autoSyntheticCopy: rng.bool(),
            hotkeySyntheticCopy: rng.bool(),
            quiescence: rng.bool(),
            axEnable: rng.pick(enablings),
            copiesLineWhenEmpty: rng.bool(),
            expectedCopyDelta: rng.pick(deltas)
        )
    }
}

private func sampleRecords(_ count: Int, seed: UInt64 = 0xCE11_1465) -> [DetectionPolicyRecord] {
    var rng = Seeded(state: seed)
    func maybe<T>(_ value: @autoclosure () -> T) -> T? { rng.bool() ? value() : nil }
    return (0..<count).map { _ in
        DetectionPolicyRecord(
            strategies: maybe(orderedKinds.filter { _ in rng.bool() }),
            autoAppear: maybe(rng.bool()),
            autoSyntheticCopy: maybe(rng.bool()),
            hotkeySyntheticCopy: maybe(rng.bool()),
            quiescence: maybe(rng.bool()),
            axEnable: maybe(rng.pick(enablings)) ?? nil,
            copiesLineWhenEmpty: maybe(rng.bool()),
            expectedCopyDelta: maybe(rng.pick(deltas))
        )
    }
}

@Suite struct DetectionPolicyTests {

    // MARK: The chain (ACT-9, ACT-10j, ONB-6)

    @Test func anUnlistedAppTakesTheDefaultAndTheDefaultRefusesAutomaticSyntheticCopy() {
        let store = DetectionPolicyStore(document())
        let policy = store.policy(for: "com.example.NeverSeenBefore")
        #expect(policy == fallback)
        #expect(!policy.autoSyntheticCopy)
        #expect(!policy.chain(for: .automatic).contains(.syntheticCopy))
    }

    /// ACT-9's "apps with no policy use strategies 1–4 automatically and all five from the shortcut",
    /// less strategy 3, which has nothing to enable in an app the file does not name.
    @Test func anUnlistedAppTriesTheAXStrategiesAutomaticallyAndAddsSyntheticCopyOnTheShortcut() {
        let policy = document().policy(for: "com.example.NeverSeenBefore")
        #expect(policy.chain(for: .automatic) == [.ax, .webkitMarkers, .appleScript])
        for route in ActivationRoute.allCases where route.isDeliberate {
            #expect(policy.chain(for: route) == [.ax, .webkitMarkers, .appleScript, .syntheticCopy])
        }
    }

    @Test func strategyThreeIsDroppedWhenTheAppHasNoAttributeToEnableAndKeptWhenItHasOne() {
        let electron = DetectionPolicyRecord(axEnable: .manualAccessibility)
        let policy = document(apps: ["md.obsidian": electron]).policy(for: "md.obsidian")
        #expect(policy.chain(for: .automatic) == [.ax, .webkitMarkers, .axEnable, .appleScript])
        #expect(fallback.chain(for: .automatic).contains(.axEnable) == false)
    }

    @Test func aWholeLineCopyAppNeverGetsSyntheticCopyOnTheAutomaticPath() {
        // Even though the record asks for it: ACT-11a is a rule about the app, not a default.
        let vsCode = DetectionPolicyRecord(autoSyntheticCopy: true, copiesLineWhenEmpty: true)
        let policy = document(apps: ["com.microsoft.VSCode": vsCode]).policy(for: "com.microsoft.VSCode")
        #expect(policy.copiesLineWhenEmpty)
        #expect(!policy.autoSyntheticCopy)
        #expect(!policy.chain(for: .automatic).contains(.syntheticCopy))
    }

    @Test func popClipStopsSyntheticCopyOnTheAutomaticPathAndNowhereElse() {
        let permissive = DetectionPolicyRecord(autoSyntheticCopy: true)
        let policy = document(apps: ["com.apple.Safari": permissive]).policy(for: "com.apple.Safari")
        #expect(policy.chain(for: .automatic).contains(.syntheticCopy))
        #expect(!policy.chain(for: .automatic, popClipIsRunning: true).contains(.syntheticCopy))
        #expect(policy.chain(for: .hotkey, popClipIsRunning: true).contains(.syntheticCopy))
    }

    @Test func aDeliberateRouteMayUseSyntheticCopyWhereTheAutomaticPathMayNot() {
        #expect(!fallback.chain(for: .automatic).contains(.syntheticCopy))
        #expect(fallback.chain(for: .hotkey).contains(.syntheticCopy))
        #expect(fallback.chain(for: .script).contains(.syntheticCopy))
        #expect(fallback.chain(for: .urlScheme).contains(.syntheticCopy))
    }

    @Test func aPolicyThatWithholdsSyntheticCopyOnEveryRouteNeverOffersIt() {
        let policy = DetectionPolicy(
            strategies: [.ax],
            autoAppear: true,
            autoSyntheticCopy: false,
            hotkeySyntheticCopy: false,
            quiescence: false
        )
        for route in ActivationRoute.allCases {
            #expect(policy.chain(for: route) == [.ax])
        }
    }

    /// Strategy 5 is governed by the two flags, not by the order, so a file cannot smuggle it in.
    @Test func syntheticCopyIsNeverPartOfADeclaredStrategyOrder() {
        let policy = DetectionPolicy(
            strategies: [.ax, .syntheticCopy, .appleScript],
            autoAppear: true,
            autoSyntheticCopy: false,
            hotkeySyntheticCopy: false,
            quiescence: true
        )
        #expect(policy.strategies == [.ax, .appleScript])
        #expect(policy.chain(for: .automatic) == [.ax, .appleScript])
    }

    // MARK: The restrictive merge (SEC-9, RUN-2h)

    @Test func aMergeIsNeverLooserThanEitherSide() {
        let policies = samplePolicies(64)
        for left in policies {
            for right in policies {
                let merged = left.restricted(by: right)
                #expect(merged.isAtLeastAsRestrictive(as: left))
                #expect(merged.isAtLeastAsRestrictive(as: right))
            }
        }
    }

    @Test func aMergeWithItselfChangesNothing() {
        for policy in samplePolicies(64) {
            #expect(policy.restricted(by: policy) == policy)
        }
    }

    @Test func aMergeAllowsTheSameThingsWhicheverWayRound() {
        let policies = samplePolicies(48, seed: 0xD00D)
        for left in policies {
            for right in policies {
                let forwards = left.restricted(by: right)
                let backwards = right.restricted(by: left)
                #expect(Set(forwards.strategies) == Set(backwards.strategies))
                #expect(forwards.autoAppear == backwards.autoAppear)
                #expect(forwards.autoSyntheticCopy == backwards.autoSyntheticCopy)
                #expect(forwards.hotkeySyntheticCopy == backwards.hotkeySyntheticCopy)
                #expect(forwards.quiescence == backwards.quiescence)
                #expect(forwards.axEnable == backwards.axEnable)
                #expect(forwards.copiesLineWhenEmpty == backwards.copiesLineWhenEmpty)
            }
        }
    }

    /// The merge keeps the left side's order, because that side is the one that knows the app.
    @Test func aMergeKeepsTheOrderOfThePolicyItRestricts() {
        let ordered = DetectionPolicy(
            strategies: [.appleScript, .ax, .webkitMarkers],
            autoAppear: true, autoSyntheticCopy: false, hotkeySyntheticCopy: true, quiescence: true
        )
        let other = DetectionPolicy(
            strategies: [.ax, .webkitMarkers, .appleScript],
            autoAppear: true, autoSyntheticCopy: false, hotkeySyntheticCopy: true, quiescence: true
        )
        #expect(ordered.restricted(by: other).strategies == [.appleScript, .ax, .webkitMarkers])
    }

    /// A warning about the app, not a permission: either side raising it wins.
    @Test func theWholeLineCopyFlagSpreadsThroughAMergeInsteadOfBeingDroppedByIt() {
        let flagged = DetectionPolicy(
            strategies: [.ax], autoAppear: true, autoSyntheticCopy: true,
            hotkeySyntheticCopy: true, quiescence: true, copiesLineWhenEmpty: true
        )
        let plain = DetectionPolicy(
            strategies: [.ax], autoAppear: true, autoSyntheticCopy: true,
            hotkeySyntheticCopy: true, quiescence: true
        )
        #expect(plain.restricted(by: flagged).copiesLineWhenEmpty)
        #expect(!plain.restricted(by: flagged).autoSyntheticCopy)
    }

    // MARK: Ceilings (SEC-9, RUN-2h)

    @Test func aCeilingCanNeverGrant() {
        let document = document()
        let bundled = document.policy(for: "com.apple.Safari")
        for record in sampleRecords(96) {
            let global = DetectionPolicyStore(document, ceilings: DetectionCeilings(global: record))
            let perApp = DetectionPolicyStore(
                document,
                ceilings: DetectionCeilings(apps: ["com.apple.Safari": record])
            )
            #expect(global.policy(for: "com.apple.Safari").isAtLeastAsRestrictive(as: bundled))
            #expect(perApp.policy(for: "com.apple.Safari").isAtLeastAsRestrictive(as: bundled))
        }
    }

    @Test func aCeilingThatAsksForMoreThanTheBundledPolicyAllowsChangesNothing() {
        let greedy = DetectionPolicyRecord(
            strategies: orderedKinds,
            autoAppear: true,
            autoSyntheticCopy: true,
            hotkeySyntheticCopy: true,
            quiescence: true
        )
        let store = DetectionPolicyStore(document(), ceilings: DetectionCeilings(global: greedy))
        #expect(store.policy(for: "com.apple.Safari") == fallback)
        #expect(!store.policy(for: "com.apple.Safari").autoSyntheticCopy)
    }

    @Test func aUserCeilingTurnsOffQuiescenceThatTheBundledPolicyAllows() {
        let store = DetectionPolicyStore(
            document(),
            ceilings: DetectionCeilings(global: DetectionPolicyRecord(quiescence: false))
        )
        #expect(fallback.quiescence)
        #expect(!store.policy(for: "com.apple.Safari").quiescence)
    }

    @Test func aPerAppCeilingAppliesOnTopOfTheGlobalOne() {
        let store = DetectionPolicyStore(
            document(apps: ["com.apple.Safari": DetectionPolicyRecord(autoSyntheticCopy: true)]),
            ceilings: DetectionCeilings(
                global: DetectionPolicyRecord(quiescence: false),
                apps: ["com.apple.Safari": DetectionPolicyRecord(autoSyntheticCopy: false)]
            )
        )
        let safari = store.policy(for: "com.apple.Safari")
        #expect(!safari.quiescence)
        #expect(!safari.autoSyntheticCopy)
        // Another app keeps what only Safari's entry took away.
        #expect(store.policy(for: "com.apple.Notes").quiescence == false)
        #expect(store.policy(for: "com.apple.Notes").hotkeySyntheticCopy)
    }

    @Test func ceilingsAreReadAtEachLookupSoASettingChangeAppliesToTheNextAttempt() {
        let ceilings = Mutable(DetectionCeilings.none)
        let store = DetectionPolicyStore(policies: { document() }, ceilings: { ceilings.value })
        #expect(store.policy(for: "com.apple.Safari").hotkeySyntheticCopy)
        ceilings.value = DetectionCeilings(global: DetectionPolicyRecord(hotkeySyntheticCopy: false))
        #expect(!store.policy(for: "com.apple.Safari").hotkeySyntheticCopy)
    }

    // MARK: Lookup

    @Test func aSparseRecordOverridesOnlyWhatItNames() {
        let record = DetectionPolicyRecord(autoAppear: false)
        let policy = document(apps: ["com.jetbrains.intellij": record]).policy(for: "com.jetbrains.intellij")
        #expect(!policy.autoAppear)
        #expect(policy.strategies == fallback.strategies)
        #expect(policy.quiescence == fallback.quiescence)
        #expect(policy.hotkeySyntheticCopy == fallback.hotkeySyntheticCopy)
    }

    @Test func anExactEntryBeatsAPrefixAndTheLongestPrefixWins() {
        let document = document(
            apps: ["com.jetbrains.intellij": DetectionPolicyRecord(autoAppear: false)],
            prefixes: [
                "com.": DetectionPolicyRecord(quiescence: false),
                "com.jetbrains.": DetectionPolicyRecord(copiesLineWhenEmpty: true),
            ]
        )
        // Exact: the prefixes have nothing to say.
        let intelliJ = document.policy(for: "com.jetbrains.intellij")
        #expect(!intelliJ.autoAppear)
        #expect(!intelliJ.copiesLineWhenEmpty)
        #expect(intelliJ.quiescence)
        // Longest prefix: the JetBrains family, not the `com.` one.
        let goLand = document.policy(for: "com.jetbrains.goland")
        #expect(goLand.copiesLineWhenEmpty)
        #expect(goLand.quiescence)
        // Shorter prefix where nothing longer matches.
        #expect(!document.policy(for: "com.apple.Safari").quiescence)
    }

    @Test func aProcessWithNoBundleIdentifierTakesTheDefault() {
        let document = document(
            apps: ["com.apple.Safari": DetectionPolicyRecord(autoAppear: false)],
            prefixes: ["": DetectionPolicyRecord(autoAppear: false)]
        )
        #expect(document.record(for: nil) == nil)
        #expect(document.policy(for: nil) == fallback)
        #expect(DetectionPolicyStore(document).policy(for: TargetApp(pid: 99, bundleID: nil)) == fallback)
    }

    @Test func aTargetIsLookedUpByItsBundleIdentifier() {
        let store = DetectionPolicyStore(
            document(apps: ["com.apple.Safari": DetectionPolicyRecord(autoAppear: false)])
        )
        #expect(!store.policy(for: TargetApp(pid: 501, bundleID: "com.apple.Safari")).autoAppear)
        #expect(store.policy(for: TargetApp(pid: 502, bundleID: "com.apple.Notes")).autoAppear)
    }

    // MARK: The document

    @Test func aDocumentRoundTripsThroughJSON() throws {
        let original = document(
            apps: ["com.microsoft.VSCode": DetectionPolicyRecord(axEnable: .manualAccessibility, copiesLineWhenEmpty: true)],
            prefixes: ["com.jetbrains.": DetectionPolicyRecord(copiesLineWhenEmpty: true)]
        )
        let decoded = try DetectionPolicies.decode(JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func aDocumentFromAFutureSchemaIsRefusedRatherThanReadWithTheFieldsWeKnow() throws {
        var ahead = document()
        ahead.schema = DetectionPolicies.supportedSchema + 1
        let data = try JSONEncoder().encode(ahead)
        #expect(throws: DetectionPolicies.UnsupportedSchema.self) { try DetectionPolicies.decode(data) }
    }

    @Test func aDocumentNeedsOnlyASchemaASequenceAndADefault() throws {
        let json = Data("""
        {"schema":1,"sequence":7,"default":{"strategies":["ax"],"autoAppear":true,
         "autoSyntheticCopy":false,"hotkeySyntheticCopy":true,"quiescence":true}}
        """.utf8)
        let decoded = try DetectionPolicies.decode(json)
        #expect(decoded.sequence == 7)
        #expect(decoded.apps.isEmpty)
        #expect(decoded.prefixes.isEmpty)
        #expect(decoded.policy(for: "com.apple.Safari").strategies == [.ax])
    }

    /// The initialiser's normalisation is not something a file can route around.
    @Test func decodingNormalisesTheSameWayTheInitialiserDoes() throws {
        let json = Data("""
        {"schema":1,"sequence":1,"default":{"strategies":["ax","syntheticCopy"],"autoAppear":true,
         "autoSyntheticCopy":true,"hotkeySyntheticCopy":true,"quiescence":true,
         "copiesLineWhenEmpty":true}}
        """.utf8)
        let policy = try DetectionPolicies.decode(json).default
        #expect(policy.strategies == [.ax])
        #expect(!policy.autoSyntheticCopy)
    }

    @Test func aStrategyKnowsItsNumberAndWhichBudgetItIsMeasuredAgainst() {
        #expect(SelectionStrategyKind.allCases.map(\.number) == [1, 2, 3, 4, 5])
        #expect(SelectionStrategyKind.allCases.filter { $0.path == .accessibility } == [.ax, .webkitMarkers, .axEnable])
        #expect(SelectionStrategyKind.allCases.filter { $0.path == .clipboardFallback } == [.appleScript, .syntheticCopy])
    }
}

/// A box, so a test can change what the store's closure returns between two lookups.
private final class Mutable<Value: Sendable>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Suite struct DetectionPolicyNormalisationTests {
    @Test func aStrategyListedTwiceRunsOnce() {
        let policy = DetectionPolicy(
            strategies: [.ax, .webkitMarkers, .ax, .appleScript, .webkitMarkers],
            autoAppear: true, autoSyntheticCopy: false, hotkeySyntheticCopy: false, quiescence: true
        )
        #expect(policy.strategies == [.ax, .webkitMarkers, .appleScript])
    }
}
