import Foundation
import PappuCore
@testable import PappuExtensions
import Testing

/// EXM-11: what Import from PopClip reads from PopClip's folders. The exclusion list's format is
/// unverified (see `PopClipExclusions`), so these are fixtures of the shape it is believed to have.
@Suite struct PopClipExclusionsTests {
    private func plist(_ object: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    @Test func theBlockedAppsArrayIsReadInOrder() throws {
        let data = try plist(["BlockedApps": ["com.apple.Terminal", "com.googlecode.iterm2"], "Other": 1])
        #expect(PopClipExclusions.read(preferences: data) == ["com.apple.Terminal", "com.googlecode.iterm2"])
    }

    @Test func anXMLPropertyListReadsTheSame() throws {
        let data = try plist(["BlockedApps": ["com.apple.Terminal"]], format: .xml)
        #expect(PopClipExclusions.read(preferences: data) == ["com.apple.Terminal"])
    }

    @Test func noKeyIsNoExclusions() throws {
        #expect(PopClipExclusions.read(preferences: try plist(["Something": ["com.apple.Terminal"]])).isEmpty)
    }

    /// Another shape than the one believed in reads as nothing rather than as a guess.
    @Test func anotherShapeIsNoExclusions() throws {
        #expect(PopClipExclusions.read(preferences: try plist(["BlockedApps": "com.apple.Terminal"])).isEmpty)
        #expect(PopClipExclusions.read(preferences: try plist(["BlockedApps": ["com.apple.Terminal": true]])).isEmpty)
        #expect(PopClipExclusions.read(preferences: try plist(["com.apple.Terminal"])).isEmpty)
    }

    @Test func somethingThatIsNotAPropertyListIsNoExclusions() {
        #expect(PopClipExclusions.read(preferences: Data("not a plist".utf8)).isEmpty)
        #expect(PopClipExclusions.read(preferences: Data()).isEmpty)
    }

    /// Blanks, repeats, paths, names and non-strings are dropped: a rule no app can match is not kept.
    @Test func entriesThatAreNotBundleIdentifiersAreDropped() throws {
        let data = try plist(["BlockedApps": [
            " com.apple.Terminal ", "com.apple.Terminal", "", "Terminal", "/Applications/Terminal.app", 42, ".com.x", "com.x.",
            "org.p0deje.Maccy",
        ] as [Any]])
        #expect(PopClipExclusions.read(preferences: data) == ["com.apple.Terminal", "org.p0deje.Maccy"])
    }
}

@Suite struct PopClipImportTests {
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    private func locations(preferences: [URL] = []) -> PopClipImport.Locations {
        PopClipImport.Locations(
            extensions: scratch.root.appending(path: "PopClip/Extensions", directoryHint: .isDirectory),
            preferences: preferences
        )
    }

    /// EXM-11's condition: no folder, no offer.
    @Test func withoutPopClipsFolderThereIsNothingToOffer() {
        #expect(PopClipImport.find(at: locations()) == nil)
        #expect(!PopClipImport.isPresent(at: locations()))
    }

    @Test func thePackageFoldersAreFoundInNameOrder() throws {
        let where_ = locations()
        let folder = where_.extensions
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Zeta.popclipext", "alpha.popclipext", "Beta 10.popclipext", "Beta 9.popclipext", "Notes.txt.popclipext"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        // A file with the right extension is not a package folder, and other folders are not packages.
        try Data().write(to: folder.appending(path: "Loose.popclipext"))
        try FileManager.default.createDirectory(at: folder.appending(path: "Cache"), withIntermediateDirectories: true)

        let found = try #require(PopClipImport.find(at: where_))
        #expect(PopClipImport.isPresent(at: where_))
        #expect(found.packages.map(\.lastPathComponent) == ["alpha.popclipext", "Beta 9.popclipext", "Beta 10.popclipext", "Notes.txt.popclipext", "Zeta.popclipext"])
        #expect(found.excludedApps.isEmpty)
    }

