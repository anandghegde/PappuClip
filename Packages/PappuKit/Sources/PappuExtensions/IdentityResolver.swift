import Foundation
import PappuCore

/// What an arriving package is, relative to what is installed (EXM-2, SEC-8d, architecture §9.2).
///
/// A pure function over summaries, so the whole collision table is a unit test. The table:
///
/// | Arriving | Installed | Decision |
/// |---|---|---|
/// | Nothing matches | — | `fresh` |
/// | Identical content | any | `alreadyInstalled` |
/// | Same declared identifier, provenance that vouches for it, manual route | registry | `replacementOffered` |
/// | Same declared identifier, anything else | any | `separate`, collision `.identifier` |
/// | Same name, or an identifier that is only a name (FMT-3) | any | `separate`, collision `.name` |
///
/// **A name never replaces anything, and neither does an identifier on its own.** The first is the
/// PRD's words; the second follows from what an identifier is — a string in a file — and is why an
/// `.identifier` collision is only ever settled by a *trust transition* the user chooses, which moves
/// the list positions and non-secret options to a new identity and leaves grants and secrets behind
/// (SEC-8e). `.name` collisions offer nothing: the two extensions merely look alike, and the user is
/// told so.
public enum IdentityResolver {
    public struct Candidate: Sendable, Equatable {
        public var identifier: String
        public var identifierOrigin: IdentifierOrigin
        public var name: String
        public var provenance: Provenance
        public var digest: ContentDigest

        public init(identifier: String, identifierOrigin: IdentifierOrigin, name: String, provenance: Provenance, digest: ContentDigest) {
            self.identifier = identifier
            self.identifierOrigin = identifierOrigin
            self.name = name
            self.provenance = provenance
            self.digest = digest
        }

        public init(manifest: ExtensionManifest, provenance: Provenance, digest: ContentDigest) {
            self.init(
                identifier: manifest.identifier,
                identifierOrigin: manifest.identifierOrigin,
                name: manifest.name.english,
                provenance: provenance,
                digest: digest
            )
        }
    }

    public struct Installed: Sendable, Equatable {
        public var identity: LocalIdentity
        public var identifier: String
        public var identifierOrigin: IdentifierOrigin
        public var name: String
        public var provenance: Provenance
        /// The active version's; nil for a built-in, which has no folder.
        public var digest: ContentDigest?

        public init(
            identity: LocalIdentity,
            identifier: String,
            identifierOrigin: IdentifierOrigin,
            name: String,
            provenance: Provenance,
            digest: ContentDigest?
        ) {
            self.identity = identity
            self.identifier = identifier
            self.identifierOrigin = identifierOrigin
            self.name = name
            self.provenance = provenance
            self.digest = digest
        }
    }

    /// EXM-2 offers a replacement "for manual installs" only. An import or a sync that arrives with
    /// several packages at once is not a moment at which anyone is looking at one of them.
    public enum Route: Sendable, Equatable {
        case manual
        case batch
    }

    public struct Collision: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The same declared identifier, from a source that cannot vouch for the change.
            case identifier
            /// Only the name, or an identifier that stands in for one.
            case name
        }

        public var existing: LocalIdentity
        public var kind: Kind

        /// Whether the user may choose to replace `existing` by a trust transition. Never for a name,
        /// never for a built-in (it has no folder to replace and the app's signature to answer to),
        /// and never on a batch route.
        public var allowsTrustTransition: Bool

        public init(existing: LocalIdentity, kind: Kind, allowsTrustTransition: Bool) {
            self.existing = existing
            self.kind = kind
            self.allowsTrustTransition = allowsTrustTransition
        }
    }

    public enum Decision: Sendable, Equatable {
        case fresh
        /// Byte for byte what is already there. Installing it again would change nothing.
        case alreadyInstalled(LocalIdentity)
        /// The installed extension's publisher vouches for this package: it may become the next
        /// version of the same identity, if the user says so.
        case replacementOffered(LocalIdentity)
        /// It installs with a new identity; these are what it will be shown beside.
        case separate([Collision])
    }

    public static func resolve(_ candidate: Candidate, against installed: [Installed], route: Route) -> Decision {
        // The same bytes are the same extension whatever they are called: nothing to decide.
        if let same = installed.first(where: { $0.digest == candidate.digest }) {
            return .alreadyInstalled(same.identity)
        }
        var collisions: [Collision] = []
        for existing in installed {
            let sameIdentifier = candidate.identifierOrigin == .declared
                && existing.identifierOrigin == .declared
                && candidate.identifier == existing.identifier
            if sameIdentifier {
                if route == .manual, existing.provenance.vouchesForReplacement(by: candidate.provenance) {
                    return .replacementOffered(existing.identity)
                }
                collisions.append(
                    Collision(
                        existing: existing.identity,
                        kind: .identifier,
                        allowsTrustTransition: route == .manual && existing.provenance != .builtin
                    )
                )
            } else if looksAlike(candidate, existing) {
                collisions.append(Collision(existing: existing.identity, kind: .name, allowsTrustTransition: false))
            }
        }
        return collisions.isEmpty ? .fresh : .separate(collisions)
    }

    /// Names are compared the way a person reads them: case, width and diacritics aside. An
    /// identifier that is only a name (FMT-3) is compared as one.
    static func looksAlike(_ candidate: Candidate, _ existing: Installed) -> Bool {
        let theirs = [existing.name] + (existing.identifierOrigin == .name ? [existing.identifier] : [])
        let ours = [candidate.name] + (candidate.identifierOrigin == .name ? [candidate.identifier] : [])
        let fold = { (text: String) in
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
        let folded = Set(theirs.map(fold))
        return ours.map(fold).contains { !$0.isEmpty && folded.contains($0) }
    }
}
