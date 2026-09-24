import Foundation
import PappuCore
@testable import PappuExtensions
import Testing

/// What Extension Info and the catalog are built from after launch: each extension read back from its
/// active version's folder, with its capabilities worked out again (EXM-5b).
@Suite struct InstalledExtensionsTests {
    private let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    @Test func anInstallIsReadBackFromItsFolder() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        _ = try await library.install(.selectedText(ExecutionApprovalTests.shell), review: { _ in .install })
        let installed = try await library.installed()
        let shout = try #require(installed.extensions.first)
        #expect(installed.unreadable.isEmpty)
        #expect(shout.manifest.identifier == "com.example.shout")
        #expect(shout.capabilities.gated == [.script])
        #expect(shout.approval != nil)
        #expect(shout.isGranted(.script) == false)
        #expect(shout.instance != nil)
    }

    /// Built-ins are the app's, and are not listed as installed extensions.
    @Test func builtinsAreNotListed() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        try await library.store.seedBuiltins([try manifest(snippet("Search", identifier: "com.example.builtin"))])
        #expect(try await library.installed().extensions.isEmpty)
    }

    /// A folder that has gone is reported, not dropped: the store still holds the user's settings.
    @Test func aMissingFolderIsUnreadable() async throws {
        let library = try ExtensionLibrary(paths: scratch.paths)
        _ = try await library.install(.selectedText(snippet("Search", identifier: "com.example.search")), review: { _ in .install })
        let record = try #require(try await library.store.extensions().first { !$0.isBuiltin })
        try FileManager.default.removeItem(at: try #require(library.folder(for: record)))
        let installed = try await library.installed()
        #expect(installed.extensions.isEmpty)
        #expect(installed.unreadable.map(\.record.localIdentity) == [record.localIdentity])
    }
}

@Suite struct SecretStoreTests {
    @Test func secretsAreKeptPerOwnerAndRemovedWithIt() throws {
        let store = InMemorySecretStore()
        let (a, b) = (LocalIdentity(), LocalIdentity())
        let instance = InstanceID()
        try store.setSecret("one", for: "key", of: instance, owner: a)
        try store.setSecret("two", for: "key", of: instance, owner: b)
        #expect(store.secret("key", of: instance, owner: a) == "one")
        try store.removeSecrets(of: a)
        #expect(store.secret("key", of: instance, owner: a) == nil)
        #expect(store.secret("key", of: instance, owner: b) == "two")
    }

    /// An empty value clears the secret rather than storing nothing under it.
    @Test func anEmptyValueDeletes() throws {
        let store = InMemorySecretStore()
        let owner = LocalIdentity()
        let instance = InstanceID()
        try store.setSecret("one", for: "key", of: instance, owner: owner)
        try store.setSecret("", for: "key", of: instance, owner: owner)
        #expect(store.count == 0)
    }
}
