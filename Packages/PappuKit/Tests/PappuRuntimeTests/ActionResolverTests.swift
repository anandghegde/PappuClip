import Foundation
import PappuAnalysis
import PappuCore
import PappuRuntime
import Testing

/// **FLT-1: only actions relevant to the current selection and context are shown.**
///
/// `ActionMatchingTests` covers §8.5 rule by rule over facts written by hand. This suite covers the
/// thing above it: the real five built-ins, loaded from the files that ship, resolved against
/// analyses and contexts of the shape the probe produces — which is the sentence FLT-1 actually makes
/// a claim about.
@Suite struct ActionResolverTests {
    static let resolver = ActionResolver()

    static func catalog() throws -> ActionCatalog {
        ActionCatalog(entries: try BuiltinExtensions.entries(from: builtinsDirectory()))
    }

    /// The repository's `Resources/`, found by walking up from this file. There is no app bundle yet.
    static func builtinsDirectory() throws -> URL {
        var candidate = URL(filePath: #filePath).standardizedFileURL
        while candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
            let resources = candidate.appending(path: "Resources/" + BuiltinExtensions.directoryName)
            if FileManager.default.fileExists(atPath: resources.path) { return resources }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func app(_ bundleID: String? = "com.example.Editor") -> AppIdentity {
        AppIdentity(pid: 42, bundleID: bundleID, name: "Editor")
    }

    static func context(
        canCut: Bool = false,
        canCopy: Bool = false,
        canPaste: Bool = false,
        hasFormatting: Bool = false,
        bundleID: String? = "com.example.Editor"
    ) -> SelectionContext {
        SelectionContext(
            app: app(bundleID),
            editability: Editability(isEditable: canCut || canPaste, source: .settableSelectedText),
            canCut: canCut,
            canCopy: canCopy,
            canPaste: canPaste,
            hasFormatting: hasFormatting
        )
    }

    static func selection(_ text: String, _ detections: [Detection] = []) -> AnalyzedSelection {
        AnalyzedSelection(text: text, detections: detections)
    }

    static func detection(_ kind: Detection.Kind, _ value: String, at location: Int = 0) -> Detection {
        Detection(kind: kind, span: TextSpan(location: location, length: value.utf16.count), value: value)
    }

    static func titles(_ resolution: ActionResolver.Resolution) -> [String] {
        resolution.actions.map { $0.action.title.text(for: Locale(identifier: "en_US")) }
    }

    // MARK: The five built-ins over the shapes PRD §7.4 names

    /// Read-only prose in a web page: there is a selection, and nothing may be written.
    @Test func readOnlyTextOffersCopyAndSearchOnly() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection("some prose"),
            context: Self.context(canCopy: true),
            conditions: .init(clipboardHasText: true)
        )
        #expect(Self.titles(resolution) == ["Copy", "Search"])
    }

