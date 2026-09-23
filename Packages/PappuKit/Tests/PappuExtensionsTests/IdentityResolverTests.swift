import Foundation
import PappuCore
@testable import PappuExtensions
import Testing

/// EXM-2 and SEC-8d's collision table, one row per test.
@Suite struct IdentityResolverTests {
    static let digestA = ContentDigest.of(snippet: "a")
    static let digestB = ContentDigest.of(snippet: "b")

    static func installed(
        _ identifier: String = "com.example.translate",
        origin: IdentifierOrigin = .declared,
        name: String = "Translate",
        provenance: Provenance = .local(.packageFile, digestA),
        digest: ContentDigest? = digestA
    ) -> IdentityResolver.Installed {
        IdentityResolver.Installed(identity: LocalIdentity(), identifier: identifier, identifierOrigin: origin, name: name, provenance: provenance, digest: digest)
    }

    static func candidate(
        _ identifier: String = "com.example.translate",
        origin: IdentifierOrigin = .declared,
        name: String = "Translate",
        provenance: Provenance = .local(.packageFile, digestB),
        digest: ContentDigest = digestB
    ) -> IdentityResolver.Candidate {
        IdentityResolver.Candidate(identifier: identifier, identifierOrigin: origin, name: name, provenance: provenance, digest: digest)
    }

    static let registry = Provenance.registry(namespace: "example", publisherRecord: "pub-1", keyID: "k1")

    @Test func nothingMatchingIsFresh() {
        let decision = IdentityResolver.resolve(Self.candidate("com.other.thing", name: "Other"), against: [Self.installed()], route: .manual)
        #expect(decision == .fresh)
    }

    @Test func identicalContentIsAlreadyInstalledWhateverItIsCalled() {
        let existing = Self.installed()
        let decision = IdentityResolver.resolve(Self.candidate("x.y", name: "Z", digest: Self.digestA), against: [existing], route: .batch)
        #expect(decision == .alreadyInstalled(existing.identity))
    }

    /// SEC-8d: local code is vouched for by nobody, so the same identifier is a separate install.
    @Test func aLocalPackageWithTheSameIdentifierInstallsSeparately() {
        let existing = Self.installed()
        let decision = IdentityResolver.resolve(Self.candidate(), against: [existing], route: .manual)
        #expect(decision == .separate([.init(existing: existing.identity, kind: .identifier, allowsTrustTransition: true)]))
    }

    @Test func theSamePublisherOffersAReplacementOnlyOnAManualRoute() {
        let existing = Self.installed(provenance: Self.registry)
        let candidate = Self.candidate(provenance: .registry(namespace: "example", publisherRecord: "pub-1", keyID: "k2"))
        #expect(IdentityResolver.resolve(candidate, against: [existing], route: .manual) == .replacementOffered(existing.identity))
        #expect(IdentityResolver.resolve(candidate, against: [existing], route: .batch)
            == .separate([.init(existing: existing.identity, kind: .identifier, allowsTrustTransition: false)]))
    }

    @Test func anotherPublisherWithTheSameIdentifierDoesNotReplace() {
        let existing = Self.installed(provenance: Self.registry)
        let candidate = Self.candidate(provenance: .registry(namespace: "example", publisherRecord: "pub-2", keyID: "k1"))
        #expect(IdentityResolver.resolve(candidate, against: [existing], route: .manual)
            == .separate([.init(existing: existing.identity, kind: .identifier, allowsTrustTransition: true)]))
    }

    @Test func aBuiltinIsNeverReplacedByTrustTransition() {
        let existing = Self.installed(provenance: .builtin, digest: nil)
        #expect(IdentityResolver.resolve(Self.candidate(), against: [existing], route: .manual)
            == .separate([.init(existing: existing.identity, kind: .identifier, allowsTrustTransition: false)]))
    }

    /// EXM-2: "A matching name alone never silently replaces an extension."
    @Test(arguments: ["Translate", "TRANSLATE", " translate ", "Tránslate"])
    func aMatchingNameIsOnlyAWarning(_ name: String) {
        let existing = Self.installed()
        let decision = IdentityResolver.resolve(Self.candidate("com.other.translate", name: name), against: [existing], route: .manual)
        #expect(decision == .separate([.init(existing: existing.identity, kind: .name, allowsTrustTransition: false)]))
    }

    /// FMT-3: a snippet with no identifier is identified by its name, which is still only a name.
    @Test func aNameDerivedIdentifierIsComparedAsAName() {
        let existing = Self.installed("Translate", origin: .name, name: "Translate")
        let decision = IdentityResolver.resolve(Self.candidate("Translate", origin: .name, name: "Translate"), against: [existing], route: .manual)
        #expect(decision == .separate([.init(existing: existing.identity, kind: .name, allowsTrustTransition: false)]))
    }

    @Test func onlyRegistryProvenanceVouches() {
        let local = Provenance.local(.packageFile, Self.digestA)
        #expect(!local.vouchesForReplacement(by: local))
        #expect(!Provenance.builtin.vouchesForReplacement(by: .builtin))
        #expect(Self.registry.vouchesForReplacement(by: Self.registry))
    }
}
