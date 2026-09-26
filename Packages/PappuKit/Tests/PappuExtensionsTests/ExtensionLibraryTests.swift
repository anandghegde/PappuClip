import Foundation
import Synchronization
import PappuCore
@testable import PappuExtensions
import Testing
import ZIPFoundation

/// EXM-1, EXM-2, EXM-9 and SEC-8a–d through the whole install pipeline, on a real folder and a real
/// SQLite file.
@Suite struct ExtensionLibraryTests {
    // MARK: EXM-1: from files

    @Test func aPackageFolderInstallsIntoAFolderNamedByIdentityAndDigest() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let source = try scratch.package(files: ["icon.svg": "<svg/>"])

        let outcome = try await library.install(.packageFolder(source), review: Reviews().reviewer)
        guard case .installed(let identity, replaced: nil) = outcome else {
            Issue.record("expected an install, got \(outcome)")
            return
        }
        let record = try #require(try await library.store.extension(identity))
        let digest = try ContentDigest.of(packageAt: source)
        #expect(record.activeVersion == digest)
        #expect(record.provenance == .local(.packageFile, digest))
        #expect(record.manifestIdentifier == "com.example.translate")
        let folder = try #require(library.folder(for: record))
        #expect(folder.path.hasSuffix("Extensions/\(identity)/\(digest.hex)"))
        #expect(Scratch.tree(folder) == ["Config.json", "icon.svg"])
        #expect(Scratch.tree(scratch.paths.staging).isEmpty)
        #expect(try await library.store.placedActions().map(\.item.actionKey) == ["a0"])
        // The original is the user's, and stays.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aZippedPackageIsDeletedAfterInstall() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let folder = try scratch.package(files: ["script.sh": "echo hi"])
        let archive = try scratch.zip(folder)

        let outcome = try await library.install(.zippedPackage(archive), review: Reviews().reviewer)
        guard case .installed(let identity, _) = outcome else {
            Issue.record("expected an install, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        let record = try #require(try await library.store.extension(identity))
        // The digest is of the files, so a zipped and an unzipped copy are the same extension.
        #expect(record.activeVersion == (try ContentDigest.of(packageAt: folder)))
        #expect(try await library.install(.packageFolder(folder), review: Reviews().reviewer) == .alreadyInstalled(identity))
    }

    @Test func aSnippetFileInstalls() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let text = snippet("Search")
        let file = try scratch.file("Search.popcliptxt", text)
        guard case .installed(let identity, _) = try await library.install(.snippetFile(file), review: Reviews().reviewer) else {
            Issue.record("not installed")
            return
        }
        let record = try #require(try await library.store.extension(identity))
        #expect(record.provenance == .local(.snippetFile, .of(snippet: text)))
        let folder = try #require(library.folder(for: record))
        #expect(try String(contentsOf: folder.appending(path: StagedForm.snippetFileName), encoding: .utf8) == text)
        #expect(try await library.store.versions(of: identity).map(\.form) == [.snippet])
    }

    // MARK: EXM-3: snippets under their language's suffix

