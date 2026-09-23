import Foundation
import PappuCore

/// What PappuClip may do to read a selection in one app (ACT-11a, architecture §4.6).
///
/// Immutable, and the memberwise `init` is the only way in — the `Codable` conformance goes through
/// it too — because one pair of fields is not free to combine: an app that copies the whole line when
/// nothing is selected never gets synthetic copy on the automatic path, whatever the file says
/// (ACT-11a, ACT-10j). Normalising once, on the way in, is what stops a caller reading
/// `autoSyntheticCopy` and getting an answer `chain(for:)` would not have given.
///
/// `autoAppear` is the *app's* say — an app where auto-appear is hopeless or harmful. It is not the
/// user's appearance exclusion, which is `AppActivationMode` and belongs to the `PrivacyGate`. The
/// coordinator needs both to pass.
public struct DetectionPolicy: Sendable, Equatable, Codable {
    /// The chain to try, in order, stopping at the first success. Strategy 5 is never in this list.
    public let strategies: [SelectionStrategyKind]
    /// Whether the bar may appear here without being asked for.
    public let autoAppear: Bool
    /// Whether strategy 5 may run on the automatic path (ACT-10j). False for every unlisted app.
    public let autoSyntheticCopy: Bool
    /// Whether strategy 5 may run on a deliberate route — shortcut, script, URL scheme.
    public let hotkeySyntheticCopy: Bool
    /// Whether the quiescence verification tier may be used here (RUN-2h).
    public let quiescence: Bool
    /// The attribute strategy 3 sets, if this app has one. Without it strategy 3 is strategy 1 run
    /// twice, so `chain(for:)` leaves it out.
    public let axEnable: AXTreeEnabling?
    /// ⌘C with an empty selection copies the whole line here: VS Code, Sublime Text, the JetBrains
    /// IDEs (ACT-11a). A quirk, not a permission — see `restricted(by:)`.
    public let copiesLineWhenEmpty: Bool
    /// How far one ⌘C may move the pasteboard's change count here (ACT-10e). An empty range is how a
    /// policy or a user ceiling says "never simulate ⌘C in this app" in one field instead of two.
    ///
    /// It belongs in the policy and the transaction's durations do not, because intersection is
    /// monotone: two ranges can only narrow each other, which is what `restricted(by:)` needs. See
    /// `ClipboardTiming` for the numbers that are not.
    public let expectedCopyDelta: CopyDelta

    public init(
        strategies: [SelectionStrategyKind],
        autoAppear: Bool,
        autoSyntheticCopy: Bool,
        hotkeySyntheticCopy: Bool,
        quiescence: Bool,
        axEnable: AXTreeEnabling? = nil,
        copiesLineWhenEmpty: Bool = false,
        expectedCopyDelta: CopyDelta = .one
    ) {
        // Strategy 5 is not an order, and a strategy listed twice would run twice.
        var seen: Set<SelectionStrategyKind> = [.syntheticCopy]
        self.strategies = strategies.filter { seen.insert($0).inserted }
        self.autoAppear = autoAppear
        self.autoSyntheticCopy = autoSyntheticCopy && !copiesLineWhenEmpty
        self.hotkeySyntheticCopy = hotkeySyntheticCopy
        self.quiescence = quiescence
        self.axEnable = axEnable
        self.copiesLineWhenEmpty = copiesLineWhenEmpty
        self.expectedCopyDelta = expectedCopyDelta
    }

    /// The strategies to try for one attempt, in order (ACT-9, ACT-10j, ONB-6).
    ///
    /// A deliberate route may use strategy 5 where the automatic path may not: the user has just
    /// asked, so a moment's use of their clipboard is something they set off. PopClip stops only the
    /// automatic path, because that is where the two apps' fallbacks would race (ONB-6).
    public func chain(
        for route: ActivationRoute,
        popClipIsRunning: Bool = false
    ) -> [SelectionStrategyKind] {
        let usable = strategies.filter { $0 != .axEnable || axEnable != nil }
        // An empty delta means no change the count could make would be attributable, so there is nothing
        // a simulated ⌘C could tell us and every one of them would end `ambiguous`.
        let syntheticCopy = !expectedCopyDelta.isEmpty && (route.isDeliberate
            ? hotkeySyntheticCopy
            : autoSyntheticCopy && !popClipIsRunning)
        return syntheticCopy ? usable + [.syntheticCopy] : usable
    }

    /// The more restrictive of two policies, field by field (architecture §4.6, SEC-9, RUN-2h).
    ///
    /// The user's ceilings go through here, and from M5 so does a signed remote document (ACT-11b).
    /// That a merge can only ever take something away is the property that makes a remote policy safe
    /// to ship without re-reviewing every field: there is no value either side can carry that turns
    /// something on.
    ///
    /// `copiesLineWhenEmpty` merges the other way round, and deliberately: it is a warning about the
    /// app, not a permission, so either side raising it wins.
    public func restricted(by other: DetectionPolicy) -> DetectionPolicy {
        DetectionPolicy(
            strategies: strategies.filter(other.strategies.contains),
            autoAppear: autoAppear && other.autoAppear,
            autoSyntheticCopy: autoSyntheticCopy && other.autoSyntheticCopy,
            hotkeySyntheticCopy: hotkeySyntheticCopy && other.hotkeySyntheticCopy,
            quiescence: quiescence && other.quiescence,
            axEnable: axEnable == other.axEnable ? axEnable : nil,
            copiesLineWhenEmpty: copiesLineWhenEmpty || other.copiesLineWhenEmpty,
            expectedCopyDelta: expectedCopyDelta.intersected(with: other.expectedCopyDelta)
        )
    }

