// PappuExtensions
//
// Extension store, identity, install pipeline, grants, consent model, options, icons.
// Architecture §9 and §11; docs/implementation-plan.md M2.
//
// As built (M2 week 2): identity and provenance (`LocalIdentity`, `Provenance`, `ContentDigest`,
// `IdentityResolver`), the SQLite store (`ExtensionStore`, `OrderKey`), and the staged install
// pipeline over both (`ExtensionLibrary`). Grants and consent are week 5.
import Foundation
