import Foundation

/// `Resources/BuiltinExtensions/`: the five P0 built-ins, each a real manifest (architecture §19 item 2).
///
/// **They are files, not code, and that is the point.** PRD principle 5 says built-ins are extensions;
/// the cheapest way to keep that true is for them to be loaded by the same reader, keyed the same way,
/// ordered in the same list and shown by the same bar as anything a user installs. What separates them
/// is one thing: their `executor` names `builtin`, and `ExtensionManifest.validate(origin:)` accepts
/// that only from `.appBundle`. Everything else about them is ordinary.
///
/// **Why the order is code.** The files are read in `BuiltinAction.allCases` order rather than by
/// sorting a directory listing, because this is the *default action order* a new install sees (ALM-3)
/// and it is the order of PRD §7.4's table, which is a product decision — not something to be changed
/// by renaming a file. Once a user reorders the list, their order is stored and this one stops
/// mattering (M4).
public enum BuiltinExtensions {
    /// The directory, beside the other bundled data.
    public static let directoryName = "BuiltinExtensions"

    /// One file per built-in, named after it, so that a missing one is a named error rather than a
    /// silently shorter bar.
    public static func fileName(for builtin: BuiltinAction) -> String {
        "\(builtin.rawValue).json"
    }

    public struct LoadFailure: Error, CustomStringConvertible, Equatable {
        public enum Reason: Sendable, Equatable {
            case unreadable(String)
            /// The file decoded but says it runs something else. A packaging mistake, and the one
            /// thing a per-file name cannot check by itself.
            case wrongExecutor(found: [ActionExecutor])
            case invalid(String)
        }

        public var builtin: BuiltinAction
        public var reason: Reason

        public var description: String {
            switch reason {
            case .unreadable(let detail):
                "\(BuiltinExtensions.fileName(for: builtin)) could not be read: \(detail)"
            case .wrongExecutor(let found):
                "\(BuiltinExtensions.fileName(for: builtin)) does not run \(builtin.rawValue); it names \(found)."
            case .invalid(let detail):
                "\(BuiltinExtensions.fileName(for: builtin)) is not a usable extension: \(detail)"
            }
        }

        public static func == (lhs: LoadFailure, rhs: LoadFailure) -> Bool {
            lhs.builtin == rhs.builtin && lhs.description == rhs.description
        }
    }

    /// Every built-in, in order, from a directory of manifests.
    public static func load(from directory: URL) throws -> [ExtensionManifest] {
        try BuiltinAction.allCases.map { builtin in
            try load(builtin, from: directory.appending(path: fileName(for: builtin)))
        }
    }

    public static func bundled(in bundle: Bundle) throws -> [ExtensionManifest] {
        try BuiltinAction.allCases.map { builtin in
            guard let url = bundle.url(
                forResource: builtin.rawValue,
                withExtension: "json",
                subdirectory: directoryName
            ) else {
                throw LoadFailure(builtin: builtin, reason: .unreadable("not in the app bundle"))
            }
            return try load(builtin, from: url)
        }
    }

    /// One file, checked against the built-in it claims to be.
    public static func load(_ builtin: BuiltinAction, from url: URL) throws -> ExtensionManifest {
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: url))
        } catch {
            throw LoadFailure(builtin: builtin, reason: .unreadable(String(describing: error)))
        }
        do {
            try manifest.validate(origin: .appBundle)
        } catch {
            throw LoadFailure(builtin: builtin, reason: .invalid(String(describing: error)))
        }
        let executors = manifest.actions.map(\.executor)
        guard executors == [.builtin(builtin)] else {
            throw LoadFailure(builtin: builtin, reason: .wrongExecutor(found: executors))
        }
        return manifest
    }

    /// The catalog entries a fresh install starts from (ALM-3).
    public static func entries(from directory: URL) throws -> [ActionCatalog.Entry] {
        try load(from: directory).map { ActionCatalog.Entry(manifest: $0, origin: .appBundle) }
    }

    public static func entries(in bundle: Bundle) throws -> [ActionCatalog.Entry] {
        try bundled(in: bundle).map { ActionCatalog.Entry(manifest: $0, origin: .appBundle) }
    }
}