    /// FLT-6 again, from the other side: an editable field offers everything the clipboard allows.
    @Test func editableTextOffersCutCopyPasteAndSearch() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection("some prose"),
            context: Self.context(canCut: true, canCopy: true, canPaste: true),
            conditions: .init(clipboardHasText: true)
        )
        #expect(Self.titles(resolution) == ["Cut", "Copy", "Paste", "Search"])
    }

    /// PRD §7.4: Search is shown alongside Open Link *unless the selection is only a URL*.
    @Test func aSelectionThatIsOnlyALinkOffersOpenLinkWithoutSearch() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection("https://example.com", [Self.detection(.url, "https://example.com")]),
            context: Self.context(canCopy: true)
        )
        #expect(Self.titles(resolution) == ["Copy", "Open Link"])
    }

    @Test func aSentenceWithALinkInItOffersBothSearchAndOpenLink() throws {
        let text = "see https://example.com today"
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection(text, [Self.detection(.url, "https://example.com", at: 4)]),
            context: Self.context(canCopy: true)
        )
        #expect(Self.titles(resolution) == ["Copy", "Search", "Open Link"])
    }

    /// PRD §7.4 says Open Link handles app schemes too, and the analyser reports them as a different
    /// detection kind. The pipeline flattens both to one, which is what makes `urls` mean "a link".
    @Test func anAppSchemeIsALinkToo() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection("omnifocus:///task/1", [Self.detection(.nonHTTPURL, "omnifocus:///task/1")]),
            context: Self.context(canCopy: true)
        )
        #expect(Self.titles(resolution).contains("Open Link"))
    }

    /// ACT-3: the bar may appear on a caret with nothing selected. Paste is the only thing there.
    @Test func aCaretWithNoSelectionOffersPasteAlone() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection(""),
            context: Self.context(canPaste: true),
            conditions: .init(clipboardHasText: true)
        )
        #expect(Self.titles(resolution) == ["Paste"])
    }

    @Test func pasteIsNotOfferedWhenTheClipboardIsEmpty() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection("prose"),
            context: Self.context(canCut: true, canCopy: true, canPaste: true),
            conditions: .init(clipboardHasText: false)
        )
        #expect(Self.titles(resolution).contains("Paste") == false)
        let key = ActionKey(extensionIdentifier: "app.pappuclip.builtin.paste", action: "paste")
        #expect(resolution.refusals[key] == .builtinCondition(.paste))
    }

    @Test func searchIsNotOfferedForAWholeDocument() throws {
        let long = String(repeating: "word ", count: 500)
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection(long),
            context: Self.context(canCopy: true)
        )
        #expect(Self.titles(resolution) == ["Copy"])
        let key = ActionKey(extensionIdentifier: "app.pappuclip.builtin.search", action: "search")
        #expect(resolution.refusals[key] == .builtinCondition(.search))
    }

    /// A selection with nothing available anywhere shows nothing rather than a bar of dead buttons.
    @Test func aContextThatAnswersNothingShowsCopyAndSearchAndNoMore() throws {
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection("prose"),
            context: Self.context()
        )
        #expect(Self.titles(resolution) == ["Copy", "Search"])
    }

    // MARK: Narrowing carries through

    @Test func openLinkActsOnTheSelectionAndSearchOnTheTextItself() throws {
        let text = "see https://example.com today"
        let resolution = Self.resolver.resolve(
            try Self.catalog(),
            selection: Self.selection(text, [Self.detection(.url, "https://example.com", at: 4)]),
            context: Self.context()
        )
        // `urls` is plural and does not narrow: Open Link wants every address, not the first.
        let openLink = try #require(resolution.match(for: .init(extensionIdentifier: "app.pappuclip.builtin.open-link", action: "open-link")))
        #expect(openLink.isNarrowed == false)
        #expect(openLink.value == text)
        let search = try #require(resolution.match(for: .init(extensionIdentifier: "app.pappuclip.builtin.search", action: "search")))
        #expect(search.value == text)
        #expect(search.fullText == text)
    }

    /// §8.5 step 3, through the whole stack: an action asking for `url` is handed the address and
    /// still has the sentence it came from.
    @Test func aNarrowingActionGetsTheDetectionAndKeepsTheSelection() throws {
        let text = "write to ana@example.com now"
        let catalog = ActionCatalog(entries: [
            .init(
                manifest: ExtensionManifest(
                    name: "Mail",
                    identifier: "com.example.mail",
                    actions: [ActionManifest(requirements: [ActionRequirement(parsing: "email")], executor: .builtin(.copy))]
                ),
                origin: .appBundle
            )
        ])
        let resolution = Self.resolver.resolve(
            catalog,
            selection: Self.selection(text, [Self.detection(.email, "ana@example.com", at: 9)]),
            context: Self.context()
        )
        let match = try #require(resolution.actions.first?.match)
        #expect(match.narrowing == .email)
        #expect(match.value == "ana@example.com")
        #expect(match.span == TextSpan(location: 9, length: 15))
        #expect(match.fullText == text)
    }

    // MARK: Order, disabling and refusals

    /// The resolver never reorders: the list it returns is the user's order, filtered (ALM-3).
    @Test func theResolutionIsInCatalogOrder() throws {
        let catalog = try Self.catalog()
        let resolution = Self.resolver.resolve(
            catalog,
            selection: Self.selection("prose"),
            context: Self.context(canCut: true, canCopy: true, canPaste: true),
            conditions: .init(clipboardHasText: true)
        )
        let positions = resolution.actions.compactMap { resolved in
            catalog.actions.firstIndex { $0.key == resolved.key }
        }
        #expect(positions == positions.sorted())
    }

    @Test func aDisabledExtensionIsNotOfferedAndSaysSo() throws {
        var entries = try BuiltinExtensions.entries(from: Self.builtinsDirectory())
        entries[1].isEnabled = false // Copy
        let resolution = Self.resolver.resolve(
            ActionCatalog(entries: entries),
            selection: Self.selection("prose"),
            context: Self.context()
        )
        #expect(Self.titles(resolution) == ["Search"])
        #expect(resolution.refusals[.init(extensionIdentifier: "app.pappuclip.builtin.copy", action: "copy")] == .disabled)
    }

    /// DIA-2's inspector answers "why is Cut not here", and this is the only moment the answer exists.
    /// DIA-4: the answer is keys and reasons, never the selection's text.
    @Test func everyActionThatIsNotShownSaysWhy() throws {
        let catalog = try Self.catalog()
        let resolution = Self.resolver.resolve(
            catalog,
            selection: Self.selection("prose"),
            context: Self.context(canCopy: true)
        )
        #expect(resolution.actions.count + resolution.refusals.count == catalog.count)
        #expect(resolution.refusals[.init(extensionIdentifier: "app.pappuclip.builtin.cut", action: "cut")]
            == .filtered(.requirementUnmet(ActionRequirement(.cut))))
    }

    // MARK: App rules (ALM-8's static half)

    @Test func anActionRestrictedToAnAppIsOnlyResolvedThere() throws {
        let catalog = ActionCatalog(entries: [
            .init(
                manifest: ExtensionManifest(
                    name: "Safari Only",
                    identifier: "com.example.safari",
                    actions: [ActionManifest(requiredApps: ["com.apple.Safari"], executor: .builtin(.copy))]
                ),
                origin: .appBundle
            )
        ])
        #expect(Self.resolver.resolve(catalog, selection: Self.selection("x"), context: Self.context()).isEmpty)
        #expect(Self.resolver.resolve(catalog, selection: Self.selection("x"), context: Self.context(bundleID: "com.apple.Safari")).isEmpty == false)
    }
}

