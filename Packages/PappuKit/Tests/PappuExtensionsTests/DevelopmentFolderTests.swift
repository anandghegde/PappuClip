import Foundation
import PappuCore
@testable import PappuExtensions
import Testing

/// DEV-1: a development folder is installed through the review, and reloaded from where it is only when
/// the developer asks. A reload that needs more than was approved is reviewed again.
@Suite struct DevelopmentFolderTests {
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    private func config(_ actions: [[String: String]]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["name": "Dev", "identifier": "com.example.dev", "actions": actions],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private var searchAction: [String: String] { ["title": "Search", "identifier": "a0", "url": "https://example.com/?q=***"] }
    private var shellAction: [String: String] { ["title": "Shout", "identifier": "a1", "shellScript": "echo hi"] }

    private func folder(_ actions: [[String: String]], extra: [String: String] = [:]) throws -> URL {
        var files = extra
        files["Config.json"] = try config(actions)
        return try scratch.package("Dev.popclipext", files: files)
    }

    private func approve(_ url: URL, in library: ExtensionLibrary, reviews: Reviews = Reviews()) async throws -> LocalIdentity {
        guard case .installed(let identity, replaced: nil) = try await library.approveDevelopmentFolder(url, review: reviews.reviewer) else {
            throw CocoaError(.featureUnsupported)
        }
        return identity
    }

    @Test func approvingAFolderReviewsItAsDevelopmentCodeAndRemembersIt() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction])
        let reviews = Reviews()
        let identity = try await approve(url, in: library, reviews: reviews)

        let proposal = try #require(reviews.proposals.first)
        #expect(reviews.proposals.count == 1)
        guard case .local(.developmentFolder, _) = proposal.provenance else {
            Issue.record("expected development provenance, got \(proposal.provenance)")
            return
        }
        let folders = try await library.developmentFolders()
        #expect(folders.map(\.identity) == [identity])
        #expect(folders.first?.path == url.standardizedFileURL.path)
        #expect(folders.first?.approved == proposal.capabilities)
        #expect(try await library.store.approval(for: identity) != nil)
        // The same folder twice is refused rather than installed again beside itself.
        await #expect(throws: ExtensionLibrary.DevelopmentError.self) {
            try await library.approveDevelopmentFolder(url, review: reviews.reviewer)
        }
    }

    @Test func aCancelledApprovalInstallsNothing() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let outcome = try await library.approveDevelopmentFolder(try folder([searchAction]), review: Reviews { _ in .cancel }.reviewer)
        #expect(outcome == .cancelled)
        #expect(try await library.developmentFolders().isEmpty)
        #expect(try await library.store.extensions().filter { !$0.isBuiltin }.isEmpty)
    }

    @Test func aFileIsNotADevelopmentFolder() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let file = try scratch.file("Search.popcliptxt", snippet())
        await #expect(throws: ExtensionLibrary.DevelopmentError.notAFolder("Search.popcliptxt")) {
            try await library.approveDevelopmentFolder(file, review: Reviews().reviewer)
        }
    }

    @Test func aDevelopmentFolderNeverReplacesAnInstalledExtension() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let installed = try scratch.package("Installed.popclipext", identifier: "com.example.dev")
        guard case .installed(let original, _) = try await library.install(.packageFolder(installed), review: Reviews().reviewer) else {
            Issue.record("not installed")
            return
        }
        let reviews = Reviews()
        let identity = try await approve(try folder([searchAction]), in: library, reviews: reviews)
        #expect(identity != original)
        #expect(try await library.store.extension(original) != nil)
        guard case .separate = reviews.proposals.first?.decision else {
            Issue.record("expected a separate install, got \(String(describing: reviews.proposals.first?.decision))")
            return
        }
    }

    @Test func reloadingUnchangedFilesDoesNothing() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let identity = try await approve(try folder([searchAction]), in: library)
        let reviews = Reviews()
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .unchanged)
        #expect(reviews.proposals.isEmpty)
    }

    @Test func aChangeWithinWhatWasApprovedReloadsWithoutAReview() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction])
        let identity = try await approve(url, in: library)
        let before = try #require(try await library.store.extension(identity)?.activeVersion)

        try Data("<svg/>".utf8).write(to: url.appending(path: "icon.svg"))
        let reviews = Reviews()
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .reloaded)
        #expect(reviews.proposals.isEmpty)
        let record = try #require(try await library.store.extension(identity))
        #expect(record.activeVersion != before)
        #expect(record.activeVersion == (try ContentDigest.of(packageAt: url)))
        #expect(try await library.store.approval(for: identity)?.digest == record.activeVersion)
        // As with any update, one previous version is kept for rollback (EXM-13) and older ones retire.
        try Data("<svg></svg>".utf8).write(to: url.appending(path: "icon.svg"))
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .reloaded)
        let latest = try #require(try await library.store.extension(identity)?.activeVersion)
        let identityFolder = scratch.paths.extensions.appending(path: identity.description)
        #expect(Scratch.tree(identityFolder).filter { !$0.contains("/") } == Set([record.activeVersion!.hex, latest.hex]))
    }

    @Test func aNewCapabilityIsReviewedAndItsGateStartsOff() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction])
        let identity = try await approve(url, in: library)

        try Data(try config([searchAction, shellAction]).utf8).write(to: url.appending(path: "Config.json"))
        let reviews = Reviews()
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .approved)
        let proposal = try #require(reviews.proposals.first)
        #expect(proposal.decision == .replacementOffered(identity))
        #expect(proposal.capabilities.gated == [.script])
        // `.install` names no gates, so the new one is off.
        #expect(try await library.store.approval(for: identity)?.gates == [])
        #expect(try await library.developmentFolder(identity)?.approved.gated == [.script])
    }

    @Test func cancellingAReviewedReloadKeepsTheOldVersion() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction])
        let identity = try await approve(url, in: library)
        let before = try await library.store.extension(identity)?.activeVersion

        try Data(try config([searchAction, shellAction]).utf8).write(to: url.appending(path: "Config.json"))
        #expect(try await library.reloadDevelopmentFolder(identity, review: Reviews { _ in .cancel }.reviewer) == .cancelled)
        #expect(try await library.store.extension(identity)?.activeVersion == before)
        #expect(try await library.store.approval(for: identity)?.digest == before)
        #expect(try await library.developmentFolder(identity)?.approved.gated == [])
        // An answer the reload never offers is refused, not taken as an install.
        await #expect(throws: ExtensionLibrary.InstallError.answerNotOffered) {
            try await library.reloadDevelopmentFolder(identity, review: Reviews { _ in .installSeparately }.reviewer)
        }
    }

    @Test func aSilentReloadKeepsOnlyGatesAlreadyGranted() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction, shellAction])
        let identity = try await approve(url, in: library, reviews: Reviews { _ in .install(granting: [.script]) })
        #expect(try await library.store.approval(for: identity)?.gates == [.script])

        // Dropping the script action drops its gate; the reload asks nothing and grants nothing new.
        try Data(try config([searchAction]).utf8).write(to: url.appending(path: "Config.json"))
        let reviews = Reviews()
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .reloaded)
        #expect(reviews.proposals.isEmpty)
        #expect(try await library.store.approval(for: identity)?.gates == [])

        // Putting it back is within what was approved, but the grant was not kept: it is off again.
        try Data(try config([searchAction, shellAction]).utf8).write(to: url.appending(path: "Config.json"))
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .reloaded)
        #expect(try await library.store.approval(for: identity)?.gates == [])
    }

    @Test func aRevokedExtensionIsReviewedOnEveryReload() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction])
        let identity = try await approve(url, in: library)
        try await library.store.revoke(identity)

        let reviews = Reviews()
        #expect(try await library.reloadDevelopmentFolder(identity, review: reviews.reviewer) == .approved)
        #expect(reviews.proposals.count == 1)
        #expect(try await library.store.approval(for: identity) != nil)
    }

    @Test func removingForgetsTheFolderAndLeavesItsFiles() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let url = try folder([searchAction])
        let identity = try await approve(url, in: library)
        try await library.removeDevelopmentFolder(identity)
        #expect(try await library.developmentFolders().isEmpty)
        #expect(try await library.store.extension(identity) == nil)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "Config.json").path))
        await #expect(throws: ExtensionLibrary.DevelopmentError.unknown(identity)) {
            try await library.reloadDevelopmentFolder(identity, review: Reviews().reviewer)
        }
    }

    @Test func anExtensionUninstalledElsewhereIsNoLongerADevelopmentFolder() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let identity = try await approve(try folder([searchAction]), in: library)
        try await library.uninstall(identity)
        #expect(try await library.developmentFolders().isEmpty)
    }

    @Test func developmentFoldersAreNeverRecognisedFromAFileAlone() throws {
        let url = try folder([searchAction])
        #expect(ExtensionLibrary.Source.file(url) == .packageFolder(url))
    }

    @Test func exceedsComparesEveryPartOfWhatWasApproved() {
        let approved = CapabilitySet(listed: [.readsAndReplacesText], gated: [.script], controlledApps: ["Mail"], reachableMethods: ["a"])
        #expect(!CapabilitySet().exceeds(approved))
        #expect(!approved.exceeds(approved))
        #expect(CapabilitySet(listed: [.runsOnEveryAppearance]).exceeds(approved))
        #expect(CapabilitySet(gated: [.network]).exceeds(approved))
        #expect(CapabilitySet(controlledApps: ["Finder"]).exceeds(approved))
        #expect(CapabilitySet(reachableMethods: ["b"]).exceeds(approved))
    }
}
