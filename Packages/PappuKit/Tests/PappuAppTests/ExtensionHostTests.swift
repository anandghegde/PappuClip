import Foundation
import PappuAnalysis
import PappuCore
import PappuExtensions
@testable import PappuApp
import PappuRuntime
import PappuSelection
import PappuSettings
import Synchronization
import Testing

/// EXM-5, SEC-4b and §8.9 where the bar meets the store: the host's snapshot is what the resolver is
/// handed, so what it says is what can run.
@Suite struct ExtensionHostTests {
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

    static let module = "// #popclip\n// name: Moduled\n// identifier: com.example.moduled\ndefineExtension({ action: { title: 'Go', code: (input) => input.text } })"

    /// A describer that answers every module the same way and remembers who asked.
    final class FakeModules: ModuleDescribing {
        private let answer: ModuleExports
        private let asked = Mutex<[ModuleDescribeRequest]>([])
        var requests: [ModuleDescribeRequest] { asked.withLock { $0 } }

        init(_ json: String) throws {
            answer = try ModuleExports(json: json, functions: [])
        }

        func describe(_ module: ModuleDescribeRequest) async -> Result<ModuleExports, ModuleDescribeFailure> {
            asked.withLock { $0.append(module) }
            return .success(answer)
        }
    }

    /// The host answers in the background; this waits, a little, for what it should have done.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private let root: URL
    private let library: ExtensionLibrary
    private let secrets = InMemorySecretStore()
    private let invalidated = Invalidations()

    final class Invalidations: Sendable {
        private let owners = Mutex<[String]>([])
        var all: [String] { owners.withLock { $0 } }
        func append(_ owner: String) { owners.withLock { $0.append(owner) } }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "pappu-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        library = try ExtensionLibrary(paths: ExtensionLibrary.Paths(root: root))
    }

    private func host() -> ExtensionHost {
        let invalidated = self.invalidated
        return ExtensionHost(library: library, secrets: secrets, builtins: []) { owner in
            invalidated.append(owner)
        }
    }

    private func install(_ text: String, consent: ExtensionLibrary.Consent = .install) async throws -> LocalIdentity {
        guard case .installed(let identity, _) = try await library.install(.selectedText(text), review: { _ in consent }) else {
            throw CocoaError(.featureUnsupported)
        }
        return identity
    }

    private func resolve(_ host: ExtensionHost, _ text: String = "hello") -> ActionResolver.Resolution {
        ActionResolver { host.approval(for: $0) }.resolve(
            host.catalog,
            selection: AnalyzedSelection(text: text, detections: []),
            context: SelectionContext(
                app: AppIdentity(pid: 42, bundleID: "com.example.Editor", name: "Editor"),
                editability: Editability(isEditable: false, source: .settableSelectedText),
                canCut: false,
                canCopy: true,
                canPaste: false,
                hasFormatting: false
            ),
            options: host.options
        )
    }

    @Test func anApprovedExtensionReachesTheBar() async throws {
        let identity = try await install(Self.search)
        let host = host()
        await host.start()
        let action = try #require(host.catalog.actions.first)
        #expect(action.owner == identity.description)
        #expect(host.approval(for: action)?.owner == identity.description)
        #expect(resolve(host).actions.map(\.key) == [action.key])
        try? FileManager.default.removeItem(at: root)
    }

