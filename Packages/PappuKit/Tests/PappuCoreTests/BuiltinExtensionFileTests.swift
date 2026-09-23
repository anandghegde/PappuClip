import Foundation
import PappuCore
import PappuDevTools
import Testing

/// The two documents the built-ins are made of: `Resources/BuiltinExtensions/` and
/// `Resources/search-engines.json` (PRD §7.4, architecture §19 item 2).
///
/// Read from the repository rather than from a bundle, because there is no app bundle to copy them
/// into yet. What is asserted is what the PRD settles — which actions exist, when each is shown, what
/// the presets are — and not the things that are data: an SF Symbol's exact name, an engine's exact
/// query parameter.
@Suite struct BuiltinExtensionFileTests {
    static func root() throws -> URL {
        try RepositoryRoot.find(from: URL(filePath: #filePath))
    }

    static func directory() throws -> URL {
        try root().appending(path: "Resources/" + BuiltinExtensions.directoryName)
    }

    static func manifests() throws -> [ExtensionManifest] {
        try BuiltinExtensions.load(from: directory())
    }

    static func engines() throws -> SearchEngines {
        try SearchEngines.load(from: root().appending(path: "Resources/" + SearchEngines.fileName))
    }

    // MARK: The five files

    /// PRD §7.4: exactly five are P0, and all five ship in M1. The other three are M4 and are
    /// deliberately not here.
    @Test func allFiveShippedBuiltinsLoadAndValidateAsAppBundleExtensions() throws {
        let manifests = try Self.manifests()
        #expect(manifests.count == 5)
        #expect(manifests.map(\.identifier) == [
            "app.pappuclip.builtin.cut",
            "app.pappuclip.builtin.copy",
            "app.pappuclip.builtin.paste",
            "app.pappuclip.builtin.search",
            "app.pappuclip.builtin.open-link",
        ])
        for manifest in manifests {
            #expect(throws: Never.self) { try manifest.validate(origin: .appBundle) }
        }
    }

    /// They are loaded in `BuiltinAction.allCases` order rather than by sorting a directory listing,
    /// because this is PRD §7.4's table order and a product decision, not a consequence of file names.
    @Test func theyLoadInTheOrderTheProductDecidedNotTheOrderTheFilesSortIn() throws {
        #expect(try Self.manifests().compactMap { $0.actions.first?.executor } == BuiltinAction.allCases.map(ActionExecutor.builtin))
    }

    /// Whatever else changes about them, this must not: a bundled built-in names the reserved
    /// executor, and nothing else in the world may.
    @Test func everyBuiltinNamesTheReservedExecutorAndIsRefusedFromAnywhereElse() throws {
        for manifest in try Self.manifests() {
            #expect(manifest.actions.allSatisfy { if case .builtin = $0.executor { true } else { false } })
            #expect(throws: ExtensionManifest.Invalid.self) { try manifest.validate(origin: .installed) }
        }
    }

    @Test func everyBuiltinHasAnEnglishNameAndDescriptionAndAnIcon() throws {
        for manifest in try Self.manifests() {
            #expect(!manifest.name.english.isEmpty, "\(manifest.identifier)")
            #expect(manifest.description?.english.isEmpty == false, "\(manifest.identifier)")
            #expect(manifest.icon.specifier != nil, "\(manifest.identifier)")
        }
    }

