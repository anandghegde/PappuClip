import Foundation
import JavaScriptCore
import PappuJSBridge

/// One extension's JavaScript world (SEC-1b, architecture §10.1).
///
/// **Nothing is shared with another.** Its own `JSVirtualMachine`, so its own heap and garbage
/// collector and no way to hold a reference into another's; its own global object; its own module
/// cache, library cache and timers, which live in its own prelude; and its own serial queue, because
/// a virtual machine runs one thread at a time and a slow extension should hold up itself and nobody
/// else. The text of the environment and of the libraries is shared, and each world evaluates it for
/// itself, so two worlds' `Buffer` or `require("axios")` are different objects.
///
/// **What it can reach** is the language, the environment's globals (JS-2: `URL`, `Buffer`, timers,
/// `sleep` and the rest), `print` and `console`, `require` over the files it was loaded with and the
/// bundled libraries (JS-9, JS-10), and a frozen `popclip` describing the invocation (JS-3). There is
/// no `fetch`, no DOM, no `process`, no file system: JavaScriptCore has none of them, and the helper's
/// sandbox would refuse them if it did (SEC-1a).
///
/// Everything but `init` runs on `queue`. The host puts it there, and timers fire there.
final class ExtensionVM: @unchecked Sendable {
    typealias Reply = @Sendable (JSHostReply) -> Void

    let name: String
    let generation: String
    let queue: DispatchQueue

    private let files: [String: String]
    private let log: @Sendable (String) -> Void
    private let transpiler: Transpiler
    private var context: JSContext?
    /// The prelude's `run` and `fire`.
    private var runner: JSValue?
    /// Invocations started and not yet settled or dropped. Their replies are owed.
    private var pending: [UInt64: Reply] = [:]

    /// The longest line `print` sends. The console is for reading, and a script printing a megabyte
    /// at a time should not be able to make the app hold it.
    static let lineLimit = 4_096

    /// The longest a timer waits, as in a browser: about 24.8 days.
    static let longestDelay: Double = 2_147_483_647

    init(load: JSLoad, transpiler: Transpiler = .shared, log: @escaping @Sendable (String) -> Void) {
        name = load.extensionName
        generation = load.generation
        var files: [String: String] = [:]
        for (path, text) in load.files {
            if let path = ModulePath.normalize(path) { files[path] = text }
        }
        self.files = files
        self.transpiler = transpiler
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

        // What the prelude asks of the host. None of these holds the world strongly: the world holds
        // them, through `native`, and a timer that outlives the world finds nothing to fire.
        let native = JSValue(newObjectIn: context)!
        let names = Set(files.keys)
        let log: @convention(block) (String) -> Void = { [log] line in
            log(line.count > Self.lineLimit ? String(line.prefix(Self.lineLimit)) + "…" : line)
        }
        // A path; `false` for a request that is absolute or leaves the package; `null` for nothing there.
        let resolve: @convention(block) (String, String) -> JSValue = { base, request in
            let current = JSContext.current()
            switch ModulePath.resolve(request, from: base, in: names) {
            case .file(let path): return JSValue(object: path, in: current)
            case .invalid: return JSValue(bool: false, in: current)
            case .missing: return JSValue(nullIn: current)
            }
        }
        let source: @convention(block) (String) -> Any = { [files] path in
            if let text = files[path] { return text }
            return NSNull()
        }
        let environment: @convention(block) () -> Any = {
            if let text = JavaScriptResources.environment { return text }
            return NSNull()
        }
        let library: @convention(block) (String) -> Any = { name in
            if let text = JavaScriptResources.library(name) { return text }
            return NSNull()
        }
        // The CommonJS text, or `{ error }`.
        let transpile: @convention(block) (String, String) -> Any = { [transpiler] text, name in
            guard let kind = Transpiler.Kind(rawValue: name) else { return ["error": "Nothing transpiles as \(name)."] }
            switch transpiler.transform(text, as: kind) {
            case .success(let code): return code
            case .failure(let error): return ["error": error.message]
            }
        }
        let schedule: @convention(block) (Double, Double) -> Void = { [weak self] id, milliseconds in
            self?.schedule(timer: id, after: milliseconds)
        }
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(resolve, forKeyedSubscript: "resolve" as NSString)
        native.setObject(source, forKeyedSubscript: "source" as NSString)
        native.setObject(environment, forKeyedSubscript: "environment" as NSString)
        native.setObject(library, forKeyedSubscript: "library" as NSString)
        native.setObject(transpile, forKeyedSubscript: "transpile" as NSString)
        native.setObject(schedule, forKeyedSubscript: "schedule" as NSString)

        let prelude = context.evaluateScript(Self.prelude, withSourceURL: URL(string: "pappuclip:prelude"))
        runner = prelude?.call(withArguments: [context.globalObject as Any, native])
        if let thrown {
            runner = nil
            return thrown
        }
        guard let runner, runner.isObject else { return "The prelude did not start." }
        // From here on, what a script throws reaches it through the prelude's own catch, and the
        // handler only sees what escapes that — which is nothing the prelude lets go.
        context.exceptionHandler = { _, _ in }
        self.context = context
        return nil
    }

