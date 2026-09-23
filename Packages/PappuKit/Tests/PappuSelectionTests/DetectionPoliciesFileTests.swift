import Foundation
import PappuDevTools
import PappuSelection
import Testing

/// The shipped `Resources/DetectionPolicies/detection-policies.json` (ACT-11a, architecture §4.6).
///
/// Most of the file is provisional — strategy order and the per-app flags are M0 spike 3's output, and
/// the `axEnable` kinds are spike 4's — so what is asserted here is only what the PRD already settles:
/// the default refuses synthetic copy on the automatic path, and the apps ACT-11a names by hand are
/// flagged. Everything else the file says is data these tests deliberately do not pin.
@Suite struct DetectionPoliciesFileTests {
    static let relativePath = "Resources/DetectionPolicies/" + DetectionPolicies.fileName

    static func bundled() throws -> DetectionPolicies {
        let root = try RepositoryRoot.find(from: URL(filePath: #filePath))
        return try DetectionPolicies.load(from: root.appending(path: relativePath))
    }

    @Test func theShippedFileLoadsAtTheSchemaThisBuildReads() throws {
        let policies = try Self.bundled()
        #expect(policies.schema == DetectionPolicies.supportedSchema)
        #expect(policies.sequence >= 1)
        #expect(policies.note != nil)
    }

    @Test func theShippedDefaultRefusesSyntheticCopyOnTheAutomaticPath() throws {
        let policies = try Self.bundled()
        #expect(!policies.default.autoSyntheticCopy)
        #expect(!policies.policy(for: "com.example.NeverSeenBefore").chain(for: .automatic).contains(.syntheticCopy))
    }

    /// ACT-11a names these by hand, so they are not waiting on a spike.
    @Test func everyAppACT11aCallsAWholeLineCopierIsFlagged() throws {
        let policies = try Self.bundled()
        let expected = [
            "com.microsoft.VSCode",
            "com.sublimetext.4",
            "com.sublimetext.3",
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.jetbrains.WebStorm",
            "com.jetbrains.goland",
            "com.jetbrains.CLion",
        ]
        for bundleID in expected {
            let policy = policies.policy(for: bundleID)
            #expect(policy.copiesLineWhenEmpty, "\(bundleID)")
            #expect(!policy.autoSyntheticCopy, "\(bundleID)")
            #expect(!policy.chain(for: .automatic).contains(.syntheticCopy), "\(bundleID)")
        }
    }

    @Test func noShippedAppIsAllowedSyntheticCopyOnTheAutomaticPathBeforeSpikeThreeHasRun() throws {
        let policies = try Self.bundled()
        for (bundleID, _) in policies.apps {
            #expect(!policies.policy(for: bundleID).autoSyntheticCopy, "\(bundleID)")
        }
    }

    /// An entry that names an attribute to set is an entry whose chain can use strategy 3.
    @Test func everyAppWithAnEnableKindHasStrategyThreeInItsChain() throws {
        let policies = try Self.bundled()
        for (bundleID, record) in policies.apps where record.axEnable != nil {
            #expect(policies.policy(for: bundleID).chain(for: .automatic).contains(.axEnable), "\(bundleID)")
        }
    }

    /// An empty record is a no-op, so it is a typo or a leftover rather than a policy.
    @Test func noShippedEntrySaysNothing() throws {
        let policies = try Self.bundled()
        for (bundleID, record) in policies.apps {
            #expect(!record.isEmpty, "\(bundleID)")
        }
        for (prefix, record) in policies.prefixes {
            #expect(!record.isEmpty, "\(prefix)")
            #expect(!prefix.isEmpty, "an empty prefix matches every app; use `default` instead")
        }
    }
}
