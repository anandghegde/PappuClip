import Foundation
import PappuCore
import ZIPFoundation

/// Getting a package's files into `Staging/<uuid>/` (architecture §9.4's first step).
///
/// Everything an install reads, it reads from its own copy: the original may change while the user
/// reads the review sheet, and the digest the user approved must be the digest of what activates.
///
/// **Only regular files and folders.** A symbolic link could point anywhere — including at a file
/// that changes after review — and a hard link, device or socket has no business in a package, so a
/// package holding one is refused rather than copied with the link resolved. Finder's `.DS_Store`
/// and a zip tool's `__MACOSX` folder are left out, because they are not the author's and would make
/// the same package hash differently on two Macs.
public enum PackageStaging {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAPackage(String)
        case unsupportedEntry(String)
        case escapesPackage(String)
        case tooLarge(Int)
        case unreadable(String)

        public var description: String {
            switch self {
            case .notAPackage(let reason): reason
            case .unsupportedEntry(let path): "\(path) is a link or special file; a package may hold only files and folders."
            case .escapesPackage(let path): "\(path) would be written outside the package."
            case .tooLarge(let bytes): "The package is \(bytes / 1_048_576) MB unpacked, over the limit of \(maximumBytes / 1_048_576) MB."
            case .unreadable(let reason): reason
            }
        }
    }

    /// A zip bomb's ceiling: far above any real extension (the largest in the corpus is a few MB).
    public static let maximumBytes = 256 * 1_048_576

    static func isIgnored(_ component: Substring) -> Bool {
        component == ".DS_Store" || component == "__MACOSX"
    }

    /// Relative paths of every regular file under `root`, sorted, with ignored files left out.
    /// Throws on anything that is not a regular file or a folder.
    public static func regularFiles(under root: URL) throws -> [String] {
        let fileManager = FileManager.default
        let base = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(atPath: base) else {
            throw Failure.unreadable("\(root.lastPathComponent) could not be read.")
        }
        var files: [String] = []
        while let path = enumerator.nextObject() as? String {
            if path.split(separator: "/").contains(where: isIgnored) {
                continue
            }
            let attributes = try fileManager.attributesOfItem(atPath: base + "/" + path)
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: files.append(path)
            case .typeDirectory?: continue
            default: throw Failure.unsupportedEntry(path)
            }
        }
        return files.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Copy a package folder's files into `destination`, which must not exist yet.
    public static func copyFolder(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Failure.notAPackage("\(source.lastPathComponent) is not a folder.")
        }
        let files = try regularFiles(under: source)
        var total = 0
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        for path in files {
            let target = destination.appending(path: path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source.appending(path: path), to: target)
            total += (try fileManager.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
            if total > maximumBytes { throw Failure.tooLarge(total) }
        }
    }

    /// Unpack a zipped package into `destination`, which must not exist yet, and return the package
    /// folder inside it: the archive holds one `.popclipext` or `.pappuext` folder (FMT-4).
    public static func unzip(_ archive: URL, into destination: URL) throws -> URL {
        let zip: Archive
        do {
            zip = try Archive(url: archive, accessMode: .read)
        } catch {
            throw Failure.unreadable("\(archive.lastPathComponent) is not a zip archive.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        var total = 0
        for entry in zip {
            let path = entry.path
            if path.split(separator: "/").contains(where: isIgnored) {
                continue
            }
            guard PackageFiles.isContained(path) else { throw Failure.escapesPackage(path) }
            let target = destination.appending(path: path)
            switch entry.type {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case .file:
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fileManager.createFile(atPath: target.path, contents: nil)
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                // The declared size can lie; count what is actually written.
                _ = try zip.extract(entry, skipCRC32: false) { chunk in
                    total += chunk.count
                    if total > maximumBytes { throw Failure.tooLarge(total) }
                    try handle.write(contentsOf: chunk)
                }
                // Keep the executable bit a script needs (FMT-9), and nothing more: no set-ID bits,
                // nothing writable by others.
                if let mode = entry.fileAttributes[.posixPermissions] as? NSNumber {
                    try fileManager.setAttributes([.posixPermissions: mode.int16Value & 0o755], ofItemAtPath: target.path)
                }
            case .symlink:
                throw Failure.unsupportedEntry(path)
            }
        }
        let top = try fileManager.contentsOfDirectory(atPath: destination.path).filter { !isIgnored(Substring($0)) }
        let packages = top.filter { name in
            let suffix = (name as NSString).pathExtension.lowercased()
            return ProductIdentity.FileExtension.package.contains(suffix)
        }
        guard packages.count == 1 else {
            throw Failure.notAPackage("\(archive.lastPathComponent) must hold exactly one .pappuext or .popclipext folder.")
        }
        return destination.appending(path: packages[0])
    }
}