/// An action the manifest reads but no runner can run yet is absent, with a reason — never a button
/// that does nothing. The ones that have a runner are on the bar.
@Suite struct ActionResolverRunnerTests {
    private func resolve(_ body: String) throws -> (ActionResolver.Resolution, ActionExecutor) {
        let manifest = try ExtensionLoader.loadSnippet("#popclip\nname: Shout\nidentifier: com.example.shout\n\(body)").manifest
        let catalog = ActionCatalog(entries: [.init(manifest: manifest, origin: .installed)])
        let resolution = ActionResolver().resolve(
            catalog,
            selection: AnalyzedSelection(text: "hello", detections: []),
            context: SelectionContext(
                app: AppIdentity(pid: 42, bundleID: "com.example.Editor", name: "Editor"),
                editability: Editability(isEditable: false, source: .settableSelectedText),
                canCut: false,
                canCopy: true,
                canPaste: false,
                hasFormatting: false
            )
        )
        return (resolution, manifest.actions[0].executor)
    }

    @Test func anActionWithNoRunnerIsRefusedByName() throws {
        let (resolution, executor) = try resolve("javascript: return popclip.input.text")
        #expect(resolution.actions.isEmpty)
        #expect(Array(resolution.refusals.values) == [.noRunner(executor)])
    }

    @Test(arguments: [
        "keyCombo: command b",
        "url: https://example.com/?q=***",
        "shortcutName: Shout",
        "serviceName: Make Sticky",
        "applescript: return \"{popclip text}\"",
        "shellScript: echo hi",
    ])
    func everyOtherExecutorHasARunner(_ body: String) throws {
        let (resolution, _) = try resolve(body)
        #expect(resolution.actions.count == 1)
        #expect(resolution.refusals.isEmpty)
    }
}