    @Test func codeAndYAMLSnippetFilesInstallAsSnippets() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let files = [
            try scratch.file("Shout.js", "// #popclip\n// name: Shout\n// language: javascript\npopclip.pasteText(popclip.input.text.toUpperCase())"),
            try scratch.file("Ask.ts", "// #popclip\n// name: Ask\nconst text: string = popclip.input.text\npopclip.pasteText(`${text}?`)"),
            try scratch.file("Search.yaml", snippet("Search")),
        ]
        for file in files {
            let source = try #require(ExtensionLibrary.Source.file(file))
            #expect(source == .snippetFile(file))
            guard case .installed(let identity, _) = try await library.install(source, review: Reviews().reviewer) else {
                Issue.record("\(file.lastPathComponent) not installed")
                continue
            }
            let record = try #require(try await library.store.extension(identity))
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(record.provenance == .local(.snippetFile, .of(snippet: text)))
            #expect(try await library.store.versions(of: identity).map(\.form) == [.snippet])
        }
    }

    @Test func aCodeFileWithNoMarkerIsRefused() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let file = try scratch.file("plain.js", "console.log('not an extension')")
        await #expect(throws: ExtensionLibrary.InstallError.self) {
            try await library.install(.snippetFile(file), review: Reviews().reviewer)
        }
        #expect(Scratch.tree(scratch.paths.staging).isEmpty)
    }

    /// FMT-7.
    @Test func installedExtensionsLiveInApplicationSupport() {
        let paths = ExtensionLibrary.Paths.standard
        #expect(paths.extensions.path.hasSuffix("Library/Application Support/PappuClip/Extensions"))
        #expect(paths.staging.deletingLastPathComponent() == paths.extensions.deletingLastPathComponent())
    }

    @Test func sourceFilesAreRecognisedByExtension() {
        #expect(ExtensionLibrary.Source.file(URL(filePath: "/a/X.popclipext")) == .packageFolder(URL(filePath: "/a/X.popclipext")))
        #expect(ExtensionLibrary.Source.file(URL(filePath: "/a/X.PappuExtZ")) == .zippedPackage(URL(filePath: "/a/X.PappuExtZ")))
        #expect(ExtensionLibrary.Source.file(URL(filePath: "/a/X.popcliptxt")) == .snippetFile(URL(filePath: "/a/X.popcliptxt")))
        #expect(ExtensionLibrary.Source.file(URL(filePath: "/a/X.ts")) == .snippetFile(URL(filePath: "/a/X.ts")))
        #expect(ExtensionLibrary.Source.file(URL(filePath: "/a/X.txt")) == nil)
    }

    // MARK: EXM-2: from a selection

    @Test func selectedTextInstallsUpToTheLimit() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let outcome = try await library.install(.selectedText(snippet("Search")), review: Reviews().reviewer)
        guard case .installed = outcome else {
            Issue.record("not installed: \(outcome)")
            return
        }
        let long = snippet("Long") + "# " + String(repeating: "x", count: SnippetDetector.maximumSelectionLength)
        await #expect(throws: ExtensionLibrary.InstallError.selectionTooLong(long.count)) {
            try await library.install(.selectedText(long), review: Reviews().reviewer)
        }
    }

    @Test func invalidTextIsRefusedWithoutATrace() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        await #expect(throws: ExtensionLibrary.InstallError.self) {
            try await library.install(.selectedText("#popclip\nname: Nothing to do"), review: Reviews().reviewer)
        }
        #expect(Scratch.tree(scratch.paths.staging).isEmpty)
        #expect(Scratch.tree(scratch.paths.extensions).isEmpty)
        #expect(try await library.store.extensions().isEmpty)
    }

    @Test func cancellingTheReviewLeavesNoTrace() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let outcome = try await library.install(.selectedText(snippet()), review: Reviews { _ in .cancel }.reviewer)
        #expect(outcome == .cancelled)
        #expect(Scratch.tree(scratch.paths.staging).isEmpty)
        #expect(Scratch.tree(scratch.paths.extensions).isEmpty)
        #expect(try await library.store.extensions().isEmpty)
    }

    // MARK: SEC-8: collisions

    /// SEC-8a/d: the same declared identifier from a local source is a second, separate extension,
    /// and the first one is untouched.
    @Test func anIdentifierCollisionFromAnotherOriginInstallsSeparately() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let first = try scratch.package("One.popclipext", actions: ["https://one.example/?q=***"])
        let second = try scratch.package("Two.popclipext", actions: ["https://two.example/?q=***"])
        guard case .installed(let original, _) = try await library.install(.packageFolder(first), review: Reviews().reviewer) else {
            Issue.record("first did not install")
            return
        }
        let before = try #require(try await library.store.extension(original))

        let reviews = Reviews()
        guard case .installed(let separate, replaced: nil) = try await library.install(.packageFolder(second), review: reviews.reviewer) else {
            Issue.record("second did not install")
            return
        }
        #expect(separate != original)
        #expect(reviews.proposals.map(\.decision) == [.separate([.init(existing: original, kind: .identifier, allowsTrustTransition: true)])])
        #expect(try await library.store.extension(original) == before)
        let placed = try await library.store.placedActions()
        #expect(placed.map(\.extension.localIdentity) == [original, separate])
        #expect(Set(placed.map(\.extension.manifestIdentifier)) == ["com.example.translate"])
    }

    /// SEC-8b/c: a local package is its content, so one changed byte is a different extension that
    /// the user must review before it is installed; declining leaves the approved one as it was.
    @Test func changedLocalCodeIsReviewedBeforeItInstalls() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let package = try scratch.package(files: ["run.sh": "echo 1"])
        guard case .installed(let original, _) = try await library.install(.packageFolder(package), review: Reviews().reviewer) else {
            Issue.record("did not install")
            return
        }
        let before = try await library.store.extension(original)
        try Data("echo 2".utf8).write(to: package.appending(path: "run.sh"))

        let declining = Reviews { _ in .cancel }
        #expect(try await library.install(.packageFolder(package), review: declining.reviewer) == .cancelled)
        let shown = try #require(declining.proposals.first)
        #expect(shown.digest != before?.activeVersion)
        #expect(shown.provenance == .local(.packageFile, shown.digest))
        #expect(try await library.store.extensions().map(\.localIdentity) == [original])
        #expect(try await library.store.extension(original) == before)
    }

    /// EXM-2: a name collision never replaces anything, and is not offered as a replacement either.
    @Test func aNameCollisionNeverReplaces() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        guard case .installed(let original, _) = try await library.install(.selectedText(snippet("Search")), review: Reviews().reviewer) else {
            Issue.record("first did not install")
            return
        }
        let replacing = Reviews { _ in .replaceByTrustTransition(original) }
        await #expect(throws: ExtensionLibrary.InstallError.answerNotOffered) {
            try await library.install(.selectedText(snippet("Search", url: "https://other.example/?q=***")), review: replacing.reviewer)
        }
        #expect(replacing.proposals.map(\.decision) == [.separate([.init(existing: original, kind: .name, allowsTrustTransition: false)])])
        #expect(try await library.store.extensions().map(\.localIdentity) == [original])
        #expect(Scratch.tree(scratch.paths.staging).isEmpty)

        let second = try await library.install(.selectedText(snippet("Search", url: "https://other.example/?q=***")), review: Reviews().reviewer)
        guard case .installed(let separate, replaced: nil) = second else {
            Issue.record("second did not install: \(second)")
            return
        }
        #expect(Set(try await library.store.extensions().map(\.localIdentity)) == [original, separate])
    }

    /// SEC-8e: the user may choose to replace; the new identity takes the list places and the
    /// non-secret options, and the old identity and its files are gone.
    @Test func aTrustTransitionMovesPlacesAndOptionsToANewIdentity() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let first = try scratch.package("One.popclipext", actions: ["https://one.example/?q=***", "https://one.example/b?q=***"])
        guard case .installed(let old, _) = try await library.install(.packageFolder(first), review: Reviews().reviewer) else {
            Issue.record("first did not install")
            return
        }
        try await library.install(.selectedText(snippet("Other")), review: Reviews().reviewer)
        let oldRecord = try #require(try await library.store.extension(old))
        let oldFolder = try #require(library.folder(for: oldRecord))
        let oldInstance = try #require(try await library.store.instances(of: old).first)
        try await library.store.setOptionValue("de", for: "language", of: oldInstance.id)
        let before = try await library.store.placedActions()

        let second = try scratch.package("Two.popclipext", actions: ["https://two.example/?q=***"])
        let outcome = try await library.install(.packageFolder(second), review: Reviews { _ in .replaceByTrustTransition(old) }.reviewer)
        guard case .installed(let new, replaced: old) = outcome else {
            Issue.record("expected a transition, got \(outcome)")
            return
        }
        #expect(new != old)
        #expect(try await library.store.extension(old) == nil)
        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))

        let after = try await library.store.placedActions()
        // `a0` keeps its item and its place ahead of Other; `a1` is gone from the new version.
        #expect(after.map(\.item.id) == [before[0].item.id, before[2].item.id])
        #expect(after[0].extension.localIdentity == new)
        let newInstance = try #require(try await library.store.instances(of: new).first)
        #expect(newInstance.id != oldInstance.id)
        #expect(try await library.store.optionValues(of: newInstance.id) == ["language": "de"])
        #expect(try await library.store.optionValues(of: oldInstance.id).isEmpty)
    }

    // MARK: EXM-9

    @Test func deletingTheLastActionUninstalls() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        let package = try scratch.package(actions: ["https://example.com/a?q=***", "https://example.com/b?q=***"])
        guard case .installed(let identity, _) = try await library.install(.packageFolder(package), review: Reviews().reviewer) else {
            Issue.record("did not install")
            return
        }
        let record = try #require(try await library.store.extension(identity))
        let folder = try #require(library.folder(for: record))
        let items = try await library.store.placedActions()

        #expect(try await library.deleteListItem(items[0].item.id).uninstalled == nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        #expect(try await library.deleteListItem(items[1].item.id).uninstalled == identity)
        #expect(try await library.store.extension(identity) == nil)
        #expect(Scratch.tree(scratch.paths.extensions).isEmpty)
        // The instance is a tombstone, not a gap (SYN-1).
        #expect(try await library.store.instances(of: identity, includingDeleted: true).allSatisfy { $0.deletedAt != nil })
    }

    // MARK: Killed installs

    /// The done-when: a kill at any point of an install leaves, after `recover()`, exactly what was
    /// there before it started.
    @Test(arguments: ExtensionLibrary.Checkpoint.allCases)
    func aKilledInstallLeavesNoTrace(at point: ExtensionLibrary.Checkpoint) async throws {
        let scratch = try Scratch()
        let snapshot = scratch.root.appending(path: "Killed", directoryHint: .isDirectory)
        let paths = scratch.paths
        let armed = Mutex(false)
        let library = try ExtensionLibrary(paths: paths) { reached in
            // What a kill at this instant would leave on disk: a copy of everything, database included.
            if reached == point, armed.withLock({ $0 }) {
                try? FileManager.default.copyItem(at: paths.root, to: snapshot)
            }
        }
        try await library.install(.selectedText(snippet("Existing")), review: Reviews().reviewer)
        armed.withLock { $0 = true }
        let before = try await library.store.extensions()
        let treeBefore = Scratch.tree(paths.extensions)

        try await library.install(.packageFolder(try scratch.package()), review: Reviews().reviewer)

        let relaunched = try ExtensionLibrary(paths: ExtensionLibrary.Paths(root: snapshot))
        let recovery = try await relaunched.recover()
        #expect(Scratch.tree(relaunched.paths.staging).isEmpty)
        if point == .committed {
            // The commit happened: the install is whole, and nothing is orphaned.
            #expect(recovery.orphaned.isEmpty)
            #expect(try await relaunched.store.extensions().count == 2)
        } else {
            #expect(try await relaunched.store.extensions() == before)
            #expect(Scratch.tree(relaunched.paths.extensions) == treeBefore)
            #expect(recovery.staged + recovery.orphaned.count == 1)
        }
    }

    @Test func recoveryRemovesFoldersNoRowPointsAt() async throws {
        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        try await library.install(.selectedText(snippet()), review: Reviews().reviewer)
        let stray = scratch.paths.extensions.appending(path: "\(LocalIdentity())/abc")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.paths.staging.appending(path: "leftover"), withIntermediateDirectories: true)

        let recovery = try await library.recover()
        #expect(recovery.staged == 1)
        #expect(recovery.orphaned.count == 1)
        #expect(!FileManager.default.fileExists(atPath: stray.deletingLastPathComponent().path))
        #expect(try await library.store.versionFolders().count == 1)
    }
}
