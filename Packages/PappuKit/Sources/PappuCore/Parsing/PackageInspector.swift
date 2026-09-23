import Foundation

/// The files of one package, as the builder may ask about them.
///
/// Every question is about a path *inside* the package. A path that is absolute or climbs out with
/// `..` is refused before the file system is asked, so that a manifest cannot learn whether
/// `/etc/passwd` exists, let alone name it as its script.
public struct PackageFiles: Sendable, Equatable {
    public var root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Relative, and never above the root at any point.
    public static func isContained(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        var depth = 0
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": depth -= 1
            default: depth += 1
            }
            if depth < 0 { return false }
        }
        return true
    }

    public func url(for path: String) -> URL? {
        guard Self.isContained(path) else { return nil }
        let url = root.appending(path: path).standardizedFileURL
        // Symbolic links are resolved here, so that a link out of the package is outside it.
        let resolved = url.resolvingSymlinksInPath().path
        let rootPath = root.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { return nil }
        return url
    }

    /// A regular file at `path`.
    public func contains(_ path: String) -> Bool {
        guard let url = url(for: path) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// §8.4: executable, and starting with `#!`.
    public func isExecutableScript(_ path: String) -> Bool {
        guard let url = url(for: path), FileManager.default.isExecutableFile(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
    }
}

/// FMT-4: which file in a package is its config.
///
/// Exactly one file in the package's root whose name is `Config` or starts `Config.` — case-sensitive,
/// because `config.json` next to `Config.plist` is a package that says two things. The extension picks
/// the parser: `plist`, `json` and `yaml` are what they say, and anything else, a bare `Config`
/// included, is a code snippet (FMT-2). `_Signature.plist` is PopClip's and is ignored; subfolders are
/// the package's business.
public enum PackageInspector {
    public enum ConfigKind: Sendable, Equatable {
        case data(ConfigFormat)
        /// A code snippet, with the language its extension implies, if any.
        case code(ScriptLanguage?)
    }

    public struct Config: Sendable, Equatable {
        public var fileName: String
        public var kind: ConfigKind
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case noConfig
        case severalConfigs([String])

        public var description: String {
            switch self {
            case .unreadable(let reason): "The package could not be read: \(reason)"
            case .noConfig: "The package has no Config file in its top folder."
            case .severalConfigs(let names): "The package has \(names.count) Config files (\(names.joined(separator: ", "))); it must have one."
            }
        }
    }

    public static func config(in names: [String]) throws(Failure) -> Config {
        let candidates = names.filter { $0 == "Config" || $0.hasPrefix("Config.") }.sorted()
        guard let name = candidates.first else { throw .noConfig }
        guard candidates.count == 1 else { throw .severalConfigs(candidates) }
        let kind: ConfigKind = switch (name as NSString).pathExtension {
        case "plist": .data(.plist)
        case "json": .data(.json)
        case "yaml": .data(.yaml)
        case "js": .code(.javascript)
        case "ts": .code(.typescript)
        case "applescript": .code(.applescript)
        default: .code(nil)
        }
        return Config(fileName: name, kind: kind)
    }

    public static func config(at root: URL) throws(Failure) -> Config {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map(\.lastPathComponent)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        return try config(in: names)
    }
}
