import CryptoKit
import Foundation
import JavaScriptCore
import Synchronization

/// TypeScript and ES module syntax to CommonJS, through sucrase (JS-10, JS-14, architecture §10.1).
///
/// **The tooling world.** Sucrase runs in a virtual machine of its own, made the first time anything
/// needs transpiling and kept for the life of the helper. No extension code runs in it: an
/// extension's source reaches it only as a string argument to `transform`, which parses and prints
/// and evaluates nothing. So the one virtual machine the extensions share holds nothing an extension
/// could reach, and it costs one load of sucrase (about 40 ms without the JIT) instead of one per
/// world.
///
/// **The cache.** Output is kept by a digest of the kind and the source, so a world that is made
/// again, or a second extension with the same file, is not transpiled twice: about 10 to 30 ms for a
/// 6 KB file without the JIT. It is bounded by size and emptied when full. Two extensions that send
/// the same text get the same output, which they could each have computed, so sharing it tells
/// neither anything.
///
/// Types are removed, not checked (JS-14). Newer syntax is left alone (`disableESTransforms`): the
/// engine runs it, and leaving it keeps error columns where the author wrote them. Sucrase keeps line
/// numbers, so an error's line is the author's line either way.
final class Transpiler: Sendable {
    enum Kind: String, Sendable {
        /// A `.ts` file or a TypeScript action: types removed, `import` and `export` made CommonJS.
        case typeScript = "typescript"
        /// A `.mjs` file, or a `.js` file with `import` or `export` statements.
        case module
    }

    static let shared = Transpiler()

    /// The most output kept, in UTF-16 code units, before the cache is emptied.
    static let cacheLimit = 8 << 20

    private struct State {
        var context: JSContext?
        var transform: JSValue?
        var failure: String?
        var cache: [SHA256.Digest: String] = [:]
        var cached = 0
    }

    /// `JSContext` and `JSValue` are safe to use from any thread that holds this lock; the lock is
    /// what makes one transform happen at a time.
    private let state = Mutex<State>(State())

    /// The CommonJS text, or why the source would not transpile.
    func transform(_ source: String, as kind: Kind) -> Result<String, TranspileError> {
        state.withLock { state in
            // Made inside the lock, so nothing from outside is stored into the state it guards.
            let key = SHA256.hash(data: Data((kind.rawValue + "\u{0}" + source).utf8))
            if let kept = state.cache[key] { return .success(kept) }
            guard let transform = Self.prepare(&state) else {
                return .failure(TranspileError(message: state.failure ?? "The transpiler is missing from the helper."))
            }
            let transforms = kind == .typeScript ? ["typescript", "imports"] : ["imports"]
            let result = transform.call(withArguments: [source, transforms])
            if let code = result?.objectForKeyedSubscript("code"), code.isString, let text = code.toString() {
                if state.cached + text.utf16.count > Self.cacheLimit {
                    state.cache = [:]
                    state.cached = 0
                }
                state.cache[key] = text
                state.cached += text.utf16.count
                return .success(text)
            }
            let error: JSValue? = result?.objectForKeyedSubscript("error")
            let message: String? = error?.isString == true ? error?.toString() : nil
            return .failure(TranspileError(message: message ?? "The source could not be transpiled."))
        }
    }

    /// Loads sucrase once. Nil, with `failure` set, if it cannot be.
    private static func prepare(_ state: inout State) -> JSValue? {
        if let transform = state.transform { return transform }
        if state.failure != nil { return nil }
        guard let sucrase = JavaScriptResources.library("sucrase"),
              let context = JSContext(virtualMachine: JSVirtualMachine())
        else {
            state.failure = "The transpiler is missing from the helper."
            return nil
        }
        context.name = "Transpiler"
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value.map(ExtensionVM.describe) }
        let wrapper = context.evaluateScript(Self.wrapper, withSourceURL: URL(string: "pappuclip:transpiler"))
        let transform = wrapper?.call(withArguments: [sucrase])
        if let thrown {
            state.failure = "The transpiler would not load: \(thrown)"
            return nil
        }
        guard let transform, transform.isObject else {
            state.failure = "The transpiler would not load."
            return nil
        }
        context.exceptionHandler = { _, _ in }
        state.context = context
        state.transform = transform
        return transform
    }

    /// Evaluates sucrase's bundle as a CommonJS module and returns a function that never throws: it
    /// answers `{ code }` or `{ error }`.
    private static let wrapper = #"""
    (function (text) {
      'use strict';
      const module = { exports: {} };
      (0, eval)('(function (exports, require, module) {' + text + '\n})\n//# sourceURL=pappuclip:library/sucrase')
        .call(module.exports, module.exports, function (name) { throw new Error("Cannot find module '" + name + "'"); }, module);
      const sucrase = module.exports;
      return function (source, transforms) {
        try {
          return { code: sucrase.transform(source, { transforms: transforms, disableESTransforms: true, production: true }).code };
        } catch (error) {
          return { error: error !== null && typeof error === 'object' && typeof error.message === 'string' ? error.message : String(error) };
        }
      };
    })
    """#
}

struct TranspileError: Error, Equatable {
    var message: String
}
