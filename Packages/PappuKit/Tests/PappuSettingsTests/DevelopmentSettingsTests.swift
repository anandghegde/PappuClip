import Foundation
import PappuCore
import PappuExtensions
@testable import PappuSettings
import PappuTestSupport
import Testing

/// DEV-1: Settings → Developer, the development review and the two developer switches.
@MainActor @Suite struct DevelopmentSettingsTests {
    private let scratch: LibraryScratch

    init() throws {
        scratch = try LibraryScratch()
    }

    private static let search = #"{"name": "Dev", "identifier": "com.example.dev", "actions": [{"title": "Search", "url": "https://example.com/?q=***"}]}"#
    private static let searchAndShell = #"{"name": "Dev", "identifier": "com.example.dev", "actions": [{"title": "Search", "url": "https://example.com/?q=***"}, {"title": "Shout", "shellScript": "echo hi"}]}"#

    /// A package folder the developer is working on.
    private func folder(_ config: String) throws -> URL {
        let url = scratch.root.appending(path: "Work/Dev.popclipext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: url.appending(path: "Config.json"))
        return url
    }

    /// Records every proposal and every change, answering each review with `answer`.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _proposals: [ExtensionLibrary.Proposal] = []
        var answer: ExtensionLibrary.Consent = .install
        var changes: [DevelopmentModel.Change] = []

        var proposals: [ExtensionLibrary.Proposal] { lock.withLock { _proposals } }

        var reviewer: ExtensionLibrary.Reviewer {
            { proposal in
                self.lock.withLock {
                    self._proposals.append(proposal)
                    return self.answer
                }
            }
        }
    }

    private func model(_ recorder: Recorder, storage: FakeSettingsStorage = FakeSettingsStorage()) -> DevelopmentModel {
        DevelopmentModel(
            library: scratch.library,
            preferences: DeveloperPreferences(storage: storage),
            locale: Locale(identifier: "en"),
            review: recorder.reviewer,
            changed: { change in recorder.changes.append(change) }
        )
    }

    // MARK: Strings

