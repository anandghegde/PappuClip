import Foundation

/// §8.5's pipeline: does this action show for this selection, and on what does it act (FLT-5).
///
/// A pure function of `(ActionManifest, MatchingFacts, option values)`, deliberately: it is the one
/// decision a user notices every single time — a bar with a button that should not be there, or
/// without one that should — and the only way to be sure about it is to be able to run it a thousand
/// times over a table with no window server in sight.
///
/// **The steps this build runs.** §8.5 has five; `ActionMatching` runs 1, 2, 3 and 5:
///
/// 1. App filters (`requiredApps`, `excludedApps`).
/// 2. `requirements`, each satisfiable or negated.
/// 3. Narrowing: a satisfied `url`, `isurl`, `email` or `path` makes the action act on that one
///    detection rather than on the whole selection.
/// 5. The full text stays available whatever step 3 narrowed to.
///
/// Step 4 — `regex`, matched against what step 3 left — is M2, with the manifest parser that reads the
/// key. It is absent rather than half-present: an action carrying a `regex` this build silently
/// ignored would be shown in places its author excluded, which is the failure mode §8.5's ordering
/// exists to prevent. `ManifestBuilder` refuses such a manifest in M2 until the step is written.
public enum ActionMatching {
    /// A shown action, and what it acts on (§8.5 steps 3 and 5).
    public struct Match: Sendable, Equatable {
        /// Which requirement did the narrowing, or nil when the action acts on the selection.
        public var narrowing: NarrowingKind?
        /// Where `value` sits in the full text. Nil when nothing narrowed.
        public var span: TextSpan?
        /// What the action acts on: the narrowed detection's normalised value, or the full selection.
        public var value: String
        /// The whole selection, always (§8.5 step 5).
        public var fullText: String

        public var isNarrowed: Bool { narrowing != nil }
    }

    /// Why an action is not on the bar. Carried rather than collapsed to `false` because DIA-2's
    /// inspector answers exactly this question, and "Cut is missing" and "Cut is missing *because the
    /// field is read-only*" are different answers to a user who expected it.
    public enum Refusal: Sendable, Equatable {
        /// The action names `requiredApps` and this app is not among them — or has no bundle
        /// identifier to be among them with.
        case appNotRequired(bundleID: String?)
        case appExcluded(bundleID: String)
        /// A requirement did not hold. The first one that failed, in the author's order.
        case requirementUnmet(ActionRequirement)
        /// A requirement spelling this build does not know. Never satisfied, negated or not.
        case requirementUnread(String)
    }

    public enum Outcome: Sendable, Equatable {
        case shown(Match)
        case hidden(Refusal)

        public var match: Match? {
            if case .shown(let match) = self { return match }
            return nil
        }

        public var refusal: Refusal? {
            if case .hidden(let refusal) = self { return refusal }
            return nil
        }

        public var isShown: Bool { match != nil }
    }

    /// Run the pipeline.
    ///
    /// `options` is the extension's **effective** option values — the user's choices over the
    /// manifest's defaults — which the option model resolves in M2 (§8.9). Until then it is empty,
    /// and an action gated on an option value simply does not show, which is the honest answer for a
    /// build that cannot let anyone set one.
    public static func match(
        _ action: ActionManifest,
        against facts: MatchingFacts,
        options: [String: String] = [:]
    ) -> Outcome {
        // Step 1: app filters. Exclusion is checked first, so that an app named in both lists is
        // excluded — the restrictive reading of a manifest that contradicts itself.
        if let bundleID = facts.bundleID, action.excludedApps.contains(where: { $0.matchesBundleID(bundleID) }) {
            return .hidden(.appExcluded(bundleID: bundleID))
        }
        if !action.requiredApps.isEmpty {
            guard let bundleID = facts.bundleID,
                  action.requiredApps.contains(where: { $0.matchesBundleID(bundleID) })
            else {
                return .hidden(.appNotRequired(bundleID: facts.bundleID))
            }
        }

        // Step 2: requirements, in the order the author wrote them, so that the refusal names the
        // first thing that was wrong rather than an arbitrary one.
        for requirement in action.requirements {
            if case .unrecognised(let spelling) = requirement.condition {
                return .hidden(.requirementUnread(spelling))
            }
            let holds = satisfies(requirement.condition, facts: facts, options: options)
            guard holds != requirement.isNegated else {
                return .hidden(.requirementUnmet(requirement))
            }
        }

        // Step 3: narrowing. The first non-negated requirement that narrows wins; a negated one says
        // what is *not* in the selection and so has nothing to hand the action.
        for requirement in action.requirements where !requirement.isNegated {
            guard let kind = requirement.condition.narrowsTo else { continue }
            // By step 2 the condition held, so the detection is there. A facts value that says
            // otherwise is inconsistent rather than interesting, and the action gets the selection.
            guard let address = narrowingTarget(kind, requirement: requirement.condition, facts: facts) else { break }
            return .shown(
                Match(narrowing: kind, span: address.span, value: address.value, fullText: facts.text)
            )
        }

        // Step 5: nothing narrowed, so the action acts on the selection.
        return .shown(Match(narrowing: nil, span: nil, value: facts.text, fullText: facts.text))
    }

    private static func narrowingTarget(
        _ kind: NarrowingKind,
        requirement: ActionRequirement.Condition,
        facts: MatchingFacts
    ) -> MatchingFacts.Address? {
        // `isurl` narrows to the one address the selection is, which is the only address there is.
        if case .isURL = requirement { return facts.addresses.first }
        return facts.firstAddress(kind)
    }

    private static func satisfies(
        _ condition: ActionRequirement.Condition,
        facts: MatchingFacts,
        options: [String: String]
    ) -> Bool {
        switch condition {
        case .text: facts.hasText
        case .cut: facts.canCut
        case .paste: facts.canPaste
        case .url, .urls: !facts.addresses(.url).isEmpty
        case .isURL: facts.isSingleAddress
        case .email, .emails: !facts.addresses(.email).isEmpty
        case .path: !facts.addresses(.path).isEmpty
        case .formatting: facts.hasFormatting
        case .option(let id, let value): options[id] == value
        // Unreachable: `match` refuses an unread spelling before asking whether it holds. Answering
        // `false` here would make `!unknown` satisfiable, which is the unsafe half of not knowing.
        case .unrecognised: false
        }
    }
}

extension String {
    /// Bundle identifiers are compared without case, because macOS treats them that way and a rule
    /// that works until somebody writes `com.apple.Safari` for `com.apple.safari` is not a rule.
    fileprivate func matchesBundleID(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive]) == .orderedSame
    }
}
