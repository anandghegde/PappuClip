import Foundation
import JavaScriptCore
import PappuJSBridge

/// One extension's JavaScript world (SEC-1b, architecture §10.1).
///
/// **Nothing is shared with another.** Its own `JSVirtualMachine`, so its own heap and garbage
/// collector and no way to hold a reference into another's; its own global object; its own module
/// cache, which lives in its own prelude; and its own serial queue, because a virtual machine runs
/// one thread at a time and a slow extension should hold up itself and nobody else.
///
/// **What it can reach** is what JavaScriptCore gives any context — the language and its built-ins —
/// plus three things of ours: `print` (and `console`, which is the same thing), `require` over the
/// files it was loaded with, and a frozen `popclip` describing the invocation (JS-1, JS-3). There is
/// no `fetch`, no DOM, no `process`, no file system: JavaScriptCore has none of them, and the helper's
/// sandbox would refuse them if it did (SEC-1a).
///
/// Everything but `init` runs on `queue`. The host puts it there.
final class ExtensionVM: @unchecked Sendable {
    typealias Reply = @Sendable (JSHostReply) -> Void

    let name: String
    let generation: String
    let queue: DispatchQueue

    private let files: [String: String]
    private let log: @Sendable (String) -> Void
    private var context: JSContext?
    /// The prelude's `run`, which compiles and starts one action's script.
    private var runner: JSValue?
    /// Invocations started and not yet settled or dropped. Their replies are owed.
    private var pending: [UInt64: Reply] = [:]

    /// The longest line `print` sends. The console is for reading, and a script printing a megabyte
    /// at a time should not be able to make the app hold it.
    static let lineLimit = 4_096

    init(load: JSLoad, log: @escaping @Sendable (String) -> Void) {
        name = load.extensionName
        generation = load.generation
        var files: [String: String] = [:]
        for (path, text) in load.files {
            if let path = ModulePath.normalize(path) { files[path] = text }
        }
        self.files = files
        self.log = log
        queue = DispatchQueue(label: "app.pappuclip.jshost.vm", qos: .userInitiated)
    }

    // MARK: Lifecycle

    /// Builds the world. Nil on success, else why not.
    func prepare() -> String? {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { return "No JavaScript context." }
        context.name = name
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value.map(Self.describe) }

        let native = JSValue(newObjectIn: context)!
        let names = Set(files.keys)
        let log: @convention(block) (String) -> Void = { [log] line in
            log(line.count > Self.lineLimit ? String(line.prefix(Self.lineLimit)) + "…" : line)
        }
        let resolve: @convention(block) (String, String) -> Any = { base, request in
            if let path = ModulePath.resolve(request, from: base, in: names) { return path }
            return NSNull()
        }
        let source: @convention(block) (String) -> Any = { [files] path in
            if let text = files[path] { return text }
            return NSNull()
        }
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(resolve, forKeyedSubscript: "resolve" as NSString)
        native.setObject(source, forKeyedSubscript: "source" as NSString)

