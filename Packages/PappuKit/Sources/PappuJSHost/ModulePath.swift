/// Paths inside one extension's package, as the helper knows them: keys of the files it was sent,
/// never places on disk (architecture §10.3, JS-10).
///
/// Everything is relative to the package root. A path that climbs out of it is not resolved to
/// something outside — there is nothing outside to resolve to — but refused, so the error an
/// extension sees is "cannot find module" whatever it tried.
enum ModulePath {
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
    /// - Parameter base: The requiring file's path, or `""` for an action's script, which requires
    ///   from the package root.
    /// - Returns: Nil for a bare name — there are no packages to find one in yet — and for anything
    ///   not among `files`.
    static func resolve(_ request: String, from base: String, in files: Set<String>) -> String? {
        guard request.hasPrefix("./") || request.hasPrefix("../") else { return nil }
        let directory = base.split(separator: "/").dropLast().joined(separator: "/")
        guard let path = normalize(directory.isEmpty ? request : directory + "/" + request) else { return nil }
        let candidates = [path, path + ".js", path + ".json", path + "/index.js", path + "/index.json"]
        return candidates.first(where: files.contains)
    }
}
