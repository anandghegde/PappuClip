import AppKit
import Foundation

/// The Tier A app matrix of PRD §11.5 as data. Spike 3 and the per-release matrix run iterate it.
///
/// This type names apps, which is why it lives in the harness and not in a module the shipping app
/// links: diagnostics payloads may never carry an app name (DIA-4).
public struct AppMatrix: Sendable, Equatable, Codable {
    public enum Tier: String, Sendable, Codable, CaseIterable {
        /// Auto-appear must work; 100% is a release gate.
        case gating
        /// Measured and published each release, but does not gate it.
        case tracked
    }

    public struct App: Sendable, Equatable, Codable, Identifiable {
        public var name: String
        public var tier: Tier
        /// More than one where a vendor ships several builds under different identifiers.
        public var bundleIDs: [String]
        public var family: String
        public var bundleIDsVerified: Bool

        public var id: String { name }
    }

    public struct Installed: Sendable, Equatable {
        public var app: App
        public var bundleID: String
        public var url: URL
        public var version: String?
    }

    public var schema: Int
    public var source: String
    public var note: String
    public var apps: [App]

    public static func bundled() throws -> AppMatrix {
        guard let url = Bundle.module.url(forResource: "app-matrix", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(AppMatrix.self, from: Data(contentsOf: url))
    }

    public func apps(in tier: Tier) -> [App] {
        apps.filter { $0.tier == tier }
    }

    /// The matrix apps present on this machine. A missing app is a gap in the run, never a pass.
    @MainActor
    public func installedApps() -> [Installed] {
        apps.compactMap { app in
            for bundleID in app.bundleIDs {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
                let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                return Installed(app: app, bundleID: bundleID, url: url, version: version)
            }
            return nil
        }
    }
}
