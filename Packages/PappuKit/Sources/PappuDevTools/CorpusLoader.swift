import Foundation
import PappuCore

/// Loads every extension in a frozen corpus and says how many made it (implementation plan M2 week 1).
///
/// The corpus is PopClip's own extensions repository at a pinned commit (`Tests/corpus`), which is the
/// largest body of real manifests there is: a decade of hand-written plists, JSON and YAML. The bar it
/// sets is the plan's: **non-JavaScript extensions load, and JavaScript ones parse**, meaning their
/// manifest builds and waits only for the M3 runtime.
///
/// Some upstream extensions are broken upstream — an empty `Config.json`, a plist with a key inside an
/// array. Those are listed, with the reason, in `Tests/corpus-expected-failures.txt`, and the check
/// fails both when something unlisted fails and when something listed starts loading, so that the list
/// never goes stale in either direction.
public enum CorpusLoader {
    public enum Outcome: Sendable, Equatable {
        case loaded(warnings: [String])
        case needsJavaScript(warnings: [String])
        case failed([String])

        public var isLoaded: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    public struct Entry: Sendable, Equatable {
        /// Relative to the corpus root.
        public var path: String
        public var outcome: Outcome
    }

    public struct Report: Sendable, Equatable {
        public var entries: [Entry]
        public var expectedFailures: [String: String]

        public var loaded: Int { entries.count { if case .loaded = $0.outcome { true } else { false } } }
        public var needsJavaScript: Int { entries.count { if case .needsJavaScript = $0.outcome { true } else { false } } }
        public var failed: [Entry] { entries.filter { !$0.outcome.isLoaded } }
        public var warnings: Int {
            entries.reduce(0) { total, entry in
                switch entry.outcome {
                case .loaded(let warnings), .needsJavaScript(let warnings): total + warnings.count
                case .failed: total
                }
            }
        }

        /// Failures nobody expected.
        public var unexpectedFailures: [Entry] { failed.filter { expectedFailures[$0.path] == nil } }
        /// Listed as failing, and loading now.
        public var staleExpectations: [String] {
            let loadedPaths = Set(entries.filter(\.outcome.isLoaded).map(\.path))
            let present = Set(entries.map(\.path))
            return expectedFailures.keys.filter { loadedPaths.contains($0) || !present.contains($0) }.sorted()
        }

        public var allWarnings: [(path: String, warning: String)] {
            entries.flatMap { entry -> [(path: String, warning: String)] in
                switch entry.outcome {
                case .loaded(let warnings), .needsJavaScript(let warnings): warnings.map { (entry.path, $0) }
                case .failed: []
                }
            }
        }

        public var passed: Bool { unexpectedFailures.isEmpty && staleExpectations.isEmpty }

        public var rateText: String {
            let total = entries.count
            let loadedCount = loaded + needsJavaScript
            let percent = total == 0 ? 0 : Double(loadedCount) / Double(total) * 100
            return String(format: "%d/%d loaded (%.1f%%): %d ready, %d waiting on the JavaScript runtime, %d failed (%d expected), %d warnings",
                          loadedCount, total, percent, loaded, needsJavaScript, failed.count, failed.count - unexpectedFailures.count, warnings)
        }
    }

    public static let expectedFailuresPath = "Tests/corpus-expected-failures.txt"

    /// Every package and snippet file under `root`, in path order.
    public static func discover(in root: URL) -> [URL] {
        let packageExtensions = Set(ProductIdentity.FileExtension.package)
        let snippetExtensions = Set(ProductIdentity.FileExtension.snippet)
        var found: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        for case let url as URL in enumerator {
            let pathExtension = url.pathExtension.lowercased()
            if packageExtensions.contains(pathExtension) {
                found.append(url)
                // A package's contents are its own; a nested `.popclipext` is a file it ships.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
            } else if snippetExtensions.contains(pathExtension) {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    public static func load(_ url: URL) -> Outcome {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        do {
            let loaded: ExtensionLoader.Loaded
            if isDirectory {
                loaded = try ExtensionLoader.loadPackage(at: url)
            } else {
                // A snippet file, or a `.popclipext` that is really one.
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return .failed(["Not UTF-8 text."])
                }
                loaded = try ExtensionLoader.loadSnippet(text)
            }
            return loaded.needsJavaScriptRuntime
                ? .needsJavaScript(warnings: loaded.warnings.map(\.description))
                : .loaded(warnings: loaded.warnings.map(\.description))
        } catch {
            return .failed(error.errors.map(\.description))
        }
    }

    public static func run(corpus: URL, expectedFailures: [String: String]) -> Report {
        let rootPath = corpus.standardizedFileURL.path
        let entries = discover(in: corpus).map { url in
            var path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") { path.removeFirst(rootPath.count + 1) }
            return Entry(path: path, outcome: load(url))
        }
        return Report(entries: entries, expectedFailures: expectedFailures)
    }

    /// `path  # reason` per line; blank lines and lines starting with `#` are comments.
    public static func parseExpectedFailures(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "#", maxSplits: 1)
            let path = parts[0].trimmingCharacters(in: .whitespaces)
            let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            result[path] = reason
        }
        return result
    }
}
