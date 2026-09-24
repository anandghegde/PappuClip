import Foundation
import GRDB
import PappuCore
@testable import PappuExtensions
import Testing

/// EXM-5a–d, 5g, SEC-4a–b and SEC-8c at the level of the store and the install pipeline: what the
/// review is shown, what its answer grants, and when an `ExecutionApproval` exists at all.
@Suite struct ExecutionApprovalTests {
    static let shell = "#popclip\nname: Shout\nidentifier: com.example.shout\nshellScript: echo hi\n"
    static let network = "#popclip\nname: Fetch\nidentifier: com.example.fetch\nentitlements: [network]\nurl: https://example.com/?q=***\n"

    /// One per test, held for its length so the folder outlives the library using it.
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    private func install(
        _ text: String,
        in library: ExtensionLibrary,
        answer: @escaping @Sendable (ExtensionLibrary.Proposal) -> ExtensionLibrary.Consent = { _ in .install }
    ) async throws -> (LocalIdentity, Reviews) {
        let reviews = Reviews(answer)
        guard case .installed(let identity, _) = try await library.install(.selectedText(text), review: reviews.reviewer) else {
            throw CocoaError(.featureUnsupported)
        }
        return (identity, reviews)
    }

    // MARK: EXM-5a–c: the review, and what confirming it approves

    /// EXM-5b: the review is shown what the extension *does*, worked out from its actions.
    @Test func theReviewIsShownTheEffectiveCapabilities() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (_, reviews) = try await install(Self.shell, in: library)
        let proposal = try #require(reviews.proposals.first)
        #expect(proposal.capabilities.gated == [.script])
    }

    /// EXM-5c: a listed-only extension is approved by the one confirmation.
    @Test func confirmingTheReviewApprovesTheBytesItShowed() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, reviews) = try await install(snippet("Search"), in: library)
        let approval = try #require(try await library.store.approval(for: identity))
        #expect(approval.digest == reviews.proposals.first?.digest)
        #expect(approval.gates.isEmpty)
        #expect(try await library.store.grants(of: identity).compactMap(\.key) == [.execution])
    }

    @Test func cancellingTheReviewApprovesNothing() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let outcome = try await library.install(.selectedText(Self.shell), review: Reviews { _ in .cancel }.reviewer)
        #expect(outcome == .cancelled)
        #expect(try await library.store.approvals().isEmpty)
    }

    // MARK: EXM-5d: gated capabilities default to "Don't Allow"

    @Test func aGatedCapabilityIsNotGrantedUnlessTheUserTurnsItOn() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library)
        let approval = try #require(try await library.store.approval(for: identity))
        #expect(approval.gates.isEmpty)
    }

    @Test func aGateTheUserTurnedOnIsGranted() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library) { _ in .install(granting: [.script]) }
        #expect(try await library.store.approval(for: identity)?.gates == [.script])
    }

    /// A grant for something the review did not show would approve a later version's use of it
    /// without that version having been reviewed for it.
    @Test func aGateTheReviewDidNotShowIsNotGranted() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library) { _ in .install(granting: [.script, .network]) }
        #expect(try await library.store.approval(for: identity)?.gates == [.script])
    }

    @Test func networkWithoutHostsIsGated() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (_, reviews) = try await install(Self.network, in: library)
        #expect(reviews.proposals.first?.capabilities.gated == [.network])
    }

    // MARK: SEC-8c: an approval is for bytes

    @Test func aGrantForOtherBytesApprovesNothing() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(snippet("Search"), in: library)
        let store = library.store
        try await store.database.write { db in
            try db.execute(sql: #"UPDATE "grant" SET content_digest = ?"#, arguments: [String(repeating: "0", count: 64)])
        }
        #expect(try await store.approval(for: identity) == nil)
    }

    /// An update is reviewed like an install, and its grants are rebound to the new bytes — the old
    /// version's gates are not carried over by themselves. (Only a registry publisher can offer an
    /// update, so this is the store's half; the review's half is the install tests above.)
    @Test func anUpdateIsApprovedForItsOwnBytesWithTheGatesItsReviewGranted() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library) { _ in .install(granting: [.script]) }
        let updated = Self.shell + "description: now louder\n"
        let digest = ContentDigest.of(snippet: updated)
        _ = try await library.store.activate(ExtensionStore.Activation(
            kind: .update,
            identity: identity,
            manifest: try manifest(updated),
            provenance: .local(.selectedText, digest),
            digest: digest,
            form: .snippet
        ))
        let approval = try #require(try await library.store.approval(for: identity))
        #expect(approval.digest == digest)
        #expect(approval.gates.isEmpty)
    }

    // MARK: SEC-4a–b: inspection and revocation

    @Test func revokingAnExtensionLeavesNoApprovalUntilItIsApprovedAgain() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library) { _ in .install(granting: [.script]) }
        let store = library.store

        try await store.revoke(identity)
        #expect(try await store.approval(for: identity) == nil)
        #expect(try await store.grants(of: identity).isEmpty)
        #expect(try await store.extension(identity)?.state == .pendingApproval)

        try await store.approve(identity, granting: [])
        #expect(try await store.approval(for: identity)?.gates == [])
        #expect(try await store.extension(identity)?.state == .enabled)
    }

    @Test func revokingOneGateKeepsTheRest() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library) { _ in .install(granting: [.script]) }
        try await library.store.revoke(.script, of: identity)
        let approval = try #require(try await library.store.approval(for: identity))
        #expect(approval.gates.isEmpty)
    }

    @Test func aDisabledExtensionHasNoApproval() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(snippet("Search"), in: library)
        let store = library.store
        try await store.database.write { db in
            try db.execute(sql: "UPDATE extension SET state = 'disabled' WHERE local_identity = ?", arguments: [identity])
        }
        #expect(try await store.approval(for: identity) == nil)
    }

    @Test func uninstallingTakesTheGrantsWithIt() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let (identity, _) = try await install(Self.shell, in: library) { _ in .install(granting: [.script]) }
        try await library.uninstall(identity)
        let count = try await library.store.database.read { db in try GrantRecord.fetchCount(db) }
        #expect(count == 0)
    }

    // MARK: EXM-5g: built-ins

    @Test func aBuiltinIsApprovedByTheAppAndCannotBeRevoked() async throws {
        let store = try ExtensionStore(at: nil)
        let identities = try await store.seedBuiltins(ExtensionStoreTests.builtins())
        let copy = try #require(identities.first)
        #expect(try await store.approval(for: copy) != nil)
        await #expect(throws: ExtensionStore.GrantError.builtinIsApprovedByTheApp) {
            try await store.revoke(copy)
        }
    }

    @Test func onlyTheAppBundleVouchesForABuiltinAction() throws {
        let manifest = ExtensionManifest(name: "Copy", identifier: "com.example.copy", actions: [ActionManifest(executor: .builtin(.copy))])
        let bundled = ActionCatalog(entries: [.init(manifest: manifest, origin: .appBundle)]).actions[0]
        let installed = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)]).actions[0]
        #expect(ExecutionApproval.bundled(bundled) != nil)
        #expect(ExecutionApproval.bundled(installed) == nil)
    }
}
