import Foundation
import PappuCore
@testable import PappuExtensions
import ZIPFoundation

/// A temporary folder per test, with helpers for writing packages into it.
final class Scratch: @unchecked Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "pappu-extensions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var paths: ExtensionLibrary.Paths { ExtensionLibrary.Paths(root: root.appending(path: "Support", directoryHint: .isDirectory)) }

    /// A package folder with a `Config.json` and any other files.
    @discardableResult
    func package(
        _ name: String = "Translate.popclipext",
        identifier: String? = "com.example.translate",
        title: String = "Translate",
        actions: [String] = ["https://example.com/?q=***"],
        files: [String: String] = [:]
    ) throws -> URL {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var config: [String: Any] = ["name": title]
        if let identifier { config["identifier"] = identifier }
        config["actions"] = actions.enumerated().map { ["title": "\(title) \($0)", "identifier": "a\($0)", "url": $1] }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: folder.appending(path: "Config.json"))
        for (path, contents) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return folder
    }

    /// `folder` zipped into `<name>z`, the way Finder's Compress does it.
    func zip(_ folder: URL) throws -> URL {
        let archive = root.appending(path: folder.lastPathComponent + "z")
        try FileManager.default.zipItem(at: folder, to: archive, shouldKeepParent: true)
        return archive
    }

    func file(_ name: String, _ contents: String) throws -> URL {
        let url = root.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Everything under `folder`, relative, for comparing trees.
    static func tree(_ folder: URL) -> Set<String> {
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        var paths: Set<String> = []
        while let path = enumerator?.nextObject() as? String {
            paths.insert(path)
        }
        return paths
    }
}

func snippet(_ name: String = "Search", identifier: String? = nil, url: String = "https://example.com/?q=***") -> String {
    var text = "#popclip\nname: \(name)\n"
    if let identifier { text += "identifier: \(identifier)\n" }
    return text + "url: \(url)\n"
}

func manifest(_ text: String) throws -> ExtensionManifest {
    try ExtensionLoader.loadSnippet(text).manifest
}

/// A reviewer that always gives the same answer and remembers what it was shown.
final class Reviews: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [ExtensionLibrary.Proposal] = []
    var answer: @Sendable (ExtensionLibrary.Proposal) -> ExtensionLibrary.Answer

    init(_ answer: @escaping @Sendable (ExtensionLibrary.Proposal) -> ExtensionLibrary.Answer = { _ in .install }) {
        self.answer = answer
    }

    var proposals: [ExtensionLibrary.Proposal] { lock.withLock { shown } }

    var reviewer: ExtensionLibrary.Reviewer {
        { proposal in
            self.lock.withLock { self.shown.append(proposal) }
            return self.answer(proposal)
        }
    }
}
