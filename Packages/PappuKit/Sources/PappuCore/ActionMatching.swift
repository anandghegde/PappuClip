import Foundation

/// §8.5's pipeline: does this action show for this selection, and on what does it act (FLT-5).
///
/// A pure function of `(ActionManifest, MatchingFacts, option values)`, deliberately: it is the one
/// decision a user notices every single time — a bar with a button that should not be there, or
/// without one that should — and the only way to be sure about it is to be able to run it a thousand
/// times over a table with no window server in sight.
///
/// **The steps.** All five of §8.5's:
///
/// 1. App filters (`requiredApps`, `excludedApps`).
/// 2. `requirements`, each satisfiable or negated.
/// 3. Narrowing: a satisfied `url`, `isurl`, `email` or `path` makes the action act on that one
///    detection rather than on the whole selection.
/// 4. `regex`, matched against what step 3 left. The first match becomes what the action acts on,
///    and no match hides the action.
/// 5. The full text stays available whatever steps 3 and 4 narrowed to.
public enum ActionMatching {
    /// A shown action, and what it acts on (§8.5 steps 3 and 5).
    public struct Match: Sendable, Equatable {
        /// Which requirement did the narrowing, or nil when the action acts on the selection.
        public var narrowing: NarrowingKind?
        /// Where `value` sits in the full text. Nil when nothing narrowed. After a regex on a narrowed
        /// value it stays the detection's span, because a normalised URL's offsets are not the
        /// selection's.
        public var span: TextSpan?
        /// What the action acts on: the regex match, else the narrowed detection's normalised value,
        /// else the full selection.
        public var value: String
        /// The whole selection, always (§8.5 step 5).
        public var fullText: String
        /// Step 4's match, whole match first and then each capture group, nil for a group that did not
        /// take part. Nil when the action has no `regex`. JavaScript reads it as `regexResult` (JS-3).
        public var regexCaptures: [String?]?

        public init(
            narrowing: NarrowingKind?,
            span: TextSpan?,
            value: String,
            fullText: String,
            regexCaptures: [String?]? = nil
        ) {
            self.narrowing = narrowing
            self.span = span
            self.value = value
            self.fullText = fullText
            self.regexCaptures = regexCaptures
        }

        public var isNarrowed: Bool { narrowing != nil || regexCaptures != nil }
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
        /// Step 4: the `regex` found nothing in what step 3 left.
        case regexUnmatched
        /// The `regex` does not compile. `ManifestBuilder` refuses these at load, so this is a manifest
        /// that reached the catalog some other way — and it hides rather than matching everything.
        case regexUnreadable
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
        var match = Match(narrowing: nil, span: nil, value: facts.text, fullText: facts.text)
        for requirement in action.requirements where !requirement.isNegated {
            guard let kind = requirement.condition.narrowsTo else { continue }
            // By step 2 the condition held, so the detection is there. A facts value that says
            // otherwise is inconsistent rather than interesting, and the action gets the selection.
            guard let address = narrowingTarget(kind, requirement: requirement.condition, facts: facts) else { break }
            match = Match(narrowing: kind, span: address.span, value: address.value, fullText: facts.text)
            break
        }

        // Step 4: the regex, against what step 3 left.
        if let pattern = action.regex {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return .hidden(.regexUnreadable)
            }
            let searched = match.value as NSString
            guard let result = expression.firstMatch(
                in: match.value, range: NSRange(location: 0, length: searched.length)
            ) else {
                return .hidden(.regexUnmatched)
            }
            let captures: [String?] = (0..<result.numberOfRanges).map { index in
                let range = result.range(at: index)
                return range.location == NSNotFound ? nil : searched.substring(with: range)
            }
            if match.narrowing == nil { match.span = TextSpan(result.range) }
            match.value = captures[0] ?? ""
            match.regexCaptures = captures
        }

        // Step 5: `fullText` is the selection whatever steps 3 and 4 did.
        return .shown(match)
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
