import Foundation
import PappuCore

/// What an installed PopClip has that Import from PopClip can bring across (EXM-11), read and never
/// written.
///
/// **Read-only, always.** Nothing here writes, moves, locks or deletes anything of PopClip's (ONB-6's
/// "never modify PopClip"): packages are copied by the ordinary install pipeline from their folders,
/// and the preferences are read as a file rather than through `UserDefaults`, which would put a cache
/// for PopClip's domain in this process and could write it back.
public struct PopClipImport: Sendable, Equatable {
    public struct Locations: Sendable, Equatable {
        /// `~/Library/Application Support/PopClip/Extensions`: the folder EXM-11 names, and whose being
        /// there is what makes the offer.
        public var extensions: URL
        /// Where PopClip's preferences may be, in the order they are tried; the first that reads wins.
        public var preferences: [URL]

        public init(extensions: URL, preferences: [URL]) {
            self.extensions = extensions
            self.preferences = preferences
        }

        public static var standard: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let library = home.appending(path: "Library", directoryHint: .isDirectory)
            let file = "\(PopClipExclusions.preferencesDomain).plist"
            return Locations(
                extensions: library.appending(path: "Application Support/PopClip/Extensions", directoryHint: .isDirectory),
                preferences: [
                    library.appending(path: "Preferences/\(file)"),
                    // A sandboxed copy keeps its preferences in its container. *Unverified*: whether any
                    // PopClip build is sandboxed is not known here.
                    library.appending(path: "Containers/\(PopClipExclusions.preferencesDomain)/Data/Library/Preferences/\(file)"),
                ]
            )
        }
    }

    /// The `.popclipext` folders found, sorted by name so the review lists them in a stable order.
    public var packages: [URL]
    /// Bundle identifiers PopClip is told to stay out of, in its order, without repeats.
    public var excludedApps: [String]

    public init(packages: [URL], excludedApps: [String]) {
        self.packages = packages
        self.excludedApps = excludedApps
    }

    public var isEmpty: Bool { packages.isEmpty && excludedApps.isEmpty }

    /// Whether PopClip's `Extensions` folder is there: the menu's cheap question, asked each time it opens.
    public static func isPresent(at locations: Locations = .standard) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: locations.extensions.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What there is to import, or nil when PopClip's `Extensions` folder does not exist, which is
    /// EXM-11's condition for offering at all.
    public static func find(at locations: Locations = .standard) -> PopClipImport? {
        let fileManager = FileManager.default
        guard isPresent(at: locations) else { return nil }
        let entries = (try? fileManager.contentsOfDirectory(
            at: locations.extensions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let packages = entries
            .filter { url in
                ProductIdentity.FileExtension.package.contains(url.pathExtension.lowercased())
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var excluded: [String] = []
        for url in locations.preferences {
            guard let data = try? Data(contentsOf: url) else { continue }
            excluded = PopClipExclusions.read(preferences: data)
            break
        }
        return PopClipImport(packages: packages, excludedApps: excluded)
    }
}

/// PopClip's app-exclusion list, from its preferences file (EXM-11).
///
/// **The format is unverified.** Nothing in the specifications describes it. What this reads — an array
/// of bundle-identifier strings under `BlockedApps` in `com.pilotmoon.popclip.plist` — is what PopClip's
/// support forum tells users to edit with `defaults write com.pilotmoon.popclip BlockedApps -array-add`,
/// and has not been checked against an installed copy. It is kept to this one function, tested over
/// fixture data, so that when it is checked only this changes. Anything that does not look like the
/// expected shape reads as no exclusions: importing nothing is safe, and importing a wrong list is not
/// what the user asked for.
public enum PopClipExclusions {
    public static let preferencesDomain = "com.pilotmoon.popclip"
    public static let key = "BlockedApps"

    /// The bundle identifiers, in order, trimmed, without blanks or repeats; empty for a file that is
    /// not a property list, has no such key, or holds something other than an array there.
    public static func read(preferences data: Data) -> [String] {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let array = dictionary[key] as? [Any]
        else { return [] }
        var seen: Set<String> = []
        var identifiers: [String] = []
        for case let entry as String in array {
            let identifier = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isBundleIdentifier(identifier), seen.insert(identifier).inserted else { continue }
            identifiers.append(identifier)
        }
        return identifiers
    }

    /// A reverse-DNS name, loosely: what an app rule can be keyed by. A path or a display name that
    /// found its way into the list is dropped rather than stored as a rule no app will ever match.
    static func isBundleIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty, text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }
    }
}