    /// The first preferences file that reads wins, and a missing one is passed over.
    @Test func theExclusionsComeFromTheFirstPreferencesFileThere() throws {
        let missing = scratch.root.appending(path: "missing.plist")
        let prefs = scratch.root.appending(path: "com.pilotmoon.popclip.plist")
        try PropertyListSerialization.data(fromPropertyList: ["BlockedApps": ["com.apple.Terminal"]], format: .binary, options: 0).write(to: prefs)
        let where_ = locations(preferences: [missing, prefs])
        try FileManager.default.createDirectory(at: where_.extensions, withIntermediateDirectories: true)

        let found = try #require(PopClipImport.find(at: where_))
        #expect(found.packages.isEmpty)
        #expect(found.excludedApps == ["com.apple.Terminal"])
        #expect(!found.isEmpty)
    }

    /// Read-only: finding what there is changes nothing in PopClip's folders.
    @Test func findingChangesNothing() throws {
        let where_ = locations()
        try FileManager.default.createDirectory(at: where_.extensions, withIntermediateDirectories: true)
        let package = where_.extensions.appending(path: "Say.popclipext")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{\"name\":\"Say\"}".utf8).write(to: package.appending(path: "Config.json"))
        let before = Scratch.tree(where_.extensions)
        _ = PopClipImport.find(at: where_)
        #expect(Scratch.tree(where_.extensions) == before)
    }
}

/// EXM-15a–d, through the library: several extensions staged, reviewed on one sheet, and activated
/// with what the sheet said; a gated one the user did not switch on is installed and waits, disabled.
@Suite struct BatchInstallTests {
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    /// Three packages as Import from PopClip brings them: one listed-only, two with a shell script.
    private func packages() throws -> [ExtensionLibrary.Source] {
        let search = try scratch.package("Search.popclipext", identifier: "com.example.search", title: "Search")
        let shout = try shellPackage("Shout")
        let whisper = try shellPackage("Whisper")
        return [search, shout, whisper].map(ExtensionLibrary.Source.popClipPackage)
    }

    /// A package whose one action is a shell script: gated `.script`.
    private func shellPackage(_ name: String) throws -> URL {
        let folder = scratch.root.appending(path: "\(name).popclipext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config: [String: Any] = ["name": name, "identifier": "com.example.\(name.lowercased())", "shellScript": "echo hi"]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: folder.appending(path: "Config.json"))
        return folder
    }

    /// A reviewer that answers with `answer` and remembers what it was shown.
    private final class BatchReviews: @unchecked Sendable {
        private let lock = NSLock()
        private var shown: [[ExtensionLibrary.Proposal]] = []
        let answer: @Sendable ([ExtensionLibrary.Proposal]) -> [ExtensionLibrary.BatchApproval]?

        init(_ answer: @escaping @Sendable ([ExtensionLibrary.Proposal]) -> [ExtensionLibrary.BatchApproval]?) {
            self.answer = answer
        }

        var batches: [[ExtensionLibrary.Proposal]] { lock.withLock { shown } }

        var reviewer: ExtensionLibrary.BatchReviewer {
            { proposals in
                self.lock.withLock { self.shown.append(proposals) }
                return self.answer(proposals)
            }
        }
    }

    /// The sheet's answer when nothing was switched on: listed-only approved, gated left waiting.
    private static let nothingSwitchedOn: @Sendable ([ExtensionLibrary.Proposal]) -> [ExtensionLibrary.BatchApproval]? = { proposals in
        proposals.map { $0.capabilities.gated.isEmpty ? .approve(granting: []) : .leaveUnapproved }
    }

    private func identity(_ entry: ExtensionLibrary.BatchEntry) throws -> LocalIdentity {
        guard case .success(.installed(let identity, _)) = entry.result else { throw CocoaError(.featureUnsupported) }
        return identity
    }

    /// EXM-15a: one review for the set, every one of them on it with its capabilities.
    @Test func theSetIsReviewedOnceWithEveryCapability() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let reviews = BatchReviews(Self.nothingSwitchedOn)
        _ = try await library.installBatch(try packages(), review: reviews.reviewer)
        #expect(reviews.batches.count == 1)
        let batch = try #require(reviews.batches.first)
        #expect(batch.map { $0.manifest.name.text(for: Locale(identifier: "en")) } == ["Search", "Shout", "Whisper"])
        #expect(batch.map(\.capabilities.gated) == [[], [.script], [.script]])
    }

    /// Imported folders are local, unsigned code (EXM-11, SEC-8b).
    @Test func importedPackagesAreLocalAndUnsigned() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let reviews = BatchReviews(Self.nothingSwitchedOn)
        _ = try await library.installBatch(try packages(), review: reviews.reviewer)
        for proposal in reviews.batches.first ?? [] {
            #expect(proposal.provenance == .local(.popClipImport, proposal.digest))
        }
    }

