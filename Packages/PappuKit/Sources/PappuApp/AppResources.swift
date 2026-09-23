import Foundation
import PappuAnalysis
import PappuCore
import PappuSelection

/// The data the app reads out of its own bundle at launch (architecture §19 item 2).
///
/// **Two of these files are the app and three of them are a feature.** The built-in manifests *are* the
/// actions — without them the bar has no buttons and there is nothing to press — and the detection
/// policies are the only description of how text may be read, so a bundle missing either is damaged and
/// this says so rather than bringing up an app that cannot do anything. The search engines, the URL
/// schemes and the top-level domains each have a named fallback already, and a build that lost one has
/// lost a detector rather than the product; those are recorded and go on.
///
/// **Why there is a second way to load the same files.** The app bundle keeps them where
/// `Bundle.url(forResource:)` looks and the repository keeps them where a person would file them, so
/// `load(from:)` exists beside `bundled(in:)` — and with it the one test that reads the files as
/// checked in, which is what makes a typo in a shipped JSON document fail a build rather than a launch.
public struct AppResources: Sendable {
    /// A file the app can do without, and what was wrong with it.
    public struct Failure: Sendable, Equatable, CustomStringConvertible {
        public var resource: String
        public var reason: String

        public var description: String { "\(resource): \(reason)" }
    }

    /// A file the app cannot do without. Thrown, because there is nothing sensible to start.
    public struct Damaged: Error, Equatable, CustomStringConvertible {
        public var resource: String
        public var reason: String

        public var description: String {
            "\(ProductIdentity.appName) could not read \(resource) from its own bundle: \(reason)"
        }
    }

    /// The actions a fresh install starts with, in `BuiltinAction.allCases` order (ALM-3).
    public var catalog: ActionCatalog
    public var policies: DetectionPolicies
    public var engines: SearchEngines
    public var schemes: URLSchemes
    public var domains: TopLevelDomains
    /// What was missing, in the order it was looked for. Empty in a build that is whole.
    public var failures: [Failure]

    /// The app's own resources. `Bundle.main` in the app; the parameter is here so a test bundle can
    /// be handed in instead of a global being reached for.
    public static func bundled(in bundle: Bundle) throws -> AppResources {
        try AppResources(
            builtins: { try BuiltinExtensions.entries(in: bundle) },
            policies: { try DetectionPolicies.bundled(in: bundle) },
            engines: { try SearchEngines.bundled(in: bundle) },
            schemes: { try URLSchemes.bundled(in: bundle) },
            domains: { try TopLevelDomains.bundled(in: bundle) }
        )
    }

    /// The repository's `Resources/`: the same documents, filed the way a person files them.
    public static func load(from directory: URL) throws -> AppResources {
        let policies = directory
            .appending(path: "DetectionPolicies")
            .appending(path: DetectionPolicies.fileName)
        return try AppResources(
            builtins: { try BuiltinExtensions.entries(from: directory.appending(path: BuiltinExtensions.directoryName)) },
            policies: { try DetectionPolicies.load(from: policies) },
            engines: { try SearchEngines.load(from: directory.appending(path: SearchEngines.fileName)) },
            schemes: { try URLSchemes.load(from: directory.appending(path: URLSchemes.fileName)) },
            domains: { try TopLevelDomains.load(from: directory.appending(path: TopLevelDomains.fileName)) }
        )
    }

    /// One order, one set of names, whichever arrangement the files came from.
    private init(
        builtins: () throws -> [ActionCatalog.Entry],
        policies: () throws -> DetectionPolicies,
        engines: () throws -> SearchEngines,
        schemes: () throws -> URLSchemes,
        domains: () throws -> TopLevelDomains
    ) throws {
        catalog = ActionCatalog(entries: try Self.mustRead(BuiltinExtensions.directoryName, builtins))
        self.policies = try Self.mustRead(DetectionPolicies.fileName, policies)

        var failures: [Failure] = []
        self.engines = Self.mayRead(SearchEngines.fileName, engines, else: .fallback, recording: &failures)
        self.schemes = Self.mayRead(URLSchemes.fileName, schemes, else: .none, recording: &failures)
        self.domains = Self.mayRead(TopLevelDomains.fileName, domains, else: .none, recording: &failures)
        self.failures = failures
    }

    private static func mustRead<T>(_ resource: String, _ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch {
            throw Damaged(resource: resource, reason: String(describing: error))
        }
    }

    private static func mayRead<T>(
        _ resource: String,
        _ read: () throws -> T,
        else fallback: T,
        recording failures: inout [Failure]
    ) -> T {
        do {
            return try read()
        } catch {
            failures.append(Failure(resource: resource, reason: String(describing: error)))
            return fallback
        }
    }
}
