/// Paths inside one extension's package, as the helper knows them: keys of the files it was sent,
/// never places on disk (architecture §10.3, JS-10).
///
/// Everything is relative to the package root. A path that climbs out of it is not resolved to
/// something outside — there is nothing outside to resolve to — but refused, so the error an
/// extension sees is "cannot find module" whatever it tried.
enum ModulePath {
    /// What `require(request)` finds in the package.
    enum Resolution: Equatable {
        /// This file.
        case file(String)
        /// Absolute, or leaving the package: an error whatever is there (JS-10).
        case invalid
        /// A path that could be in the package and is not. A bare name may still be a library.
        case missing
    }

    /// The suffixes tried after the name itself, in order, as Node tries them, with TypeScript's
    /// beside JavaScript's (JS-14).
    static let candidates = [".js", ".ts", ".json", "/index.js", "/index.ts", "/index.json"]

    /// `a/./b/../c.js` → `a/c.js`. Nil for a path that is absolute or climbs above the root.
    static func normalize(_ path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// The file `require(request)` means when called from `base`, among `files`.
    ///
    /// `./` and `../` are relative to the requiring file. Anything else is relative to the package
    /// root, as in PopClip; if nothing is there, the caller tries the bundled libraries.
    ///
    /// - Parameter base: The requiring file's path, or `""` for an action's script, which requires
    ///   from the package root.
    static func resolve(_ request: String, from base: String, in files: Set<String>) -> Resolution {
        let relative = request.hasPrefix("./") || request.hasPrefix("../")
        let directory = relative ? base.split(separator: "/").dropLast().joined(separator: "/") : ""
        guard let path = normalize(directory.isEmpty ? request : directory + "/" + request) else { return .invalid }
        if files.contains(path) { return .file(path) }
        return candidates.lazy.map { path + $0 }.first(where: files.contains).map(Resolution.file) ?? .missing
    }
}
