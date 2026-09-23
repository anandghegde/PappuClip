import Foundation
import PappuCore
import PappuDevTools
import Testing

/// The corpus check's own rules: what counts as a package, and when the expected-failures list is
/// stale.
@Suite struct CorpusLoaderTests {
    static func corpus(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "pappu-corpus-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    @Test func packagesAndSnippetsAreFoundButNotFilesInsideAPackage() throws {
        let root = try Self.corpus([
            "a/Good.popclipext/Config.yaml": "name: Good\nurl: https://a.example",
            "a/Good.popclipext/Nested.popclipext/Config.yaml": "name: Nested\nurl: x",
            "b/Snippet.popcliptxt": "#popclip\nname: S\nurl: https://a.example",
            "b/readme.md": "not an extension",
        ])
        let paths = CorpusLoader.discover(in: root).map(\.lastPathComponent)
        #expect(paths == ["Good.popclipext", "Snippet.popcliptxt"])
    }

    @Test func theReportPassesOnlyWhenEveryFailureIsListedAndEveryListingFails() throws {
        let root = try Self.corpus([
            "Good.popclipext/Config.yaml": "name: Good\nurl: https://a.example",
            "Broken.popclipext/Config.json": "",
            "Module.popclipext/Config.js": "// #popclip\n// name: M\nexport default {};",
        ])
        let unlisted = CorpusLoader.run(corpus: root, expectedFailures: [:])
        #expect(unlisted.loaded == 1)
        #expect(unlisted.needsJavaScript == 1)
        #expect(unlisted.unexpectedFailures.map(\.path) == ["Broken.popclipext"])
        #expect(!unlisted.passed)

        #expect(CorpusLoader.run(corpus: root, expectedFailures: ["Broken.popclipext": "empty"]).passed)

        let stale = CorpusLoader.run(corpus: root, expectedFailures: ["Broken.popclipext": "empty", "Good.popclipext": "was broken"])
        #expect(stale.staleExpectations == ["Good.popclipext"])
        #expect(!stale.passed)
    }

    @Test func theExpectedFailuresFileIsPathsWithReasons() {
        let parsed = CorpusLoader.parseExpectedFailures("""
        # a comment

        contrib/A.popclipext   # empty config
        contrib/B.popclipext
        """)
        #expect(parsed == ["contrib/A.popclipext": "empty config", "contrib/B.popclipext": ""])
    }
}