    @Test func everyDeveloperStringIsInItsTable() {
        let missing = "\u{1}missing"
        for key in DeveloperStrings.all {
            #expect(
                DeveloperStrings.bundle.localizedString(forKey: key, value: missing, table: DeveloperStrings.table) != missing,
                "\(key) is not in Developer.strings"
            )
        }
        #expect(Set(DeveloperStrings.all).count == DeveloperStrings.all.count)
        #expect(DeveloperStrings.reloadLabel("Dev").contains("Dev"))
        #expect(DeveloperStrings.removeLabel("Dev").contains("Dev"))
    }

    // MARK: The review

    /// SEC-8b holds for development code: the review says it is an unsigned, unreviewed folder.
    @Test func theReviewSaysTheCodeIsAnUnreviewedDevelopmentFolder() async throws {
        let recorder = Recorder()
        recorder.answer = .cancel
        _ = try await scratch.library.approveDevelopmentFolder(try folder(Self.search), review: recorder.reviewer)
        let proposal = try #require(recorder.proposals.first)
        let review = ConsentPresenter.review(proposal)
        #expect(review.provenance == DeveloperStrings.consentProvenance)
        #expect(review.choices == [.install, .cancel])
    }

    /// A reload that asks for more is an update of the same identity, never a replacement of another.
    @Test func aWidenedReloadOffersOnlyUpdateOrCancel() async throws {
        let recorder = Recorder()
        let model = model(recorder)
        let url = try folder(Self.search)
        await model.add(url)
        let identity = try #require(model.rows.first?.identity)

        try Data(Self.searchAndShell.utf8).write(to: url.appending(path: "Config.json"))
        recorder.answer = .cancel
        await model.reload(identity)

        let proposal = try #require(recorder.proposals.last)
        let review = ConsentPresenter.review(proposal)
        #expect(review.choices == [.update, .cancel])
        #expect(review.gates.map(\.capability) == [.script])
        #expect(review.provenance == DeveloperStrings.consentProvenance)
        #expect(model.rows.first?.status == DeveloperStrings.cancelled)
    }

    // MARK: The model

    @Test func addingAFolderTurnsDevelopmentModeOnAndReportsTheChange() async throws {
        let recorder = Recorder()
        let model = model(recorder)
        #expect(!model.isActive)

        await model.add(try folder(Self.search))
        let row = try #require(model.rows.first)
        #expect(model.isActive)
        #expect(row.name == "Dev")
        #expect(row.path.hasSuffix("Dev.popclipext"))
        #expect(recorder.changes == [.updated(row.identity)])
        #expect(model.failure == nil)
    }

    @Test func aCancelledReviewAddsNothing() async throws {
        let recorder = Recorder()
        recorder.answer = .cancel
        let model = model(recorder)
        await model.add(try folder(Self.search))
        #expect(!model.isActive)
        #expect(recorder.changes.isEmpty)
    }

    @Test func reloadSaysWhatItDidAndOnlyRebuildsWhenSomethingLoaded() async throws {
        let recorder = Recorder()
        let model = model(recorder)
        let url = try folder(Self.search)
        await model.add(url)
        let identity = try #require(model.rows.first?.identity)

        await model.reload(identity)
        #expect(model.rows.first?.status == DeveloperStrings.unchanged)
        #expect(recorder.changes == [.updated(identity)])

        try Data(Self.search.replacingOccurrences(of: "Search", with: "Find").utf8).write(to: url.appending(path: "Config.json"))
        await model.reload(identity)
        #expect(model.rows.first?.status == DeveloperStrings.reloaded)
        #expect(recorder.changes == [.updated(identity), .updated(identity)])
        #expect(recorder.proposals.count == 1, "a reload within what was approved is not reviewed again")
    }

    @Test func removingTheLastFolderTurnsDevelopmentModeOff() async throws {
        let recorder = Recorder()
        let model = model(recorder)
        await model.add(try folder(Self.search))
        let identity = try #require(model.rows.first?.identity)

        await model.remove(identity)
        #expect(!model.isActive)
        #expect(recorder.changes.last == .removed(identity))
    }

    /// Uninstalling the development extension from Settings → Extensions turns development mode off at
    /// once, so the menu's "Development Mode On" line does not outlive it.
    @Test func uninstallingTheDevelopmentExtensionElsewhereTurnsDevelopmentModeOff() async throws {
        let recorder = Recorder()
        let extensions = ExtensionsModel(
            library: scratch.library, secrets: InMemorySecretStore(), locale: Locale(identifier: "en")
        ) { _ in }
        let development = model(recorder)
        extensions.development = development
        await development.add(try folder(Self.search))
        let identity = try #require(development.rows.first?.identity)
        #expect(development.isActive)

        await extensions.uninstall(identity)
        #expect(!development.isActive)
        #expect(development.rows.isEmpty)
    }

    /// Both switches start off, persist, and tell the app to update the helper.
    @Test func theSwitchesStartOffAndPersist() async {
        let storage = FakeSettingsStorage()
        let recorder = Recorder()
        let model = model(recorder, storage: storage)
        #expect(!model.verboseLogging)
        #expect(!model.webInspector)

        await model.setVerboseLogging(true)
        await model.setWebInspector(true)
        #expect(recorder.changes == [.preferences, .preferences])

        let reread = DeveloperPreferences(storage: storage)
        #expect(reread.verboseLogging)
        #expect(reread.webInspector)
    }

    @Test func everyReloadOutcomeHasAStatus() {
        #expect(DevelopmentModel.status(for: .unchanged) == DeveloperStrings.unchanged)
        #expect(DevelopmentModel.status(for: .reloaded) == DeveloperStrings.reloaded)
        #expect(DevelopmentModel.status(for: .approved) == DeveloperStrings.approved)
        #expect(DevelopmentModel.status(for: .cancelled) == DeveloperStrings.cancelled)
    }
}
