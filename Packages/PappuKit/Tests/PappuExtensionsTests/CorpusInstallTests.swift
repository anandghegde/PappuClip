import Foundation
import PappuCore
import PappuDevTools
@testable import PappuExtensions
import Testing

/// Every corpus package that loads also installs (EXM-1), and every one of them, installed side by
/// side, keeps its own identity whatever it says its identifier is (SEC-8a).
@Suite struct CorpusInstallTests {
    @Test func everyLoadableCorpusPackageInstalls() async throws {
        let corpus = try RepositoryRoot.find(from: URL(filePath: #filePath)).appending(path: "Tests/corpus")
        let sources = CorpusLoader.discover(in: corpus).filter { CorpusLoader.load($0).isLoaded }
        try #require(!sources.isEmpty, "the corpus submodule is not checked out")

        let scratch = try Scratch()
        let library = try ExtensionLibrary(paths: scratch.paths)
        var installed = 0
        var failures: [String] = []
        for url in sources {
            guard let source = ExtensionLibrary.Source.file(url) else { continue }
            do {
                switch try await library.install(source, review: Reviews().reviewer) {
                case .installed: installed += 1
                case .alreadyInstalled: break
                case let other: failures.append("\(url.lastPathComponent): \(other)")
                }
            } catch {
                failures.append("\(url.path.replacingOccurrences(of: corpus.path + "/", with: "")): \(error)")
            }
        }
        #expect(failures == [])
        let records = try await library.store.extensions()
        #expect(records.count == installed)
        #expect(Set(records.map(\.localIdentity)).count == records.count)
        #expect(try await library.store.versionFolders().count == installed)
    }
}
