import Foundation
import PappuCore
import PappuExtensions
@testable import PappuSettings
import Testing

/// EXM-15a–d: what the batch review says, and what its answer approves.
@Suite struct BatchConsentPresenterTests {
    private let scratch: LibraryScratch

    init() throws {
        scratch = try LibraryScratch()
    }

    private static let fetch = "#popclip\nname: Fetch\nidentifier: com.example.fetch\nentitlements: [network]\nurl: https://example.com/?q=***\n"

    /// Search (listed only), Shout (script) and Fetch (network), in that order.
    private func proposals() async throws -> [ExtensionLibrary.Proposal] {
        [
            try await scratch.proposal(Snippets.search),
            try await scratch.proposal(Snippets.shell),
            try await scratch.proposal(Self.fetch),
        ]
    }

    /// EXM-15a: every extension is listed, with what it can do, under the heading that says how it is
    /// approved.
    @Test func everyExtensionIsListedWithItsCapabilities() async throws {
        let review = BatchConsentPresenter.review(try await proposals())
        #expect(review.listedOnly.map(\.name) == ["Search"])
        #expect(review.gated.map(\.name) == ["Shout", "Fetch"])
        #expect(review.listedOnly.allSatisfy { !$0.listed.isEmpty })
        #expect(review.gated.map { $0.gates.map(\.capability) } == [[.script], [.network]])
        #expect(review.provenance == BatchStrings.provenance)
        #expect(review.title == BatchStrings.title)
    }

    /// EXM-15b and 15d: with nothing switched on, the confirmation approves the listed-only one and
    /// leaves every gated one waiting.
    @Test func nothingSwitchedOnApprovesOnlyTheListedOnes() async throws {
        let review = BatchConsentPresenter.review(try await proposals())
        #expect(BatchConsentPresenter.answers(review, switchedOn: []) == [.approve(granting: []), .leaveUnapproved, .leaveUnapproved])
    }

    /// EXM-15c: a switch approves its own extension, with every gate it showed, and no other.
    @Test func aSwitchApprovesItsOwnExtensionWithItsGates() async throws {
        let review = BatchConsentPresenter.review(try await proposals())
        #expect(BatchConsentPresenter.answers(review, switchedOn: [2]) == [.approve(granting: []), .leaveUnapproved, .approve(granting: [.network])])
    }

    /// A listed-only row has no switch, so an id naming one changes nothing, and an id past the end
    /// approves nothing.
    @Test func onlyAGatedRowsSwitchCounts() async throws {
        let review = BatchConsentPresenter.review(try await proposals())
        #expect(BatchConsentPresenter.answers(review, switchedOn: [0, 7]) == [.approve(granting: []), .leaveUnapproved, .leaveUnapproved])
    }

    /// A name already installed is said, as the single review says it.
    @Test func aCollisionIsSaid() async throws {
        try await scratch.install(Snippets.search)
        let other = "#popclip\nname: Search\nidentifier: com.example.other\nurl: https://example.org/?q=***\n"
        let review = BatchConsentPresenter.review([try await scratch.proposal(other)]) { _ in "Old Search" }
        #expect(review.listedOnly.first?.collision == ExtensionStrings.collision("Old Search"))
    }
}

@Suite struct BatchStringsTests {
    @Test func everyStringTheBatchReviewSaysIsInTheCatalogue() {
        let bundle = BatchStrings.bundle
        for key in BatchStrings.all {
            let missing = "\u{1}missing\u{1}"
            #expect(
                bundle.localizedString(forKey: key, value: missing, table: nil) != missing,
                "\(key) has no entry in Localizable.strings"
            )
        }
    }

    /// The accessibility label for a switch names the extension it approves.
    @Test func theSwitchLabelNamesTheExtension() {
        #expect(BatchStrings.switchLabel("Shout") == "Approve \u{201C}Shout\u{201D}")
    }
}