    /// True when nothing is allowed here that `other` does not also allow.
    ///
    /// `restricted(by:)`'s test asserts this against both of its inputs, over every combination of
    /// fields. It is the whole of SEC-9's claim about policy data, written as one function.
    public func isAtLeastAsRestrictive(as other: DetectionPolicy) -> Bool {
        Set(strategies).isSubset(of: Set(other.strategies))
            && (!autoAppear || other.autoAppear)
            && (!autoSyntheticCopy || other.autoSyntheticCopy)
            && (!hotkeySyntheticCopy || other.hotkeySyntheticCopy)
            && (!quiescence || other.quiescence)
            && (axEnable == nil || axEnable == other.axEnable)
            && (copiesLineWhenEmpty || !other.copiesLineWhenEmpty)
            && expectedCopyDelta.isAtLeastAsRestrictive(as: other.expectedCopyDelta)
    }

    // Decoding routes through `init` so that a file cannot spell a combination the memberwise
    // initialiser would have normalised away.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            strategies: try container.decode([SelectionStrategyKind].self, forKey: .strategies),
            autoAppear: try container.decode(Bool.self, forKey: .autoAppear),
            autoSyntheticCopy: try container.decode(Bool.self, forKey: .autoSyntheticCopy),
            hotkeySyntheticCopy: try container.decode(Bool.self, forKey: .hotkeySyntheticCopy),
            quiescence: try container.decode(Bool.self, forKey: .quiescence),
            axEnable: try container.decodeIfPresent(AXTreeEnabling.self, forKey: .axEnable),
            copiesLineWhenEmpty: try container.decodeIfPresent(Bool.self, forKey: .copiesLineWhenEmpty) ?? false,
            expectedCopyDelta: try container.decodeIfPresent(CopyDelta.self, forKey: .expectedCopyDelta) ?? .one
        )
    }
}

/// One app's entry in `DetectionPolicies.json`, and the shape a user's ceiling takes.
///
/// Every field is optional, and `nil` means "say nothing". Applied to a policy it overrides field by
/// field; that is right for bundled data, which is trusted and has to be able to say that Safari can
/// do something the default cannot. What makes a *user* ceiling unable to grant is not this type but
/// how `DetectionPolicyStore` spends it — see `DetectionCeilings`.
public struct DetectionPolicyRecord: Sendable, Equatable, Codable {
    public var strategies: [SelectionStrategyKind]?
    public var autoAppear: Bool?
    public var autoSyntheticCopy: Bool?
    public var hotkeySyntheticCopy: Bool?
    public var quiescence: Bool?
    /// There is no way for a record to *clear* an inherited kind, and nothing needs one: the kind is
    /// per app by definition, so the default never carries one to inherit.
    public var axEnable: AXTreeEnabling?
    public var copiesLineWhenEmpty: Bool?
    public var expectedCopyDelta: CopyDelta?

    public init(
        strategies: [SelectionStrategyKind]? = nil,
        autoAppear: Bool? = nil,
        autoSyntheticCopy: Bool? = nil,
        hotkeySyntheticCopy: Bool? = nil,
        quiescence: Bool? = nil,
        axEnable: AXTreeEnabling? = nil,
        copiesLineWhenEmpty: Bool? = nil,
        expectedCopyDelta: CopyDelta? = nil
    ) {
        self.strategies = strategies
        self.autoAppear = autoAppear
        self.autoSyntheticCopy = autoSyntheticCopy
        self.hotkeySyntheticCopy = hotkeySyntheticCopy
        self.quiescence = quiescence
        self.axEnable = axEnable
        self.copiesLineWhenEmpty = copiesLineWhenEmpty
        self.expectedCopyDelta = expectedCopyDelta
    }

    public var isEmpty: Bool { self == DetectionPolicyRecord() }

    public func applied(to base: DetectionPolicy) -> DetectionPolicy {
        DetectionPolicy(
            strategies: strategies ?? base.strategies,
            autoAppear: autoAppear ?? base.autoAppear,
            autoSyntheticCopy: autoSyntheticCopy ?? base.autoSyntheticCopy,
            hotkeySyntheticCopy: hotkeySyntheticCopy ?? base.hotkeySyntheticCopy,
            quiescence: quiescence ?? base.quiescence,
            axEnable: axEnable ?? base.axEnable,
            copiesLineWhenEmpty: copiesLineWhenEmpty ?? base.copiesLineWhenEmpty,
            expectedCopyDelta: expectedCopyDelta ?? base.expectedCopyDelta
        )
    }
}
