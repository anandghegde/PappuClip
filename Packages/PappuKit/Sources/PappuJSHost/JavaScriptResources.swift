import Foundation
import Synchronization

/// The JavaScript the helper gives every world beyond the language: the environment's globals and the
/// libraries `require()` can load by name (JS-2, JS-9).
///
/// It is built by `Scripts/update-js-environment.sh` into this module's `JavaScript` folder and read
/// from the helper's own bundle, which the sandbox lets it read and nothing lets an extension name.
/// A library is asked for by name, and the name is looked up in `libraries.json` before any path is
/// made from it, so `require("../environment")` is a name that is not there rather than a file.
///
/// Every file is read once per process and kept: each world evaluates the text itself, so worlds
/// share the string and nothing made from it.
enum JavaScriptResources {
    /// Where the files are: the `JavaScript` folder in this module's resource bundle, which Xcode
    /// embeds in `PappuClipJSHost.xpc` and SwiftPM puts beside the tests. `Bundle.module` stops the
    /// process if that bundle is missing altogether, as it would for every package module with
    /// resources; `--check-js-host` is what shows it was embedded. A bundle without the folder is nil
    /// here, and every world reports it as a load failure.
    static let folder: URL? = Bundle.module.url(forResource: "JavaScript", withExtension: nil)

    private static let texts = Mutex<[String: String]>([:])

    /// `environment.js`: URL, Buffer and the rest, evaluated before any extension code.
    static var environment: String? {
        text(at: "environment.js")
    }

    /// The library `require(name)` means, or nil for a name that is not one. `buffer` is not here: it
    /// is the environment's.
    static func library(_ name: String) -> String? {
        guard let file = libraryFiles[name] else { return nil }
        return text(at: file)
    }

    /// The names `require()` can load that are files of their own, from `libraries.json`.
    static let libraryFiles: [String: String] = {
        struct Manifest: Decodable {
            struct Library: Decodable { var file: String }
            var libraries: [String: Library]
        }
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: "libraries.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [:] }
        return manifest.libraries.compactMapValues { $0.file.hasPrefix("libraries/") ? $0.file : nil }
    }()

    private static func text(at file: String) -> String? {
        if let kept = texts.withLock({ $0[file] }) { return kept }
        guard let folder, let text = try? String(contentsOf: folder.appending(path: file), encoding: .utf8) else { return nil }
        texts.withLock { $0[file] = text }
        return text
    }
}
