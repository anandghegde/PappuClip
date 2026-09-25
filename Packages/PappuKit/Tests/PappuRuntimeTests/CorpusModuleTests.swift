import Foundation
import PappuCore
@testable import PappuRuntime
import Testing

/// JS-12 against the frozen corpus: every module extension in PopClip-Extensions is described by the
/// helper's own code, and what it exported builds a manifest.
///
/// The ones that cannot be described yet are named, with the reason, so that this fails both when
/// something new breaks and when one of them starts to work and the list is stale.
@Suite struct CorpusModuleTests {
    /// What each module that cannot be described yet is waiting for, as its failure says it. The nine
    /// that call `util` while they load describe since week 3 built it.
    static let waiting: [String: String] = [
        // An action with a submenu, which the bar has from M4; until then the builder refuses it, as it
        // does in a config.
        "OpenAIPrompt": "Submenus",
    ]

    static var corpus: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/corpus")
    }

    @Test func everyCorpusModuleIsDescribedOrWaitsForAKnownReason() async throws {
        var packages: [URL] = []
        for folder in ["source", "contrib"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.corpus.appending(path: folder).path)) ?? []
            packages += names.filter { $0.hasSuffix(".popclipext") }.sorted().map { Self.corpus.appending(path: "\(folder)/\($0)") }
        }
        try #require(!packages.isEmpty, "the corpus submodule is not checked out")

        var modules = 0
        var described: [String: ExtensionManifest] = [:]
        var failed: [String: String] = [:]
        for package in packages {
            guard let loaded = try? ExtensionLoader.loadPackage(at: package), let module = loaded.manifest.moduleSource else { continue }
            modules += 1
            let name = package.deletingPathExtension().lastPathComponent
            let request = ModuleDescribeRequest(
                owner: name,
                generation: "1",
                extensionName: name,
                directory: package,
                module: module
            )
            // A helper of its own for each, let go afterwards, so that eighty worlds are not held at once.
            switch await JSHostClient(transport: InProcessJSHost()).describe(request) {
            case .success(let exports):
                do {
                    described[name] = try ExtensionLoader.loadPackage(at: package, settings: .init(moduleExports: exports)).manifest
                } catch {
                    failed[name] = "its exports did not build: \(error)"
                }
            case .failure(let failure):
                failed[name] = failure.message
            }
        }

        #expect(modules >= 80)
        #expect(Set(failed.keys) == Set(Self.waiting.keys), "\(failed)")
        for (name, message) in failed {
            #expect(message.contains(Self.waiting[name] ?? "\u{0}"), "\(name): \(message)")
        }
        // A module whose actions are a population function offers none until week 5; every other one
        // offers at least one, and each of those runs its module's code.
        let withActions = described.values.filter { !$0.actions.isEmpty }
        #expect(withActions.count >= 60)
        for manifest in withActions {
            for action in manifest.actions {
                guard case .javaScript(let script) = action.executor, script.export != nil else {
                    Issue.record("\(manifest.identifier) has an action that does not run its module")
                    continue
                }
            }
        }
    }
}