    /// EXM-2: the bar's offer is reviewed like a file, as text from this Mac, and what the review
    /// approves is on the bar once it answers.
    @Test func aSelectedSnippetIsReviewedAndReachesTheBar() async throws {
        let host = host()
        let origins = Mutex<[LocalOrigin?]>([])
        let results = await host.install(sources: [.selectedText(Self.search)]) { proposal in
            if case .local(let origin, _) = proposal.provenance {
                origins.withLock { $0.append(origin) }
            } else {
                origins.withLock { $0.append(nil) }
            }
            return .install
        }
        guard case .success(.installed(let identity, _)) = try #require(results.first) else {
            Issue.record("not installed: \(results)")
            return
        }
        #expect(origins.withLock { $0 } == [.selectedText])
        #expect(host.catalog.actions.map(\.owner) == [identity.description])
        #expect(resolve(host).actions.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    /// Cancelling the review of a selection leaves nothing behind.
    @Test func aCancelledSelectionInstallsNothing() async throws {
        let host = host()
        let results = await host.install(sources: [.selectedText(Self.search)]) { _ in .cancel }
        #expect(results.count == 1)
        if case .success(let outcome) = results[0] { #expect(outcome == .cancelled) }
        #expect(host.catalog.actions.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    /// EXM-5d on the bar: an approval without the script gate draws no shell-script button.
    @Test func anUngrantedGateKeepsTheActionOffTheBar() async throws {
        _ = try await install(Self.shell)
        let host = host()
        await host.reload()
        let action = try #require(host.catalog.actions.first)
        #expect(resolve(host).refusals[action.key] == .notGranted([.script]))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Modules (JS-12)

    @Test func anApprovedModuleIsDescribedAndItsActionsReachTheCatalog() async throws {
        let identity = try await install(Self.module)
        let modules = try FakeModules(#"{"action":{"title":"Go","code":true}}"#)
        let host = ExtensionHost(library: library, secrets: secrets, builtins: [], modules: modules) { _ in }
        await host.reload()
        try await eventually { host.catalog.actions.contains { $0.owner == identity.description } }
        let action = try #require(host.catalog.actions.first { $0.owner == identity.description })
        #expect(action.title.english == "Go")
        guard case .javaScript(let script) = action.executor else {
            Issue.record("A module's action runs JavaScript")
            return
        }
        #expect(script.export == "action")
        #expect(modules.requests.map(\.owner) == [identity.description])
        // Asked once for these bytes, however often the host reloads.
        await host.reload()
        #expect(modules.requests.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    /// Describing a module runs its code, so a module without an approval for its bytes is never
    /// described (architecture §10.2).
    @Test func aModuleWithoutAnApprovalIsNeverRun() async throws {
        let identity = try await install(Self.module)
        try await library.store.revoke(identity)
        let modules = try FakeModules(#"{"action":{"title":"Go","code":true}}"#)
        let host = ExtensionHost(library: library, secrets: secrets, builtins: [], modules: modules) { _ in }
        await host.reload()
        try await Task.sleep(for: .milliseconds(100))
        #expect(modules.requests.isEmpty)
        #expect(!host.catalog.actions.contains { $0.owner == identity.description })
        try? FileManager.default.removeItem(at: root)
    }

    /// SEC-4b: the revocation reaches the snapshot before the invalidation, and the invalidation names
    /// the extension's owner.
    @Test func revokingTakesTheButtonAwayAndStopsWhatItRuns() async throws {
        let identity = try await install(Self.search)
        let host = host()
        await host.reload()
        try await library.store.revoke(identity)
        await host.handle(.revoked(identity))
        let action = try #require(host.catalog.actions.first)
        #expect(host.approval(for: action) == nil)
        #expect(resolve(host).refusals[action.key] == .notApproved)
        #expect(invalidated.all == [identity.description])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func anOptionChangeDoesNotStopAnything() async throws {
        let identity = try await install(Self.search)
        let host = host()
        await host.handle(.updated(identity))
        #expect(invalidated.all.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    /// §8.9: the matcher sees stored values and defaults; the run sees the Keychain's too.
    @Test func secretsReachTheRunAndNotTheMatcher() async throws {
        let identity = try await install(Self.keyed)
        let instance = try #require(try await library.store.instances(of: identity).first?.id)
        try secrets.setSecret("sk-123", for: "apikey", of: instance, owner: identity)
        let host = host()
        await host.reload()
        #expect(host.options["com.example.keyed"] == ["apikey": "", "lang": "en"])
        let action = try #require(host.catalog.actions.first)
        #expect(host.runtimeOptions(for: action) == ["apikey": "sk-123", "lang": "en"])
        try? FileManager.default.removeItem(at: root)
    }

    /// A built-in has no owner and no options, and is approved by the app (EXM-5g).
    @Test func builtinsAreApprovedByTheApp() throws {
        let resources = try AppResources.load(from: AppResourcesTests.repositoryResources())
        let host = ExtensionHost(library: library, secrets: secrets, builtins: resources.builtins) { _ in }
        let copy = try #require(host.catalog.actions.first)
        #expect(host.approval(for: copy) != nil)
        #expect(host.runtimeOptions(for: copy).isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}
