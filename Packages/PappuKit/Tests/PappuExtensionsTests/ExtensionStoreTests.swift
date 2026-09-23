import Foundation
import GRDB
import PappuCore
@testable import PappuExtensions
import Testing

/// FMT-7 and EXM-9 at the level of rows: the schema, the seed, deletion and restore.
@Suite struct ExtensionStoreTests {
    static func builtins() throws -> [ExtensionManifest] {
        [
            try manifest("#popclip\nname: Copy\nidentifier: com.example.builtin.copy\nurl: https://example.com/copy?q=***"),
            try manifest("#popclip\nname: Search\nidentifier: com.example.builtin.search\nurl: https://example.com/?q=***"),
        ]
    }

    @Test func theDatabaseIsOneFileThatKeepsItsDeviceID() async throws {
        let scratch = try Scratch()
        let url = scratch.root.appending(path: "Store/pappuclip.sqlite")
        let first = try ExtensionStore(at: url).deviceID
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try ExtensionStore(at: url).deviceID == first)
    }

    @Test func seedingAddsEachBuiltinOnceInOrder() async throws {
        let store = try ExtensionStore(at: nil)
        #expect(try await store.seedBuiltins(Self.builtins()).count == 2)
        #expect(try await store.seedBuiltins(Self.builtins()).isEmpty)
        let placed = try await store.placedActions()
        #expect(placed.map(\.extension.manifestIdentifier) == ["com.example.builtin.copy", "com.example.builtin.search"])
        #expect(placed.allSatisfy { $0.extension.isBuiltin && $0.item.revision == 1 && $0.item.deviceID == store.deviceID })
    }

    /// EXM-9: a built-in's actions can be deleted, stay deleted across a relaunch's seed, and come back.
    @Test func deletedBuiltinsStayDeletedUntilRestored() async throws {
        let store = try ExtensionStore(at: nil)
        try await store.seedBuiltins(Self.builtins())
        let copy = try #require(try await store.placedActions().first)
        let deletion = try await store.deleteListItem(copy.item.id)
        #expect(deletion.uninstalled == nil)
        #expect(try await store.extension(copy.extension.localIdentity) != nil)

        try await store.seedBuiltins(Self.builtins())
        #expect(try await store.placedActions().map(\.extension.manifestIdentifier) == ["com.example.builtin.search"])

        #expect(try await store.restoreBuiltins(Self.builtins()) == 1)
        #expect(try await store.placedActions().map(\.extension.manifestIdentifier) == ["com.example.builtin.search", "com.example.builtin.copy"])
        #expect(try await store.restoreBuiltins(Self.builtins()) == 0)
    }

    @Test func aDeletedItemIsATombstoneAndItsKeyIsNotReused() async throws {
        let store = try ExtensionStore(at: nil)
        try await store.seedBuiltins(Self.builtins())
        let last = try #require(try await store.placedActions().last)
        _ = try await store.deleteListItem(last.item.id)
        try await store.restoreBuiltins(Self.builtins())
        let restored = try #require(try await store.placedActions().last)
        #expect(restored.item.id != last.item.id)
        #expect(restored.item.orderKey > last.item.orderKey)
    }

    @Test func aBuiltinCannotBeUninstalled() async throws {
        let store = try ExtensionStore(at: nil)
        let identity = try #require(try await store.seedBuiltins(Self.builtins()).first)
        await #expect(throws: ExtensionStore.StoreError.builtinCannotBeRemoved) {
            try await store.uninstall(identity)
        }
    }

    @Test func theMigrationCreatesTheSyncColumns() async throws {
        let queue = try DatabaseQueue()
        try ExtensionStore.migrator.migrate(queue)
        let columns = try await queue.read { db in
            try Set(db.columns(in: "list_item").map(\.name))
        }
        #expect(columns.isSuperset(of: ["id", "order_key", "revision", "device_id", "deleted_at"]))
    }
}