    /// EXM-15b and EXM-15d: the confirmation approves the listed-only one; the gated ones the user did
    /// not switch on are installed, disabled, and approved for nothing.
    @Test func aGatedExtensionArrivesDisabledUntilSwitchedOn() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let entries = try await library.installBatch(try packages(), review: BatchReviews(Self.nothingSwitchedOn).reviewer)
        let (search, shout, whisper) = try (identity(entries[0]), identity(entries[1]), identity(entries[2]))
        let store = library.store

        #expect(entries.map(\.approved) == [true, false, false])
        #expect(try await store.extension(search)?.state == .enabled)
        #expect(try await store.approval(for: search) != nil)
        for waiting in [shout, whisper] {
            #expect(try await store.extension(waiting)?.state == .pendingApproval)
            #expect(try await store.approval(for: waiting) == nil)
            #expect(try await store.grants(of: waiting).isEmpty)
        }
    }

    /// EXM-15c: a switch turned on approves that one, with the gates it showed, and no other.
    @Test func switchingOneOnApprovesThatOneAlone() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let reviews = BatchReviews { proposals in
            [.approve(granting: []), .approve(granting: [.script]), .leaveUnapproved].prefix(proposals.count).map { $0 }
        }
        let entries = try await library.installBatch(try packages(), review: reviews.reviewer)
        let (shout, whisper) = try (identity(entries[1]), identity(entries[2]))
        #expect(try await library.store.approval(for: shout)?.gates == [.script])
        #expect(try await library.store.approval(for: whisper) == nil)
    }

    /// EXM-15d: one left waiting is approved later, in Extension Info, like any other.
    @Test func oneLeftWaitingCanBeApprovedLater() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let entries = try await library.installBatch(try packages(), review: BatchReviews(Self.nothingSwitchedOn).reviewer)
        let shout = try identity(entries[1])
        try await library.store.approve(shout, granting: [.script])
        #expect(try await library.store.extension(shout)?.state == .enabled)
        #expect(try await library.store.approval(for: shout)?.gates == [.script])
    }

    @Test func cancellingTheReviewInstallsNothing() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let entries = try await library.installBatch(try packages(), review: BatchReviews { _ in nil }.reviewer)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { if case .success(.cancelled) = $0.result { true } else { false } })
        #expect(try await library.store.extensions().isEmpty)
    }

    /// An answer of the wrong length is not guessed at.
    @Test func anAnswerForADifferentSetInstallsNothing() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        _ = try await library.installBatch(try packages(), review: BatchReviews { _ in [.approve(granting: [])] }.reviewer)
        #expect(try await library.store.extensions().isEmpty)
    }

    /// Something already installed with the same bytes is reported and not reviewed again; a folder that
    /// is not an extension is reported and left out.
    @Test func theAlreadyInstalledAndTheUnreadableAreNotReviewed() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        let sources = try packages()
        _ = try await library.installBatch([sources[0]], review: BatchReviews(Self.nothingSwitchedOn).reviewer)

        let broken = scratch.root.appending(path: "Broken.popclipext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let reviews = BatchReviews(Self.nothingSwitchedOn)
        let entries = try await library.installBatch(sources + [.popClipPackage(broken)], review: reviews.reviewer)

        #expect(reviews.batches.first?.count == 2)
        guard case .success(.alreadyInstalled) = entries[0].result else {
            Issue.record("expected alreadyInstalled, got \(entries[0].result)")
            return
        }
        guard case .failure = entries[3].result else {
            Issue.record("expected a failure, got \(entries[3].result)")
            return
        }
    }

    /// EXM-2: nothing in a batch replaces anything; a name already there is installed beside it.
    @Test func aBatchNeverOffersToReplace() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        _ = try await library.install(.selectedText(snippet("Search", identifier: "com.example.search")), review: Reviews().reviewer)
        let reviews = BatchReviews(Self.nothingSwitchedOn)
        _ = try await library.installBatch(try packages(), review: reviews.reviewer)
        for proposal in reviews.batches.first ?? [] {
            if case .replacementOffered = proposal.decision { Issue.record("a batch offered a replacement") }
        }
    }
}