    /// Answers everything still owed, `dropped`. Called when the world is replaced or unloaded; the
    /// context goes with the last reference to this object, and its timers with it.
    func abandon() {
        let owed = pending
        pending = [:]
        for reply in owed.values { reply(.dropped) }
        runner = nil
        context = nil
    }

    // MARK: Timers (JS-2)

    /// The host's half of `setTimeout` and `setInterval`: after the delay, on the world's own queue, ask
    /// the prelude to run timer `id`. The prelude keeps the callbacks and knows which were cleared.
    private func schedule(timer id: Double, after milliseconds: Double) {
        let delay = milliseconds.isFinite ? min(max(milliseconds, 0), Self.longestDelay) : 0
        queue.asyncAfter(deadline: .now() + .microseconds(Int(delay * 1_000))) { [weak self] in
            self?.fire(timer: id)
        }
    }

    private func fire(timer id: Double) {
        guard let runner else { return }
        runner.invokeMethod("fire", withArguments: [id])
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
        runner.invokeMethod("run", withArguments: [
            source, url, base, state, JSValue(object: settle, in: context) as Any, invocation.typeScript,
        ])
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

    /// The part of the world written in JavaScript (§8.8): `print`, the timers and `sleep`, the
    /// environment's globals, the module system over the package and the libraries, `define`, and the
    /// wrapper an action's script runs in (JS-1, JS-2, JS-9 to JS-12, JS-14).
    ///
    /// It captures what it relies on — `eval`, `Object.freeze`, `Object.defineProperty`, `Map`,
    /// `Promise` — before any extension code runs, so an extension that replaces them changes its own
    /// globals and not the prelude's behaviour. It cannot protect an extension from itself (a script
    /// that replaces `Promise.prototype.then` can stop its own action from ever answering) and does not
    /// try: that action is then cancelled like any other that hangs.
    ///
    /// **`require`** (JS-10). `./` and `../` are relative to the requiring file; anything else is tried
    /// at the package root, then among the bundled libraries. A path that is absolute or leaves the
    /// package throws "Cannot find module". Anything else not found is `undefined`, as PopClip
    /// documents, and a line in the Debug Console says so. `.ts` files, `.mjs` files and `.js` files
    /// with `import` or `export` statements are transpiled to CommonJS first (JS-14), whether they are
    /// required or are an action's own file. A library's own `require` reaches other libraries and
    /// never the package.
    ///
    /// **Every file and every action's script** sees `require`, `module`, `exports`, `define` and
    /// `defineExtension` as its own, as CommonJS files do in Node, from a scope just outside its own:
    /// one that declares any of those names itself shadows them, as it could shadow PopClip's globals.
    /// `define` and `defineExtension` are the same function, PopClip's partial AMD: the last call in a
    /// file sets its export.
    ///
    /// **Timers** are kept here and timed by the host, on the world's queue. A callback that throws is
    /// written to the Debug Console and nothing else happens. A repeating timer waits at least 4 ms, and
    /// no more than 10,000 may wait at once.
    static let prelude = #"""
    (function (global, native) {
      'use strict';
      const indirectEval = global.eval;
      const freeze = Object.freeze;
      const defineProperty = Object.defineProperty;
      const hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
      const slice = Function.prototype.call.bind(Array.prototype.slice);
      const isArray = Array.isArray;
      const Timers = Map;
      const PromiseConstructor = Promise;
      const packageModules = Object.create(null);
      const libraryModules = Object.create(null);

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

      function install(name, value) {
        defineProperty(global, name, { value: value, writable: true, configurable: true });
      }

      // Text → a function of the named parameters that returns the text as a function of none. The
      // parameters are a scope outside the text's own, so a file or script that declares `module` or
      // `define` itself shadows them, as it would shadow PopClip's globals, instead of being a syntax
      // error. The first line is not moved, so line numbers are the author's. The source URL names the
      // file for the Web Inspector (DEV-1).
      function compile(text, url, parameters, prefix) {
        return indirectEval('(function (' + parameters + ') { return ' + (prefix || '') + 'function () {' + text + '\n}; })\n//# sourceURL=' + url);
      }

      // print and console (JS-1, DIA-1)

      const print = function () {
        native.log(Array.prototype.map.call(arguments, format).join(' '));
      };
      install('print', print);
      install('console', freeze({ log: print, info: print, warn: print, error: print, debug: print }));

      // Timers and sleep (JS-2). The host keeps time; the world keeps the callbacks. An id the host fires
      // after it was cleared finds nothing.

      const timers = new Timers();
      let lastTimer = 0;
      const timerLimit = 10000;

      function schedule(callback, delay, repeats) {
        if (typeof callback !== 'function') throw new TypeError('The callback must be a function.');
        if (timers.size >= timerLimit) throw new RangeError('Too many timers are waiting.');
        let milliseconds = Number(delay);
        if (!(milliseconds > 0)) milliseconds = 0;
        // A browser's clamp for a repeating timer, so an interval of 0 cannot occupy the world's queue.
        if (repeats && milliseconds < 4) milliseconds = 4;
        lastTimer += 1;
        timers.set(lastTimer, { callback: callback, milliseconds: milliseconds, repeats: repeats });
        native.schedule(lastTimer, milliseconds);
        return lastTimer;
      }

      function fire(id) {
        const timer = timers.get(id);
        if (timer === undefined) return;
        if (!timer.repeats) timers.delete(id);
        try {
          timer.callback.call(undefined);
        } catch (error) {
          print('Uncaught ' + describe(error));
        }
        if (timer.repeats && timers.get(id) === timer) native.schedule(id, timer.milliseconds);
      }

      function clear(id) {
        timers.delete(Number(id));
      }

      install('setTimeout', function setTimeout(callback, delay) { return schedule(callback, delay, false); });
      install('setInterval', function setInterval(callback, delay) { return schedule(callback, delay, true); });
      install('clearTimeout', function clearTimeout(id) { clear(id); });
      install('clearInterval', function clearInterval(id) { clear(id); });
      install('sleep', function sleep(milliseconds) {
        return new PromiseConstructor(function (resolve) { schedule(resolve, milliseconds, false); });
      });
      // For libraries that look for a browser (JS-2). There is no DOM behind it.
      install('window', global);

      // The environment: URL, Buffer and the rest (JS-2). What it exports is `require("buffer")`.

      const environment = (function () {
        const text = native.environment();
        if (typeof text !== 'string') throw new Error('The JavaScript environment is missing from the helper.');
        const module = { exports: {} };
        compile(text, 'pappuclip:environment', 'exports, require, module')(module.exports, function (name) {
          throw new Error("The environment cannot require '" + name + "'.");
        }, module).call(module.exports);
        return module.exports;
      })();

      // Modules (JS-10)

      function notFound(request) {
        const error = new Error("Cannot find module '" + request + "'");
        error.code = 'MODULE_NOT_FOUND';
        return error;
      }

      // TypeScript and ES module syntax become CommonJS through the host's transpiler (JS-14). Its error
      // is a syntax error in the file that was being loaded.
      function transpile(text, kind, url) {
        const result = native.transpile(text, kind);
        if (typeof result === 'string') return result;
        throw new SyntaxError(url + ': ' + (result !== null && typeof result === 'object' ? result.error : 'could not be transpiled'));
      }

      // An `import` or `export` statement at the start of a line. Not `imports.x`, `exports.x` or `import(`.
      const moduleSyntax = /^[ \t]*(?:import(?:[ \t]+[\w${*'"]|[ \t]*[{*'"])|export(?:[ \t]+[\w$]|[ \t]*[{*]))/m;

      function commonJS(path, text) {
        if (/\.ts$/i.test(path)) return transpile(text, 'typescript', path);
        if (/\.mjs$/i.test(path) || (/\.js$/i.test(path) && moduleSyntax.test(text))) return transpile(text, 'module', path);
        return text;
      }

      // define() and defineExtension(), which are the same function (JS-12): PopClip's partial AMD. The
      // last call in a file wins. A factory is called with its dependencies, or with require, exports and
      // module when it names none, and what it returns, if anything, is the file's export.
      function definer(module, require) {
        const define = function define() {
          let args = slice(arguments);
          if (typeof args[0] === 'string') args = args.slice(1);
          const dependencies = isArray(args[0]) ? args.shift() : null;
          const factory = args[0];
          if (typeof factory !== 'function') {
            module.exports = factory;
            return;
          }
          const values = dependencies === null
            ? [require, module.exports, module]
            : dependencies.map(function (name) {
              if (name === 'require') return require;
              if (name === 'exports') return module.exports;
              if (name === 'module') return module;
              return require(name);
            });
          const result = factory.apply(undefined, values);
          if (result) module.exports = result;
        };
        define.amd = freeze({});
        return define;
      }

      const scriptParameters = 'require, module, exports, define, defineExtension';

      function loadPackageFile(path) {
        if (hasOwn(packageModules, path)) return packageModules[path].exports;
        const module = { id: path, exports: {}, loaded: false };
        packageModules[path] = module;
        try {
          const text = native.source(path);
          if (/\.json$/i.test(path)) {
            module.exports = JSON.parse(text);
          } else {
            const require = requireFrom(path);
            const define = definer(module, require);
            compile(commonJS(path, text), path, scriptParameters)(require, module, module.exports, define, define)
              .call(module.exports);
          }
        } catch (error) {
          delete packageModules[path];
          throw error;
        }
        module.loaded = true;
        return module.exports;
      }

      // A bundled library (JS-9). Its own `require` reaches other libraries and nothing in the package.
      function loadLibrary(name) {
        if (name === 'buffer') return environment.buffer;
        if (hasOwn(libraryModules, name)) return libraryModules[name].exports;
        const text = native.library(name);
        if (typeof text !== 'string') return undefined;
        const module = { id: name, exports: {}, loaded: false };
        libraryModules[name] = module;
        try {
          compile(text, 'pappuclip:library/' + name, 'exports, require, module')(module.exports, requireLibrary, module)
            .call(module.exports);
        } catch (error) {
          delete libraryModules[name];
          throw error;
        }
        module.loaded = true;
        return module.exports;
      }

      function requireLibrary(request) {
        const name = String(request);
        const library = loadLibrary(name);
        if (library === undefined) throw notFound(name);
        return library;
      }

      // `./` and `../` are relative to the requiring file; anything else is tried at the package root and
      // then among the libraries. A path that is absolute or leaves the package is an error. Anything else
      // that is not found is undefined, as in PopClip, and says so in the Debug Console.
      function requireFrom(base) {
        return function require(request) {
          const name = String(request);
          const found = native.resolve(base, name);
          if (typeof found === 'string') return loadPackageFile(found);
          if (found === false) throw notFound(name);
          if (!/^\.{0,2}\//.test(name)) {
            const library = loadLibrary(name);
            if (library !== undefined) return library;
          }
          print("require('" + name + "') found nothing, so it is undefined.");
          return undefined;
        };
      }

      return freeze({
        fire: fire,

        run: function (source, url, base, state, settle, typeScript) {
          let script;
          try {
            // An action's own file follows the rule `require` does: TypeScript, `.mjs`, and `.js` with
            // `import` or `export` statements are transpiled.
            const text = typeScript ? transpile(source, 'typescript', url) : base === '' ? source : commonJS(base, source);
            script = compile(text, url, scriptParameters, 'async ');
          } catch (error) {
            settle('threw', describe(error));
            return;
          }
          const popclip = freeze({ input: freeze(state.input), options: freeze(state.options) });
          defineProperty(global, 'popclip', { value: popclip, writable: false, configurable: true });
          defineProperty(global, 'pappuclip', { value: popclip, writable: false, configurable: true });
          const module = { id: url, exports: {}, loaded: false };
          const require = requireFrom(base);
          const define = definer(module, require);
          let promise;
          try {
            promise = script(require, module, module.exports, define, define).call(undefined);
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
