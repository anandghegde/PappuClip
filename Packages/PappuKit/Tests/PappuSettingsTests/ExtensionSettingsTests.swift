import Foundation
import PappuCore
import PappuExtensions
@testable import PappuSettings
import Testing

/// A library in a folder of its own, removed with the test.
final class LibraryScratch: @unchecked Sendable {
    let root: URL
    let library: ExtensionLibrary

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "pappu-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        library = try ExtensionLibrary(paths: ExtensionLibrary.Paths(root: root))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Installs `text` as selected text, answering the review with `consent`.
    @discardableResult
    func install(_ text: String, consent: ExtensionLibrary.Consent = .install) async throws -> LocalIdentity {
        guard case .installed(let identity, _) = try await library.install(.selectedText(text), review: { _ in consent }) else {
            throw CocoaError(.featureUnsupported)
        }
        return identity
    }

    /// The proposal the review would be shown for `text`, without installing it.
    func proposal(_ text: String) async throws -> ExtensionLibrary.Proposal {
        let seen = Seen()
        _ = try await library.install(.selectedText(text)) { proposal in
            seen.set(proposal)
            return .cancel
        }
        return try #require(seen.value)
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var proposal: ExtensionLibrary.Proposal?
        var value: ExtensionLibrary.Proposal? { lock.withLock { proposal } }
        func set(_ proposal: ExtensionLibrary.Proposal) { lock.withLock { self.proposal = proposal } }
    }
}

enum Snippets {
    static let search = "#popclip\nname: Search\nidentifier: com.example.search\nurl: https://example.com/?q=***\n"
    static let shell = "#popclip\nname: Shout\nidentifier: com.example.shout\nshellScript: echo hi\n"
    static let keyed = """
    #popclip
    name: Keyed
    identifier: com.example.keyed
    options:
      - identifier: apikey
        type: secret
        label: API Key
      - identifier: lang
        type: string
        label: Language
        default value: en
    url: https://example.com/?q=***&l={popclip option lang}
    """
}

@Suite struct ExtensionStringsTests {
    @Test func everyStringTheReviewAndExtensionInfoSayIsInTheCatalogue() {
        let bundle = ExtensionStrings.bundle
        for key in ExtensionStrings.all {
            let missing = "\u{1}missing\u{1}"
            #expect(
                bundle.localizedString(forKey: key, value: missing, table: nil) != missing,
                "\(key) has no entry in Localizable.strings"
            )
        }
    }

    @Test func argumentsAreSpliced() {
        #expect(ExtensionStrings.installTitle("Translate") == "Install \u{201C}Translate\u{201D}?")
        #expect(ExtensionStrings.sendsTextToHost("example.com").contains("example.com"))
    }
}

/// EXM-5a–d: what the install review says and offers.
@Suite struct ConsentPresenterTests {
    private let scratch: LibraryScratch

    init() throws {
        scratch = try LibraryScratch()
    }

    /// EXM-5c: the listed capabilities are sentences read together, with one Install.
    @Test func aListedOnlyExtensionIsOneConfirmation() async throws {
        let review = ConsentPresenter.review(try await scratch.proposal(Snippets.search))
        #expect(review.title == ExtensionStrings.installTitle("Search"))
        #expect(review.listed.contains(ExtensionStrings.sendsTextToHost("example.com")))
        #expect(review.gates.isEmpty)
        #expect(review.choices == [.install, .cancel])
    }

    /// EXM-5d: each gate is a switch, and the review carries no way to start one on.
    @Test func aGatedCapabilityIsASwitch() async throws {
        let review = ConsentPresenter.review(try await scratch.proposal(Snippets.shell))
        #expect(review.gates.map(\.capability) == [.script])
        #expect(review.gates.first?.sentence == ExtensionStrings.gateScript)
    }

    /// SEC-8b: local code says it is local.
    @Test func selectedTextIsSaidToComeFromThisMac() async throws {
        let review = ConsentPresenter.review(try await scratch.proposal(Snippets.search))
        #expect(review.provenance == ExtensionStrings.fromThisMac)
    }

    @Test func aCollisionIsNamedAndInstallsBesideIt() async throws {
        try await scratch.install(Snippets.search)
        let other = Snippets.search.replacingOccurrences(of: "example.com", with: "example.org")
        let review = ConsentPresenter.review(try await scratch.proposal(other)) { _ in "Old Search" }
        #expect(review.collisions == [ExtensionStrings.collision("Old Search")])
        #expect(review.choices.first == .install)
        #expect(review.choices.last == .cancel)
    }

    /// EXM-5d: the answer grants what was switched on and nothing more; Cancel grants nothing.
    @Test func theAnswerCarriesOnlyTheSwitchesTurnedOn() {
        #expect(ConsentPresenter.consent(.install, granting: []) == .install)
        #expect(ConsentPresenter.consent(.install, granting: [.script]) == .install(granting: [.script]))
        #expect(ConsentPresenter.consent(.cancel, granting: [.script]) == .cancel)
        #expect(ConsentPresenter.consent(.installSeparately, granting: []) == .installSeparately)
    }

