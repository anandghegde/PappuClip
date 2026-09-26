import Foundation
import PappuCore
import PappuExtensions
@testable import PappuSettings
import Testing

/// A library in a folder of its own, removed with the test.
final class LibraryScratch: @unchecked Sendable {
    let root: URL
    let library: ExtensionLibrary

    init(scanner: (any CodeScanning)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "pappu-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        library = try ExtensionLibrary(paths: ExtensionLibrary.Paths(root: root), scanner: scanner)
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

/// The helper's scan, answering the same for every package.
struct FixedScan: CodeScanning {
    let found: CodeScan
    init(_ found: CodeScan) { self.found = found }
    func scan(_ manifest: ExtensionManifest, in directory: URL) async -> CodeScan? { found }
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

    /// SEC-6: an extension that declares its hosts is disclosed by them, with no switch to turn on.
    @Test func consentNamesTheHosts() async throws {
        let snippet = "#popclip\nname: Fetch\nidentifier: com.example.fetch\nentitlements: [network]\nnetworkHosts: [api.example.com, cdn.example.com]\njavascript: return 1\n"
        let review = ConsentPresenter.review(try await scratch.proposal(snippet))
        let hosts = ListFormatter.localizedString(byJoining: ["api.example.com", "cdn.example.com"])
        #expect(review.listed.contains(ExtensionStrings.sendsData(hosts)))
        #expect(review.listed.contains { $0.contains("api.example.com") && $0.contains("cdn.example.com") })
        #expect(!review.gates.map(\.capability).contains(.network))
    }

    /// EXM-5f: code that aliases `popclip` cannot be bounded, so it is gated once, and that one switch
    /// names the sensitive methods it could reach. Synthetic input stays a switch of its own (SEC-7b), so
    /// declining it still leaves the rest working.
    @Test func anAliasedPopclipIsGatedOnceWithItsMethods() async throws {
        let scanned = try LibraryScratch(scanner: FixedScan(CodeScan(unbounded: [.aliasedPopclip])))
        let snippet = "#popclip\nname: Alias\nidentifier: com.example.alias\nentitlements: [script]\njavascript: const p = popclip; return p.runShellScript('ls')\n"
        let proposal = try await scanned.proposal(snippet)
        let review = ConsentPresenter.review(proposal)
        #expect(review.gates.map(\.capability) == [.script, .syntheticInput, .unboundedCode])
        #expect(review.gates.filter { $0.capability == .unboundedCode }.count == 1)
        let methods = proposal.capabilities.reachableMethods
        #expect(methods.contains("runShellScript") && methods.contains("pressKey") && methods.contains("$"))
        let sentence = try #require(review.gates.first { $0.capability == .unboundedCode }?.sentence)
        #expect(sentence == ExtensionStrings.gateUnboundedCode(calling: ListFormatter.localizedString(byJoining: methods)))
        #expect(sentence.contains("runShellScript"))
    }

    /// EXM-5f: code the scan bounds needs no `unbounded-code` switch.
    @Test func boundedCodeIsDisclosedByWhatItCalls() async throws {
        let scanned = try LibraryScratch(scanner: FixedScan(CodeScan(methods: [])))
        let snippet = "#popclip\nname: Upper\nidentifier: com.example.upper\njavascript: return popclip.input.text.toUpperCase()\n"
        let review = ConsentPresenter.review(try await scanned.proposal(snippet))
        #expect(review.gates.isEmpty)
        #expect(review.listed == [ExtensionStrings.readsAndReplacesText])
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
