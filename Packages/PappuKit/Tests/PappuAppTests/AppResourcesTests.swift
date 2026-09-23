import Foundation
import PappuAnalysis
import PappuApp
import PappuCore
import PappuSelection
import Testing

/// The one test that reads the documents the app ships as they are checked in.
///
/// Everything else about these files is tested against strings written in the test: this is the test
/// that a typo in `search-engines.json` fails a build rather than a launch, and the reason
/// `AppResources.load(from:)` exists at all. It reads the repository's `Resources/` by walking up from
/// its own source file, which is the only way a SwiftPM test can find a directory that belongs to the
/// app target rather than to the package.
@Suite struct AppResourcesTests {
    /// The repository's `Resources/`, found by the one landmark that only it has.
    static func repositoryResources() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appending(path: "Resources")
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: BuiltinExtensions.directoryName).path
            ) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        throw Damage.resourcesNotFound
    }

    enum Damage: Error { case resourcesNotFound }

    @Test func everythingTheAppShipsReadsWithoutAFailure() throws {
        let resources = try AppResources.load(from: try Self.repositoryResources())
        #expect(resources.failures.map(\.description) == [])
        #expect(!resources.catalog.isEmpty)
    }

    /// The five built-ins of ALM-3, each one a manifest that names an executor the app knows.
    @Test func everyBuiltinManifestNamesABuiltin() throws {
        let resources = try AppResources.load(from: try Self.repositoryResources())
        #expect(resources.catalog.count == 5)
        #expect(resources.catalog.enabled.allSatisfy { $0.builtin != nil })
        #expect(resources.catalog.enabled.count == 5)
    }

    @Test func theShippedDocumentsAreAllTheSchemaThisBuildReads() throws {
        let resources = try AppResources.load(from: try Self.repositoryResources())
        #expect(resources.policies.schema == DetectionPolicies.supportedSchema)
        #expect(resources.engines.schema == SearchEngines.supportedSchema)
        #expect(resources.schemes.schema == URLSchemes.supportedSchema)
        #expect(resources.engines.preferred != nil)
        #expect(resources.domains.contains("com"))
    }

    /// A build that lost the manifests has lost the product: there is nothing to put in the bar, and an
    /// app that came up anyway would be an app with an empty bar and no explanation.
    @Test func aBundleWithoutTheBuiltinsIsDamagedAndSaysWhich() throws {
        let empty = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let damage = #expect(throws: AppResources.Damaged.self) {
            try AppResources.load(from: empty)
        }
        #expect(damage?.resource == BuiltinExtensions.directoryName)
        #expect(damage?.description.contains(ProductIdentity.appName) == true)
    }

    /// A build that lost a detector's table has lost a detector. Each of the three has a named fallback
    /// already, and going on with it beats refusing to start.
    @Test func aBundleWithoutTheDetectorTablesFallsBackAndRecordsWhatWasMissing() throws {
        let partial = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let source = try Self.repositoryResources()
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: partial) }
        for path in [BuiltinExtensions.directoryName, "DetectionPolicies"] {
            try FileManager.default.copyItem(
                at: source.appending(path: path),
                to: partial.appending(path: path)
            )
        }

        let resources = try AppResources.load(from: partial)
        #expect(resources.failures.map(\.resource) == [
            SearchEngines.fileName,
            URLSchemes.fileName,
            TopLevelDomains.fileName,
        ])
        #expect(resources.engines.defaultID == SearchEngines.fallback.defaultID)
        #expect(resources.schemes.schemes.isEmpty)
        #expect(resources.domains.count == 0)
        // The half that is not a fallback is the half that had to be there.
        #expect(!resources.catalog.isEmpty)
    }
}