    @Test func everyCapabilityHasASentence() {
        for gate in GatedCapability.allCases {
            #expect(!ConsentPresenter.sentence(for: gate).isEmpty)
        }
        let apps = ConsentPresenter.sentences(for: CapabilitySet(controlledApps: ["Mail", "Notes"]))
        #expect(apps.count == 1)
        #expect(apps.first?.contains("Mail") == true)
    }
}

/// SEC-4a–b and ALM-6: Extension Info and the options sheet.
@MainActor
@Suite struct ExtensionsModelTests {
    private let scratch: LibraryScratch
    private let secrets = InMemorySecretStore()

    init() throws {
        scratch = try LibraryScratch()
    }

    private func model(recording changes: Changes = Changes()) -> ExtensionsModel {
        ExtensionsModel(library: scratch.library, secrets: secrets, locale: Locale(identifier: "en")) { change in
            changes.all.append(change)
        }
    }

    @MainActor final class Changes {
        var all: [ExtensionsModel.Change] = []
    }

    @Test func anInstalledExtensionIsListedAsApproved() async throws {
        let identity = try await scratch.install(Snippets.search)
        let model = model()
        await model.refresh()
        let row = try #require(model.row(identity))
        #expect(row.name == "Search")
        #expect(row.isApproved)
        #expect(row.state == .enabled)
    }

    /// SEC-4a: the gate is listed, off, and switching it on grants it.
    @Test func aGateStartsOffAndCanBeGranted() async throws {
        let identity = try await scratch.install(Snippets.shell)
        let model = model()
        await model.refresh()
        #expect(model.row(identity)?.gates.map(\.isGranted) == [false])
        await model.setGate(.script, granted: true, of: identity)
        #expect(model.row(identity)?.gates.map(\.isGranted) == [true])
        #expect(try await scratch.library.store.approval(for: identity)?.gates == [.script])
    }

    /// SEC-4b: revoking removes the approval and is announced as a revocation, which is what the app
    /// turns into cancelling the extension's running work.
    @Test func revokingIsAnnouncedAndTakesTheApprovalAway() async throws {
        let identity = try await scratch.install(Snippets.search)
        let changes = Changes()
        let model = model(recording: changes)
        await model.refresh()
        await model.revoke(identity)
        #expect(changes.all == [.revoked(identity)])
        #expect(try await scratch.library.store.approval(for: identity) == nil)
        #expect(model.row(identity)?.isApproved == false)
    }

    /// Turning a gate off is a revocation too: the extension may be using it now.
    @Test func turningAGateOffIsARevocation() async throws {
        let identity = try await scratch.install(Snippets.shell, consent: .install(granting: [.script]))
        let changes = Changes()
        let model = model(recording: changes)
        await model.refresh()
        await model.setGate(.script, granted: false, of: identity)
        #expect(changes.all == [.revoked(identity)])
        #expect(try await scratch.library.store.approval(for: identity)?.gates == [])
    }

    /// Approve does not switch gates on (EXM-5d).
    @Test func approvingAgainKeepsGatesOff() async throws {
        let identity = try await scratch.install(Snippets.shell)
        let model = model()
        await model.refresh()
        await model.revoke(identity)
        await model.approve(identity)
        #expect(try await scratch.library.store.approval(for: identity)?.gates == [])
    }

    /// ALM-6: no options is an empty list, which the sheet says in words.
    @Test func anExtensionWithoutOptionsHasNone() async throws {
        let identity = try await scratch.install(Snippets.search)
        let model = model()
        await model.refresh()
        #expect(model.row(identity)?.options == [])
        #expect(model.row(owner: identity.description)?.identity == identity)
    }

    /// §8.9 and SEC-3: a string goes to the store, a secret to the secret store and never the store.
    @Test func optionsAreGeneratedAndSecretsKeptApart() async throws {
        let identity = try await scratch.install(Snippets.keyed)
        let model = model()
        await model.refresh()
        let options = try #require(model.row(identity)?.options)
        #expect(options.map(\.control) == [.secret, .text(multiline: false)])
        #expect(options.last?.value == "en")

        await model.setOption("fr", for: "lang", of: identity)
        await model.setOption("sk-123", for: "apikey", of: identity)
        #expect(model.row(identity)?.options.map(\.value) == ["sk-123", "fr"])
        #expect(secrets.count == 1)
        let instance = try #require(try await scratch.library.store.instances(of: identity).first?.id)
        #expect(try await scratch.library.store.optionValues(of: instance) == ["lang": "fr"])
    }

    /// SEC-3: an uninstalled extension's secrets go with it.
    @Test func uninstallingRemovesSecrets() async throws {
        let identity = try await scratch.install(Snippets.keyed)
        let changes = Changes()
        let model = model(recording: changes)
        await model.refresh()
        await model.setOption("sk-123", for: "apikey", of: identity)
        await model.uninstall(identity)
        #expect(secrets.count == 0)
        #expect(model.rows.isEmpty)
        #expect(changes.all.last == .removed(identity))
    }
}