        let prelude = context.evaluateScript(Self.prelude, withSourceURL: URL(string: "pappuclip:prelude"))
        runner = prelude?.call(withArguments: [context.globalObject as Any, native])
        if let thrown { return thrown }
        guard let runner, runner.isObject else { return "The prelude did not start." }
        // From here on, what a script throws reaches it through the prelude's own catch, and the
        // handler only sees what escapes that — which is nothing the prelude lets go.
        context.exceptionHandler = { _, _ in }
        self.context = context
        return nil
    }

    /// Answers everything still owed, `dropped`. Called when the world is replaced or unloaded; the
    /// context goes with the last reference to this object.
    func abandon() {
        let owed = pending
        pending = [:]
        for reply in owed.values { reply(.dropped) }
        runner = nil
        context = nil
    }

    // MARK: Invoking

    /// Starts one action. `reply` is called once, now or when its promise settles, or by `drop`.
    func invoke(_ invocation: JSInvoke, reply: @escaping Reply) {
        guard let context, let runner else { return reply(.notLoaded) }
        let source: String
        let url: String
        let base: String
        switch invocation.entry {
        case .inline(let text):
            source = text
            url = "pappuclip:action"
            base = ""
        case .file(let path):
            guard let path = ModulePath.normalize(path), let text = files[path] else {
                return reply(.threw("Cannot find the script \(path)."))
            }
            source = text
            url = path
            base = path
        }
        pending[invocation.invocation] = reply
        let id = invocation.invocation
        let settle: @convention(block) (String, JSValue) -> Void = { [weak self] kind, value in
            guard let self, let reply = self.pending.removeValue(forKey: id) else { return }
            switch kind {
            case "returned": reply(.returned(value.isString ? value.toString() : nil))
            default: reply(.threw(value.isString ? value.toString() : "An error was thrown."))
            }
        }
        let state: [String: Any] = [
            "input": ["text": invocation.input.text, "matchedText": invocation.input.matchedText],
            "options": invocation.options,
        ]
        runner.invokeMethod("run", withArguments: [source, url, base, state, JSValue(object: settle, in: context) as Any])
    }

    /// Stops waiting for an invocation, and answers it `dropped`. Whatever its script does afterwards
    /// settles into nothing.
    func drop(_ invocation: UInt64) {
        pending.removeValue(forKey: invocation)?(.dropped)
    }

    var pendingCount: Int { pending.count }

    // MARK: The prelude

    static func describe(_ value: JSValue) -> String {
        if value.isObject, let message = value.objectForKeyedSubscript("message"), message.isString {
            return message.toString()
        }
        return value.toString() ?? "An error was thrown."
    }

    /// The part of the world written in JavaScript: the module loader and its cache, `print`, and the
    /// wrapper an action's script runs in (§8.8, JS-10, JS-11).
    ///
    /// It captures what it relies on — `eval`, `Object.freeze`, `Object.defineProperty` — before any
    /// extension code runs, so an extension that replaces them changes its own globals and not the
    /// prelude's behaviour. It cannot protect an extension from itself (a script that replaces
    /// `Promise.prototype.then` can stop its own action from ever answering) and does not try: that
    /// action is then cancelled like any other that hangs.
    static let prelude = #"""
    (function (global, native) {
      'use strict';
      const indirectEval = global.eval;
      const freeze = Object.freeze;
      const define = Object.defineProperty;
      const hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
      const cache = Object.create(null);

      function describe(error) {
        if (error !== null && typeof error === 'object' && typeof error.message === 'string') return error.message;
        return String(error);
      }

      function format(value) {
        if (typeof value === 'string') return value;
        try {
          const json = JSON.stringify(value);
          return json === undefined ? String(value) : json;
        } catch (error) {
          return String(value);
        }
      }

      function load(path) {
        if (hasOwn(cache, path)) return cache[path].exports;
        const module = { id: path, exports: {}, loaded: false };
        cache[path] = module;
        try {
          const text = native.source(path);
          if (path.endsWith('.json')) {
            module.exports = JSON.parse(text);
          } else {
            const factory = indirectEval('(function (exports, require, module) {' + text + '\n})\n//# sourceURL=' + path);
            factory.call(module.exports, module.exports, requireFrom(path), module);
          }
        } catch (error) {
          delete cache[path];
          throw error;
        }
        module.loaded = true;
        return module.exports;
      }

      function requireFrom(base) {
        return function require(request) {
          const path = native.resolve(base, String(request));
          if (typeof path !== 'string') {
            const error = new Error("Cannot find module '" + request + "'");
            error.code = 'MODULE_NOT_FOUND';
            throw error;
          }
          return load(path);
        };
      }

      const print = function () {
        native.log(Array.prototype.map.call(arguments, format).join(' '));
      };
      const console = freeze({ log: print, info: print, warn: print, error: print, debug: print });
      define(global, 'print', { value: print, writable: true, configurable: true });
      define(global, 'console', { value: console, writable: true, configurable: true });

      return freeze({
        run: function (source, url, base, state, settle) {
          let body;
          try {
            body = indirectEval('(async function (require) {' + source + '\n})\n//# sourceURL=' + url);
          } catch (error) {
            settle('threw', describe(error));
            return;
          }
          const popclip = freeze({ input: freeze(state.input), options: freeze(state.options) });
          define(global, 'popclip', { value: popclip, writable: false, configurable: true });
          let promise;
          try {
            promise = body.call(undefined, requireFrom(base));
          } catch (error) {
            settle('threw', describe(error));
            return;
          }
          promise.then(
            function (value) { settle('returned', typeof value === 'string' ? value : null); },
            function (error) { settle('threw', describe(error)); }
          );
        }
      });
    })
    """#
}