    /// A file that names one built-in and runs another would be a packaging mistake no per-file name
    /// could catch.
    @Test func aFileThatRunsSomethingOtherThanItsNameIsRefused() throws {
        let directory = try Self.directory()
        #expect(throws: BuiltinExtensions.LoadFailure.self) {
            try BuiltinExtensions.load(.paste, from: directory.appending(path: "copy.json"))
        }
    }

    @Test func aMissingFileIsANamedFailureRatherThanAShorterBar() throws {
        #expect(throws: BuiltinExtensions.LoadFailure.self) {
            try BuiltinExtensions.load(from: try Self.root().appending(path: "Resources/NotHere"))
        }
    }

    // MARK: What PRD §7.4 says each one is shown for

    /// The "Shown when" column of PRD §7.4, as the manifests spell it. Search's `!isurl` is the one
    /// worth reading twice: §7.4 says Search appears alongside Open Link *unless the selection is only
    /// a URL*, which is exactly a negated `isurl`.
    @Test func eachBuiltinRequiresWhatThePRDSaysItRequires() throws {
        let expected: [String: [String]] = [
            "app.pappuclip.builtin.cut": ["text", "cut"],
            "app.pappuclip.builtin.copy": ["text"],
            "app.pappuclip.builtin.paste": ["paste"],
            "app.pappuclip.builtin.search": ["text", "!isurl"],
            "app.pappuclip.builtin.open-link": ["urls"],
        ]
        for manifest in try Self.manifests() {
            let spellings = manifest.actions.flatMap { $0.requirements.map(\.spelling) }
            #expect(spellings == expected[manifest.identifier], "\(manifest.identifier)")
        }
    }

    /// ACT-3: the bar may appear with a caret and no selection, and Paste has to be reachable there.
    /// It is the one built-in whose requirements must *not* include `text`.
    @Test func pasteIsTheOneBuiltinThatDoesNotNeedASelection() throws {
        let paste = try #require(try Self.manifests().first { $0.identifier == "app.pappuclip.builtin.paste" })
        let facts = MatchingFacts(text: "", canPaste: true)
        #expect(ActionMatching.match(paste.actions[0], against: facts).isShown)
    }

    /// The other side of the same caret, and why Cut asks for `text` as well as `cut` even though an app
    /// that greys its own Cut item out would have said so: §7.4 is "there is a selection *and* Cut is
    /// available", the enablement is the other app's answer to give or get wrong, and the fallback that
    /// reads writability instead of the Edit menu knows nothing about the selection at all. A "Cut" on a
    /// bar with nothing selected would do nothing when pressed.
    @Test func cutIsNotOfferedAtACaretEvenWhenTheEditMenuSaysItIsAvailable() throws {
        let cut = try #require(try Self.manifests().first { $0.identifier == "app.pappuclip.builtin.cut" })
        #expect(!ActionMatching.match(cut.actions[0], against: MatchingFacts(text: "", canCut: true)).isShown)
        #expect(ActionMatching.match(cut.actions[0], against: MatchingFacts(text: "word", canCut: true)).isShown)
    }

    // MARK: The two native conditions

    @Test func pasteIsNotOfferedWhenTheClipboardHasNoText() {
        let facts = MatchingFacts(text: "hi", canPaste: true)
        #expect(BuiltinAction.paste.isOffered(for: facts, given: .init(clipboardHasText: true)))
        #expect(BuiltinAction.paste.isOffered(for: facts, given: .init(clipboardHasText: false)) == false)
    }

    @Test func searchIsNotOfferedForASelectionLongerThanItWillTake() {
        let conditions = BuiltinConditions()
        let long = MatchingFacts(text: String(repeating: "a", count: conditions.maximumSearchCharacters + 1))
        let atTheLimit = MatchingFacts(text: String(repeating: "a", count: conditions.maximumSearchCharacters))
        #expect(BuiltinAction.search.isOffered(for: atTheLimit, given: conditions))
        #expect(BuiltinAction.search.isOffered(for: long, given: conditions) == false)
    }

    /// Three of the five say everything they need to say in their files, which is the shape all of
    /// them should have once the public API can express them (M3, M4).
    @Test func cutCopyAndOpenLinkAddNothingNatively() {
        let facts = MatchingFacts(text: "hi")
        for builtin in [BuiltinAction.cut, .copy, .openLink] {
            #expect(builtin.isOffered(for: facts, given: .none), "\(builtin.rawValue)")
        }
    }

    // MARK: search-engines.json

    @Test func theShippedEngineListLoadsAtTheSchemaThisBuildReads() throws {
        let engines = try Self.engines()
        #expect(engines.schema == SearchEngines.supportedSchema)
        #expect(engines.sequence >= 1)
        #expect(engines.note != nil)
    }

    /// PRD §7.4 names all twelve by hand, and Google as the default.
    @Test func everyPresetThePRDNamesIsOnTheList() throws {
        let engines = try Self.engines()
        #expect(engines.engines.map(\.name) == [
            "Baidu", "Bing", "Brave", "DuckDuckGo", "Ecosia", "Google",
            "Kagi", "NAVER", "Startpage", "Yahoo", "Yahoo Japan", "Yandex",
        ])
        #expect(engines.preferred?.name == "Google")
    }

    @Test func everyPresetBuildsASearchURL() throws {
        for engine in try Self.engines().engines {
            let url = try #require(engine.url(searching: "swift"), "\(engine.id)")
            #expect(url.scheme == "https", "\(engine.id)")
            #expect(url.absoluteString.contains("swift"), "\(engine.id)")
        }
    }

    /// The term is data inside a query, so everything that could end the query is encoded. A
    /// `.urlQueryAllowed` set would leave `&` and `=` alone and let a selection add its own parameters.
    @Test func aTermThatLooksLikeAQueryIsEncodedRatherThanObeyed() throws {
        let google = try #require(try Self.engines()["google"])
        let url = try #require(google.url(searching: "a&b=c d/e?f#g"))
        #expect(url.absoluteString == "https://www.google.com/search?q=a%26b%3Dc%20d%2Fe%3Ff%23g")
        #expect(url.query == "q=a%26b%3Dc%20d%2Fe%3Ff%23g")
    }

    @Test func aTemplateWithNoPlaceholderIsNotASearch() {
        #expect(SearchEngine(id: "x", name: "X", template: "https://example.com/").url(searching: "swift") == nil)
    }

    /// Unlike the scheme list, the fallback here is a guess — and the comment on it says why. This
    /// test holds it to being a working one.
    @Test func theFallbackStillSearches() throws {
        #expect(SearchEngines.fallback.preferred?.url(searching: "swift") != nil)
    }
}
