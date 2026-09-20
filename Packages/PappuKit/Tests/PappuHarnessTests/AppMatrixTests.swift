import PappuHarness
import Testing

@Suite struct AppMatrixTests {
    /// PRD §11.5: 15 gating apps and 22 tracked ones. Changing either count needs a recorded reason.
    @Test func matrixMatchesThePRD() throws {
        let matrix = try AppMatrix.bundled()
        #expect(matrix.schema == 1)
        #expect(matrix.apps(in: .gating).count == 15)
        #expect(matrix.apps(in: .tracked).count == 22)
        #expect(matrix.apps(in: .gating).map(\.name).contains("Terminal"))
    }

    @Test func namesAndBundleIDsAreUnique() throws {
        let matrix = try AppMatrix.bundled()
        #expect(Set(matrix.apps.map(\.name)).count == matrix.apps.count)
        let bundleIDs = matrix.apps.flatMap(\.bundleIDs)
        #expect(Set(bundleIDs).count == bundleIDs.count)
        #expect(matrix.apps.allSatisfy { !$0.bundleIDs.isEmpty })
    }

    @Test @MainActor func installedProbeFindsSystemApps() throws {
        let installed = try AppMatrix.bundled().installedApps()
        let textEdit = try #require(installed.first { $0.app.name == "TextEdit" })
        #expect(textEdit.bundleID == "com.apple.TextEdit")
        #expect(textEdit.url.pathExtension == "app")
    }
}
