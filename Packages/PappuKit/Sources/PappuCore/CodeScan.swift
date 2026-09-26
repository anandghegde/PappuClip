import Foundation

/// What a static read of an extension's JavaScript found it can reach (EXM-5f, SEC-7c, architecture §9.3).
///
/// The JavaScript helper parses every script and module in the package with acorn and walks the tree for
/// the host methods that need a gate — `popclip.pressKey`, `popclip.runShellScript`, the `$` tag,
/// `XMLHttpRequest` — and for anything that would let code reach them without naming them: `popclip`
/// handed to a variable, a computed member, `eval`, `new Function`, `with`, the global object. Finding
/// one of those means the reach **cannot be bounded**, and the extension is disclosed as unbounded.
///
/// Like the rest of the analysis this is for disclosure. Nothing is granted by a scan: every sensitive
/// method is still checked against the extension's grants when a script calls it, so a scan that misses
/// something makes a sentence too narrow, never a door open.
public struct CodeScan: Sendable, Equatable, Hashable, Codable {
    /// The sensitive methods the code names, sorted, without repeats. Complete only when `isBounded`.
    public var methods: [String]
    /// Why the reach cannot be bounded, in the order found, without repeats. Empty when it can.
    public var unbounded: [Unbounded]

    public enum Unbounded: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// `popclip[name]` with a name that is not written out.
        case computedAccess = "computed-access"
        /// `popclip` used other than as the object of a member: assigned, passed, spread, returned.
        case aliasedPopclip = "aliased-popclip"
        /// `globalThis`, `window`, `self` or `global`, through which any global is reachable by name.
        case globalObject = "global-object"
        case eval
        /// `Function(…)`, or a `.constructor` that may be one.
        case functionConstructor = "function-constructor"
        case with
        /// A file that does not parse, or that the helper could not read in time.
        case unreadable
    }

    public init(methods: [String] = [], unbounded: [Unbounded] = []) {
        self.methods = Array(Set(methods)).sorted()
        self.unbounded = unbounded.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public var isBounded: Bool { unbounded.isEmpty }

    /// Script-driven synthetic input (SEC-7b): the `synthetic-input` gate.
    public static let syntheticInputMethods: Set<String> = ["pressKey", "pressKeys", "performService", "share"]
    /// External scripts (JS-5): the `script` gate. `$` is the shell template tag.
    public static let scriptMethods: Set<String> = [
        "runAppleScript", "runAppleScriptFile", "runShortcut", "runShellScript", "runShellScriptFile", "$",
    ]
    /// The network (JS-8): the `XMLHttpRequest` shim, which is also what axios and similar libraries use.
    public static let networkMethods: Set<String> = ["XMLHttpRequest"]

    /// Every method the scan looks for.
    public static let sensitiveMethods = syntheticInputMethods.union(scriptMethods).union(networkMethods)
}

/// Scans an extension's JavaScript. The app's is the JavaScript helper; nil when it could not, which
/// the analysis treats as code it cannot bound.
public protocol CodeScanning: Sendable {
    func scan(_ manifest: ExtensionManifest, in directory: URL) async -> CodeScan?
}

extension ExtensionManifest {
    /// Whether any code in it runs in the JavaScript helper: a JavaScript action or a module.
    public var hasJavaScript: Bool {
        if moduleSource != nil { return true }
        return actions.contains { if case .javaScript = $0.executor { true } else { false } }
    }
}
