import Foundation

/// A package or snippet, from bytes to a checked manifest (architecture §9.1's whole pipeline).
///
/// Detect (`SnippetDetector`, `PackageInspector`), decode (`ConfigDecoding`), build and validate
/// (`ManifestBuilder`). Each stage's failure becomes a `ManifestLoadFailure` with one error that says
/// which stage refused, so that every way a load can fail reaches the user as the same kind of thing.
///
/// A module extension's actions do not exist until the JavaScript helper has described its module
/// (JS-12), which it may do only once the extension is approved. Loaded from its files alone it has
/// its config's actions, usually none; loaded again with `Settings.moduleExports`, it has its module's.
public enum ExtensionLoader {
    public struct Loaded: Sendable, Equatable {
        public var manifest: ExtensionManifest
        public var warnings: [ManifestDiagnostic]
        /// The config file inside a package; nil for a snippet.
        public var configFile: String?

        public var needsJavaScriptRuntime: Bool { manifest.needsJavaScriptRuntime }
    }

    public struct Settings: Sendable {
        public var origin: ManifestOrigin
        public var ignoresAPILevel: Bool
        /// JS-12: what the extension's module exported, when the helper has described it.
        public var moduleExports: ModuleExports?

        public init(origin: ManifestOrigin = .installed, ignoresAPILevel: Bool = false, moduleExports: ModuleExports? = nil) {
            self.origin = origin
            self.ignoresAPILevel = ignoresAPILevel
            self.moduleExports = moduleExports
        }
    }

    /// A package folder (FMT-4).
    public static func loadPackage(at root: URL, settings: Settings = Settings()) throws(ManifestLoadFailure) -> Loaded {
        let config: PackageInspector.Config
        do {
            config = try PackageInspector.config(at: root)
        } catch {
            throw ManifestLoadFailure(error.description)
        }
        let data: Data
        do {
            data = try Data(contentsOf: root.appending(path: config.fileName))
        } catch {
            throw ManifestLoadFailure("\(config.fileName) could not be read: \(error.localizedDescription)", at: config.fileName)
        }
        let files = PackageFiles(root: root)

        let input: ManifestBuilder.Input
        switch config.kind {
        case .data(let format):
            let value: ConfigValue
            do {
                value = try ConfigDecoding.decode(data, as: format)
            } catch {
                throw ManifestLoadFailure(String(describing: error), at: config.fileName)
            }
            input = ManifestBuilder.Input(
                config: value,
                package: files,
                moduleExports: settings.moduleExports,
                ignoresAPILevel: settings.ignoresAPILevel,
                origin: settings.origin
            )
        case .code(let language):
            guard let text = String(data: data, encoding: .utf8) else {
                throw ManifestLoadFailure("\(config.fileName) is not UTF-8 text.", at: config.fileName)
            }
            input = try codeInput(text, language: language, package: files, settings: settings, file: config.fileName)
        }

        do {
            let built = try ManifestBuilder.build(input)
            return Loaded(manifest: built.manifest, warnings: built.warnings.map { prefixed($0, config.fileName) }, configFile: config.fileName)
        } catch {
            throw ManifestLoadFailure(
                errors: error.errors.map { prefixed($0, config.fileName) },
                warnings: error.warnings.map { prefixed($0, config.fileName) }
            )
        }
    }

    /// Snippet text (FMT-1–3), from a `.popcliptxt` file or a selection.
    public static func loadSnippet(_ text: String, settings: Settings = Settings()) throws(ManifestLoadFailure) -> Loaded {
        guard let detected = SnippetDetector.detect(text) else {
            throw ManifestLoadFailure("The text does not start with #popclip or #pappuclip.")
        }
        let input: ManifestBuilder.Input
        switch detected {
        case .config(let yaml):
            input = ManifestBuilder.Input(
                config: try decodeYAML(yaml, file: nil),
                ignoresAPILevel: settings.ignoresAPILevel,
                origin: settings.origin
            )
        case .code:
            input = try codeInput(text, language: nil, package: nil, settings: settings, file: nil)
        }
        let built = try ManifestBuilder.build(input)
        return Loaded(manifest: built.manifest, warnings: built.warnings, configFile: nil)
    }

    private static func codeInput(
        _ text: String,
        language: ScriptLanguage?,
        package: PackageFiles?,
        settings: Settings,
        file: String?
    ) throws(ManifestLoadFailure) -> ManifestBuilder.Input {
        guard case .code(let yaml, let body)? = SnippetDetector.detect(text, impliedLanguage: language) else {
            throw ManifestLoadFailure("There is no #popclip comment header to read the config from (FMT-2).", at: file ?? "")
        }
        return ManifestBuilder.Input(
            config: try decodeYAML(yaml, file: file),
            package: package,
            code: body,
            codeFile: package == nil ? nil : file,
            moduleExports: settings.moduleExports,
            ignoresAPILevel: settings.ignoresAPILevel,
            origin: settings.origin
        )
    }

    private static func decodeYAML(_ yaml: String, file: String?) throws(ManifestLoadFailure) -> ConfigValue {
        do {
            return try ConfigDecoding.decodeYAML(yaml)
        } catch {
            throw ManifestLoadFailure(String(describing: error), at: file ?? "")
        }
    }

    private static func prefixed(_ diagnostic: ManifestDiagnostic, _ file: String) -> ManifestDiagnostic {
        var diagnostic = diagnostic
        diagnostic.path = diagnostic.path.isEmpty ? file : "\(file): \(diagnostic.path)"
        return diagnostic
    }
}

extension ExtensionManifest {
    /// Whether anything in it waits on the JavaScript runtime (M3): a module, or a JavaScript action.
    public var needsJavaScriptRuntime: Bool {
        if let module, module != .detection(false) { return true }
        return actions.contains { $0.executor.kind == .javaScript }
    }
}
