import Foundation

/// A module extension's module (JS-12): what the JavaScript helper runs to learn the extension's
/// actions, and runs again to call one.
///
/// A file in the package — `Config.js`, `Config.ts`, or what `module` names — or, for a snippet, the
/// snippet's own text, since a snippet has no files.
public struct ModuleSource: Sendable, Equatable, Hashable, Codable {
    public var source: ScriptSource
    /// TypeScript is transpiled before it runs (JS-14). For a file the helper also goes by its name.
    public var isTypeScript: Bool

    public init(source: ScriptSource, isTypeScript: Bool) {
        self.source = source
        self.isTypeScript = isTypeScript
    }
}

/// What a module extension exported, as the JavaScript helper describes it (JS-12): data, never code.
///
/// **What code there is, and where.** The helper evaluates the module and hands back its extension
/// object with every function taken out. An action whose code is a function — its `code`, or the
/// action itself — says `code: true`, and nothing else in the object can say that: the helper drops a
/// `code` that is not a function. The top-level functions that are not actions (a population function,
/// `auth`, `test`) are listed by name in `functions`.
///
/// **Only ever from approved bytes.** Describing a module runs it, so it happens after the extension's
/// approval and never at install (architecture §10.2: `load` needs an `ExecutionApproval`).
/// `ManifestBuilder` then reads this with the same rules as a config, so a module's actions are
/// checked exactly as a config's would be, and every one of them is JavaScript.
public struct ModuleExports: Sendable, Equatable {
    /// The exported extension object.
    public var object: ConfigValue
    /// Its top-level keys whose value is a function.
    public var functions: [String]

    public init(object: ConfigValue, functions: [String] = []) {
        self.object = object
        self.functions = functions
    }

    /// From the helper's JSON. Read as YAML 1.2, of which JSON is a subset, because the YAML reader
    /// keeps keys in the order the module wrote them and the JSON one does not.
    public init(json: String, functions: [String]) throws {
        self.init(object: try ConfigDecoding.decodeYAML(json), functions: functions)
    }
}
