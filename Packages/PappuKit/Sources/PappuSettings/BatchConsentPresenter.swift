import Foundation
import PappuCore
import PappuExtensions

/// What the batch review says and what its answer approves (EXM-15a–d, safety spec §S4).
///
/// The single review's two levels, across a set. Every extension is listed with its capabilities
/// (EXM-15a). Those with only listed capabilities are approved together by the sheet's one
/// confirmation, which comes after the list (EXM-15b). Each one with a gated capability has one switch
/// of its own, off by default, and turning it on approves that extension with every gate it showed
/// (EXM-15c); left off, it is installed and waits, disabled, for Extension Info's Approve (EXM-15d).
/// Nothing here can approve a gated extension the user did not switch on: `answers` takes the set of
/// switched-on rows and there is no other input.
public enum BatchConsentPresenter {
    public struct Row: Sendable, Equatable, Identifiable {
        /// The proposal's place in the batch, which is also the answer's.
        public var id: Int
        public var name: String
        public var listed: [String]
        /// Sentences for the gated capabilities; empty for a listed-only extension.
        public var gates: [ConsentPresenter.Gate]
        /// Said when this one sits beside an installed extension of the same name or identifier.
        public var collision: String?

        public var isGated: Bool { !gates.isEmpty }
    }

    public struct Review: Sendable, Equatable {
        public var title: String
        /// SEC-8b: said once for the set, which is all local code.
        public var provenance: String
        /// EXM-15b: approved together by the confirmation.
        public var listedOnly: [Row]
        /// EXM-15c: one switch each, all off.
        public var gated: [Row]
        public var confirm: String
    }

    public static func review(
        _ proposals: [ExtensionLibrary.Proposal],
        locale: Locale = .current,
        name: (LocalIdentity) -> String? = { _ in nil }
    ) -> Review {
        var listedOnly: [Row] = []
        var gated: [Row] = []
        for (index, proposal) in proposals.enumerated() {
            let extensionName = proposal.manifest.name.text(for: locale)
            var collision: String?
            if case .separate(let found) = proposal.decision, let first = found.first {
                collision = ExtensionStrings.collision(name(first.existing) ?? extensionName)
            }
            let row = Row(
                id: index,
                name: extensionName,
                listed: ConsentPresenter.sentences(for: proposal.capabilities),
                gates: ConsentPresenter.gates(of: proposal.capabilities),
                collision: collision
            )
            if row.isGated { gated.append(row) } else { listedOnly.append(row) }
        }
        return Review(
            title: BatchStrings.title,
            provenance: BatchStrings.provenance,
            listedOnly: listedOnly,
            gated: gated,
            confirm: BatchStrings.confirm
        )
    }

    /// The confirmation's answer, one per proposal in the batch's order. `switchedOn` is the ids of the
    /// gated rows the user turned on; an id that is not a gated row changes nothing.
    public static func answers(_ review: Review, switchedOn: Set<Int>) -> [ExtensionLibrary.BatchApproval] {
        let count = review.listedOnly.count + review.gated.count
        var answers = Array(repeating: ExtensionLibrary.BatchApproval.leaveUnapproved, count: count)
        for row in review.listedOnly where row.id < count {
            answers[row.id] = .approve(granting: [])
        }
        for row in review.gated where row.id < count {
            answers[row.id] = switchedOn.contains(row.id)
                ? .approve(granting: Set(row.gates.map(\.capability)))
                : .leaveUnapproved
        }
        return answers
    }
}

/// Every word the batch review says (PRD §7.12). Its own list, walked against the catalogue by a test,
/// as `ExtensionStrings` is.
public enum BatchStrings {
    public static var title: String { localized("batch.title", "Review Extensions") }

    public static var provenance: String {
        localized("batch.provenance", "These come from files on this Mac. They are not signed, and nobody has reviewed them.")
    }

    public static var listedHeading: String {
        localized("batch.listed.heading", "Approved together when you confirm:")
    }

    public static var gatedHeading: String {
        localized("batch.gated.heading", "These ask for more. Each stays installed but turned off unless you switch it on; you can approve it later in Extension Info.")
    }

    public static var confirm: String { localized("batch.confirm", "Install") }

    public static var cancel: String { ExtensionStrings.cancel }

    public static func switchLabel(_ name: String) -> String {
        String(localized: "batch.switch.accessibility", defaultValue: "Approve \u{201C}\(name)\u{201D}", bundle: .module,
               comment: "VoiceOver label for one gated extension's switch. %@ is its name.")
    }

    public static var nothingAsked: String { ExtensionStrings.nothingAsked }

    public static var bundle: Bundle { .module }

    public static let all: [String] = [
        "batch.title",
        "batch.provenance",
        "batch.listed.heading",
        "batch.gated.heading",
        "batch.confirm",
        "batch.switch.accessibility",
    ]

    private static func localized(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
