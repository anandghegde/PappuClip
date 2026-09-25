import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import PappuJSBridge
import Security
import Synchronization

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
/// bundled libraries (JS-9, JS-10), a frozen `popclip` describing the invocation (JS-3), and the host
/// API (JS-4, JS-6, JS-7). There is no `fetch`, no DOM, no `process`, no file system: JavaScriptCore
/// has none of them, and the helper's sandbox would refuse them if it did (SEC-1a).
///
/// **The host API is the app's.** Every `popclip` method, `pasteboard`, `RichString` and the dictionary
/// and spelling lookups become a `JSHostCall` to the app, which decides (architecture §10.4); this side
/// only says whose it is. What is pure — Base64, hashing, random values, query strings, the locale —
/// is worked out here and never crosses (§10.2).
///
/// Everything but `init`, `interrupt` and `interruptAll` runs on `queue`. The host puts it there, and
/// timers and host answers arrive there.
final class ExtensionVM: @unchecked Sendable {
    typealias Reply = @Sendable (JSHostReply) -> Void
    /// Sends a host call to the app, and gives its answer back once — on any queue.
    typealias HostCaller = @Sendable (JSHostCall, @escaping @Sendable (JSHostAnswer) -> Void) -> Void

    let name: String
    let generation: String
    let queue: DispatchQueue

    private let files: [String: String]
    private let log: @Sendable (String) -> Void
    private let host: HostCaller
    private let transpiler: Transpiler
    /// Synchronous host calls in flight, which a `drop` may have to end from outside `queue`.
    private let waiting = BlockingCalls()
    /// Invocations a `drop` has reached from outside `queue`: whatever they settle to is `dropped`.
    private let dropping = Mutex<Set<UInt64>>([])
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

    /// The longest a synchronous host call — `pasteboard.text`, a dictionary lookup — waits for the app.
    /// The world's queue is held while it waits, so it is bounded; an answer that has not come by then is
    /// not coming, and the script hears so.
    static let blockingLimit: Duration = .seconds(10)

    /// The most random bytes one call asks for: Web Crypto's limit, which `getRandomValues` keeps.
    static let randomLimit = 65_536

    init(
        load: JSLoad,
        transpiler: Transpiler = .shared,
        qos: DispatchQoS = .userInitiated,
        host: @escaping HostCaller = { _, answer in answer(.refused("There is no app to ask.")) },
        log: @escaping @Sendable (String) -> Void
    ) {
        name = load.extensionName
        generation = load.generation
        var files: [String: String] = [:]
        for (path, text) in load.files {
            if let path = ModulePath.normalize(path) { files[path] = text }
        }
        self.files = files
        self.transpiler = transpiler
        self.host = host
        self.log = log
        queue = DispatchQueue(label: "app.pappuclip.jshost.vm", qos: qos)
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
        // Host calls: answered later through the prelude's `answer`, or waited for here.
        let call: @convention(block) (Double, Double, String, String) -> Void = { [weak self] invocation, id, method, arguments in
            self?.ask(invocation, call: id, method: method, arguments: arguments)
        }
        let callSync: @convention(block) (Double, String, String) -> [String: String] = { [weak self] invocation, method, arguments in
            guard let self else { return Self.parts(of: .refused("The extension was unloaded.")) }
            return Self.parts(of: self.askAndWait(invocation, method: method, arguments: arguments))
        }
        // Pure utilities (JS-6), here so they never cross.
        let random: @convention(block) (Int) -> String = { count in
            Self.randomBytes(min(max(count, 0), Self.randomLimit)).base64EncodedString()
        }
        let digest: @convention(block) (String, String, JSValue) -> Any = { algorithm, data, key in
            let secret = key.isString ? Data(base64Encoded: key.toString()) : nil
            guard let bytes = Data(base64Encoded: data),
                  let result = Self.digest(algorithm, bytes, key: key.isString ? secret ?? Data() : nil)
            else { return NSNull() }
            return result.base64EncodedString()
        }
        let locale: @convention(block) () -> [String: String] = { Self.localeInfo() }
        let timeZone: @convention(block) () -> [String: Any] = { Self.timeZoneInfo() }
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(resolve, forKeyedSubscript: "resolve" as NSString)
        native.setObject(source, forKeyedSubscript: "source" as NSString)
        native.setObject(environment, forKeyedSubscript: "environment" as NSString)
        native.setObject(library, forKeyedSubscript: "library" as NSString)
        native.setObject(transpile, forKeyedSubscript: "transpile" as NSString)
        native.setObject(schedule, forKeyedSubscript: "schedule" as NSString)
        native.setObject(call, forKeyedSubscript: "call" as NSString)
        native.setObject(callSync, forKeyedSubscript: "callSync" as NSString)
        native.setObject(random, forKeyedSubscript: "random" as NSString)
        native.setObject(digest, forKeyedSubscript: "digest" as NSString)
        native.setObject(locale, forKeyedSubscript: "locale" as NSString)
        native.setObject(timeZone, forKeyedSubscript: "timeZone" as NSString)

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

    /// Ends the synchronous host calls `invocation` is waiting in, so that a `drop` queued behind one is
    /// not held for `blockingLimit`. Safe from any queue.
    func interrupt(_ invocation: UInt64) {
        dropping.withLock { _ = $0.insert(invocation) }
        waiting.interrupt { $0 == invocation }
    }

    /// Ends every synchronous host call, before the world is replaced or unloaded. Safe from any queue.
    func interruptAll() {
        waiting.interrupt { _ in true }
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
    ///
    /// A script's action runs its script. A module's action (JS-12) runs the function at its `export`
    /// in what the module exported, loading the module first if this world has not yet.
    func invoke(_ invocation: JSInvoke, reply: @escaping Reply) {
        guard let context, let runner else { return reply(.notLoaded) }
        guard let state = Self.state(of: invocation) else { return reply(.threw("The action's input could not be read.")) }
        if let export = invocation.export {
            guard let module = moduleEntry(invocation.entry) else {
                return reply(.threw("Cannot find the module \(invocation.entry.path ?? "")."))
            }
            let settle = settler(for: invocation.invocation, reply: reply)
            runner.invokeMethod("runExport", withArguments: [
                module.source, module.isFile, invocation.typeScript, export, state, JSValue(object: settle, in: context) as Any,
            ])
            return
        }
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
        let settle = settler(for: invocation.invocation, reply: reply)
        runner.invokeMethod("run", withArguments: [
            source, url, base, state, JSValue(object: settle, in: context) as Any, invocation.typeScript,
        ])
    }

    /// What `popclip` is made from for one invocation (JS-3), as JSON for the prelude to parse: the one
    /// shape both sides agree on, and no bridging of optionals and booleans by the runtime to get wrong.
    private struct InvocationState: Encodable {
        var invocation: UInt64
        var input: JSInput
        var context: JSSelectionContext
        var modifiers: JSModifiers
        var options: [String: String]
        var booleanOptions: [String]
    }

    static func state(of invocation: JSInvoke) -> String? {
        let state = InvocationState(
            invocation: invocation.invocation,
            input: invocation.input,
            context: invocation.context,
            modifiers: invocation.modifiers,
            options: invocation.options,
            booleanOptions: invocation.booleanOptions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The block the prelude settles an invocation through, with its reply owed until then.
    private func settler(for id: UInt64, reply: @escaping Reply) -> @convention(block) (String, JSValue) -> Void {
        pending[id] = reply
        return { [weak self] kind, value in
            guard let self, let reply = self.pending.removeValue(forKey: id) else { return }
            if self.dropping.withLock({ $0.remove(id) != nil }) { return reply(.dropped) }
            switch kind {
            case "returned": reply(.returned(value.isString ? value.toString() : nil))
            default: reply(.threw(value.isString ? value.toString() : "An error was thrown."))
            }
        }
    }

    /// JS-12: runs a module extension's module, if this world has not, and answers what it exported.
    /// The module's code runs here, as it would for an action; what comes back is data.
    func describeModule(_ request: JSDescribe) -> JSHostReply {
        guard let runner else { return .notLoaded }
        guard let module = moduleEntry(request.entry) else {
            return .threw("Cannot find the module \(request.entry.path ?? "").")
        }
        guard let result = runner.invokeMethod("describe", withArguments: [module.source, module.isFile, request.typeScript]),
              result.isObject
        else { return .threw("The module could not be described.") }
        if let error = result.objectForKeyedSubscript("error"), error.isString {
            return .threw(error.toString())
        }
        guard let exports = result.objectForKeyedSubscript("exports"), exports.isString, let json = exports.toString() else {
            return .threw("The module could not be described.")
        }
        let functions = result.objectForKeyedSubscript("functions")?.toArray() as? [String] ?? []
        return .described(JSModuleDescription(exports: json, functions: functions))
    }

    /// A module as the prelude takes it: a package path it loads as `require` would, or a snippet's
    /// text. Nil for a path that is absolute or leaves the package.
    private func moduleEntry(_ entry: JSInvoke.Entry) -> (source: String, isFile: Bool)? {
        switch entry {
        case .inline(let text): return (text, false)
        case .file(let path):
            guard let path = ModulePath.normalize(path) else { return nil }
            return (path, true)
        }
    }

    // MARK: Host calls (JS-4, JS-6, JS-7, architecture §10.4)

    /// An asynchronous call: sent now, answered on `queue` through the prelude's `answer`, whenever the
    /// app answers. The extension's name is this world's, whatever the script did.
    private func ask(_ invocation: Double, call id: Double, method: String, arguments: String) {
        guard let invocation = UInt64(exactly: invocation) else { return deliver(id, .refused("No such action.")) }
        host(JSHostCall(invocation: invocation, extensionName: name, method: method, arguments: arguments)) { [weak self] answer in
            guard let self else { return }
            self.queue.async { self.deliver(id, answer) }
        }
    }

    private func deliver(_ id: Double, _ answer: JSHostAnswer) {
        guard let runner else { return }
        let parts = Self.parts(of: answer)
        runner.invokeMethod("answer", withArguments: [id, parts["kind"] ?? "", parts["value"] ?? ""])
    }

    /// A synchronous call, for an API a script reads as a value (`pasteboard.text`). The world's queue
    /// waits here, for at most `blockingLimit`, or until a `drop` interrupts it.
    private func askAndWait(_ invocation: Double, method: String, arguments: String) -> JSHostAnswer {
        guard let invocation = UInt64(exactly: invocation) else { return .refused("No such action.") }
        let wait = waiting.open(for: invocation)
        defer { waiting.close(wait) }
        host(JSHostCall(invocation: invocation, extensionName: name, method: method, arguments: arguments)) { answer in
            wait.fulfil(answer)
        }
        return wait.answer(within: Self.blockingLimit) ?? .failed("PappuClip did not answer \(method) in time.")
    }

    /// An answer as the prelude takes it: `kind` is `done`, `value`, or anything else for an error.
    static func parts(of answer: JSHostAnswer) -> [String: String] {
        switch answer {
        case .done: ["kind": "done", "value": ""]
        case .value(let json): ["kind": "value", "value": json]
        case .refused(let message): ["kind": "refused", "value": message]
        case .failed(let message): ["kind": "failed", "value": message]
        }
    }

    // MARK: Pure utilities (JS-6)

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard count > 0, SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return Data(count: count) }
        return Data(bytes)
    }

    /// `util.hash` and, with a key, `util.hmac`. CryptoKit has no SHA-224, so that one and every HMAC are
    /// CommonCrypto's. Nil for an algorithm that is not one of the six.
    static func digest(_ algorithm: String, _ data: Data, key: Data?) -> Data? {
        if let key {
            let (hmac, length): (Int, Int32) = switch algorithm {
            case "md5": (kCCHmacAlgMD5, CC_MD5_DIGEST_LENGTH)
            case "sha1": (kCCHmacAlgSHA1, CC_SHA1_DIGEST_LENGTH)
            case "sha224": (kCCHmacAlgSHA224, CC_SHA224_DIGEST_LENGTH)
            case "sha256": (kCCHmacAlgSHA256, CC_SHA256_DIGEST_LENGTH)
            case "sha384": (kCCHmacAlgSHA384, CC_SHA384_DIGEST_LENGTH)
            case "sha512": (kCCHmacAlgSHA512, CC_SHA512_DIGEST_LENGTH)
            default: (-1, 0)
            }
            guard hmac >= 0 else { return nil }
            var output = [UInt8](repeating: 0, count: Int(length))
            key.withUnsafeBytes { key in
                data.withUnsafeBytes { data in
                    CCHmac(CCHmacAlgorithm(hmac), key.baseAddress, key.count, data.baseAddress, data.count, &output)
                }
            }
            return Data(output)
        }
        switch algorithm {
        case "md5": return Data(Insecure.MD5.hash(data: data))
        case "sha1": return Data(Insecure.SHA1.hash(data: data))
        case "sha224":
            var output = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { data in _ = CC_SHA224(data.baseAddress, CC_LONG(data.count), &output) }
            return Data(output)
        case "sha256": return Data(SHA256.hash(data: data))
        case "sha384": return Data(SHA384.hash(data: data))
        case "sha512": return Data(SHA512.hash(data: data))
        default: return nil
        }
    }

    /// `util.localeInfo`, as the user set it, read each time. A value the locale does not define is "".
    static func localeInfo() -> [String: String] {
        let locale = Locale.autoupdatingCurrent
        return [
            "localeIdentifier": locale.identifier,
            "regionCode": locale.region?.identifier ?? "",
            "languageCode": locale.language.languageCode?.identifier ?? "",
            "decimalSeparator": locale.decimalSeparator ?? "",
            "groupingSeparator": locale.groupingSeparator ?? "",
            "currencyCode": locale.currency?.identifier ?? "",
            "currencySymbol": locale.currencySymbol ?? "",
        ]
    }

    /// `util.timeZoneInfo`, read each time: the zone can change under a running app.
    static func timeZoneInfo() -> [String: Any] {
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current
        return [
            "identifier": zone.identifier,
            "abbreviation": zone.abbreviation() ?? "",
            "secondsOffset": zone.secondsFromGMT(),
            "daylightSaving": zone.isDaylightSavingTime(),
        ]
    }

    /// Stops waiting for an invocation, and answers it `dropped`. Whatever its script does afterwards
    /// settles into nothing.
    func drop(_ invocation: UInt64) {
        dropping.withLock { _ = $0.remove(invocation) }
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
    /// environment's globals, the module system over the package and the libraries, `define`, the
    /// wrapper an action's script runs in, and module extensions (JS-1, JS-2, JS-9 to JS-12, JS-14).
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
    /// **Modules** (JS-12). `describe` loads a module extension's module — a package file, loaded as
    /// `require` loads it, or a snippet's own text — and answers what it exported as JSON: the extension
    /// object `defineExtension`, `module.exports` or `export default` gave, or its named exports, with
    /// every function taken out and an action that has code marked `code: true`. Regular expressions
    /// become ICU patterns, with their `i`, `m` and `s` flags inline. `runExport` calls the action at an
    /// export path as PopClip does, `code(input, options, context)` with the action as `this`. Either
    /// loads the module once per world.
    ///
    /// **Timers** are kept here and timed by the host, on the world's queue. A callback that throws is
    /// written to the Debug Console and nothing else happens. A repeating timer waits at least 4 ms, and
    /// no more than 10,000 may wait at once.
    ///
    /// **The host API** (JS-3, JS-4, JS-6, JS-7). Each invocation gets its own frozen `popclip`, built
    /// from the app's JSON: `input` with its detections and their ranges, `context` and `modifiers` under
    /// PopClip's names, `options` with booleans as booleans, and methods that are host calls carrying that
    /// invocation's number. Arguments are checked for shape here, so a mistake throws where it was made.
    /// `pasteboard`, `RichString` and the dictionary and spelling lookups in `util` are synchronous host
    /// calls for the invocation whose code is running, and throw outside one — while a module loads, or
    /// in a timer after its action ended. The rest of `util` is worked out here. External scripts (JS-5)
    /// reject until week 4. An invocation settles only once every call it made has been answered, so a
    /// script that ends with an un-awaited `copyText` has its copy made before its run is over.
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
      const stringify = JSON.stringify;
      const parse = JSON.parse;
      const keys = Object.keys;
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

      // Module extensions (JS-12)

      // A module is a file in the package, loaded as `require` loads it, or a snippet's own text, which
      // is evaluated once per world. Either way it runs once, and its actions are what it exported.
      let snippetModule = null;

      function loadModule(source, isFile, typeScript) {
        if (isFile) {
          const path = native.resolve('', './' + source);
          if (typeof path !== 'string') throw notFound(source);
          return loadPackageFile(path);
        }
        if (snippetModule === null) {
          const module = { id: 'pappuclip:module', exports: {}, loaded: false };
          const require = requireFrom('');
          const define = definer(module, require);
          const text = typeScript ? transpile(source, 'typescript', 'pappuclip:module')
            : moduleSyntax.test(source) ? transpile(source, 'module', 'pappuclip:module') : source;
          compile(text, 'pappuclip:module', scriptParameters)(require, module, module.exports, define, define)
            .call(module.exports);
          module.loaded = true;
          snippetModule = module;
        }
        return snippetModule.exports;
      }

      // What the module exported: `defineExtension(obj)` and `module.exports = obj` are the object itself;
      // `export default obj` is its `default`, unless the module also has named exports that say what it is.
      function extensionOf(exports) {
        if (exports !== null && typeof exports === 'object') {
          const fallback = exports.default;
          const named = hasOwn(exports, 'actions') || hasOwn(exports, 'action') || hasOwn(exports, 'options') || hasOwn(exports, 'submenu');
          if (!named && fallback !== null && typeof fallback === 'object') return fallback;
        }
        return exports;
      }

      // A JavaScript regular expression as the ICU pattern the app matches with. Its flags that change what
      // matches become inline flags; `g`, `y` and `u` change nothing a single match needs.
      function icuPattern(pattern) {
        const flags = (pattern.ignoreCase ? 'i' : '') + (pattern.multiline ? 'm' : '') + (pattern.dotAll ? 's' : '');
        return (flags ? '(?' + flags + ')' : '') + pattern.source;
      }

      const describedLimit = 1048576;

      // The data in a value, as JSON would keep it: no functions, no symbols, no cycles, a bounded amount.
      function plain(value, depth, budget) {
        if (value === null) return null;
        switch (typeof value) {
          case 'string':
          case 'boolean':
            return value;
          case 'number':
            return isFinite(value) ? value : undefined;
          case 'object':
            break;
          default:
            return undefined;
        }
        budget.left -= 1;
        if (depth > 32 || budget.left < 0) throw new RangeError('The extension object is too large or too deep to describe.');
        if (value instanceof RegExp) return icuPattern(value);
        if (isArray(value)) {
          return Array.prototype.map.call(value, function (item) {
            const kept = plain(item, depth + 1, budget);
            return kept === undefined ? null : kept;
          });
        }
        const kept = {};
        for (const key of Object.keys(value)) {
          const item = plain(value[key], depth + 1, budget);
          if (item !== undefined) kept[key] = item;
        }
        return kept;
      }

      // An action as data. A function, or an object whose `code` is one, becomes `code: true`, which is the
      // one thing the app is told about code: that there is some, at this path.
      function describeAction(entry, depth, budget) {
        if (typeof entry === 'function') return { code: true };
        if (entry === null || typeof entry !== 'object' || isArray(entry)) return plain(entry, depth, budget);
        const kept = {};
        for (const key of Object.keys(entry)) {
          const value = entry[key];
          if (key === 'code') {
            if (typeof value === 'function') kept.code = true;
          } else if (key === 'submenu') {
            kept.submenu = typeof value === 'function' ? 'population'
              : isArray(value) ? Array.prototype.map.call(value, function (item) { return describeAction(item, depth + 1, budget); })
              : plain(value, depth + 1, budget);
          } else {
            const item = plain(value, depth + 1, budget);
            if (item !== undefined) kept[key] = item;
          }
        }
        return kept;
      }

      // The extension object as JSON text, and the names of its top-level keys that are functions: a
      // population function for `actions` or `submenu`, `auth`, `test`.
      function describeExtension(extension) {
        if (extension === null || typeof extension !== 'object') {
          throw new TypeError('The module exports ' + (extension === null ? 'null' : typeof extension) + ', not an extension object.');
        }
        const budget = { left: 100000 };
        const kept = {};
        const functions = [];
        for (const key of Object.keys(extension)) {
          const value = extension[key];
          if (typeof value === 'function' && key !== 'action') {
            functions.push(key);
          } else if ((key === 'actions' || key === 'submenu') && isArray(value)) {
            kept[key] = Array.prototype.map.call(value, function (entry) { return describeAction(entry, 1, budget); });
          } else if (key === 'action') {
            kept.action = describeAction(value, 1, budget);
          } else {
            const item = plain(value, 1, budget);
            if (item !== undefined) kept[key] = item;
          }
        }
        const json = JSON.stringify(kept);
        if (json.length > describedLimit) throw new RangeError('The extension object is too large to describe.');
        return { exports: json, functions: functions };
      }

      // The action at `path` (`action`, `actions.3`), as `describeExtension` numbered it.
      function exportedAction(extension, path) {
        let target = extension;
        for (const step of String(path).split('.')) {
          if (target === null || typeof target !== 'object') {
            target = undefined;
            break;
          }
          target = /^[0-9]+$/.test(step) ? (isArray(target) ? target[Number(step)] : undefined) : hasOwn(target, step) ? target[step] : undefined;
        }
        if (typeof target === 'function') return target;
        if (target !== null && typeof target === 'object' && typeof target.code === 'function') return target;
        throw new Error('The module has no action at ' + path + '.');
      }

      // Host calls (architecture §10.2, §10.4). Everything a script asks of the app goes through these two:
      // an asynchronous call is answered later, on the world's queue, through `answer`; a synchronous one
      // (`pasteboard.text`, a dictionary lookup) waits in the host for its answer. Either way it carries the
      // invocation it was made for, which the app checks is still running before anything else, and the app
      // decides. `current` is the invocation whose code is running, for the globals that are not one
      // invocation's own (`pasteboard`, `util`, `RichString`): set as it starts and cleared as it settles, so
      // a timer that fires after its action ended reaches nothing.
      //
      // An invocation does not settle while a call it made is unanswered. A script may end with
      // `popclip.copyText(result)` and not await it, as PopClip allows; its run must not be over, and the
      // call refused, before the app has done it.

      const calls = new Timers();
      const unanswered = new Timers();
      let lastCall = 0;
      let current = null;

      function counted(invocation, change) {
        const entry = unanswered.get(invocation) || { count: 0, then: [] };
        entry.count += change;
        if (entry.count > 0) {
          unanswered.set(invocation, entry);
          return;
        }
        unanswered.delete(invocation);
        for (const then of entry.then) then();
      }

      function whenAnswered(invocation, then) {
        const entry = unanswered.get(invocation);
        if (entry === undefined) then();
        else entry.then.push(then);
      }

      function outOfAction(what) {
        return new Error(what + ' is available only while an action runs.');
      }

      function settled(kind, value) {
        if (kind === 'done') return undefined;
        if (kind === 'value') return parse(value);
        throw new Error(value);
      }

      function callHost(invocation, method, args) {
        return new PromiseConstructor(function (resolve, reject) {
          if (invocation === null) {
            reject(outOfAction(method));
            return;
          }
          lastCall += 1;
          calls.set(lastCall, { resolve: resolve, reject: reject, invocation: invocation });
          counted(invocation, 1);
          native.call(invocation, lastCall, method, stringify(args));
        });
      }

      function callHostNow(invocation, method, args) {
        if (invocation === null) throw outOfAction(method);
        const answer = native.callSync(invocation, method, stringify(args));
        return settled(answer.kind, answer.value);
      }

      function answer(id, kind, value) {
        const call = calls.get(id);
        if (call === undefined) return;
        calls.delete(id);
        let result;
        let failure = null;
        try {
          result = settled(kind, value);
        } catch (error) {
          failure = error;
        }
        if (failure === null) call.resolve(result);
        else call.reject(failure);
        counted(call.invocation, -1);
      }

      // Arguments, checked here for shape so that a mistake throws where it was made; the app checks them
      // again, for meaning, and for whether they are allowed.

      const plainType = 'public.utf8-plain-text';
      const Buffer = environment.buffer.Buffer;
      const URLClass = global.URL;

      function flag(options, name, fallback) {
        if (options === undefined || options === null || options[name] === undefined) return fallback;
        return Boolean(options[name]);
      }

      function choice(options, name, allowed, fallback) {
        if (options === undefined || options === null || options[name] === undefined) return fallback;
        const value = String(options[name]);
        if (allowed.indexOf(value) < 0) throw new TypeError(name + ' must be ' + allowed.join(' or ') + '.');
        return value;
      }

      function optionalText(options, name) {
        if (options === undefined || options === null || options[name] === undefined || options[name] === null) return null;
        return String(options[name]);
      }

      // A content object (PasteboardContent): pasteboard types to strings. Other values are left out.
      function contentOf(content) {
        if (content === null || typeof content !== 'object') throw new TypeError('The content must be an object of pasteboard types.');
        const kept = {};
        for (const type of keys(content)) {
          if (typeof content[type] === 'string') kept[type] = content[type];
        }
        if (keys(kept).length === 0) throw new TypeError('The content has no text in it.');
        return kept;
      }

      // A URL as `openUrl` takes it: a string as it is, or a URL whose `+` become `%20` (PopClip's rule).
      function urlOf(url) {
        if (typeof url === 'string') return url;
        if (url instanceof URLClass) return url.href.replace(/\+/g, '%20');
        throw new TypeError('The URL must be a string or a URL.');
      }

      function keyStep(key, modifiers) {
        const mask = modifiers === undefined || modifiers === null ? 0 : Number(modifiers) >>> 0;
        if (typeof key === 'number') {
          if (!(key >= 0 && key <= 0x7f && key === Math.floor(key))) throw new RangeError('A key code is from 0 to 0x7F.');
          return { keyCode: key, modifiers: mask };
        }
        if (typeof key === 'string' && key.trim() !== '') return { combo: key, modifiers: mask };
        throw new TypeError('A key is a string, such as "command b", or a key code.');
      }

      function keySteps(sequence) {
        if (!isArray(sequence)) throw new TypeError('The sequence must be an array.');
        return sequence.map(function (entry) {
          const wait = typeof entry === 'string' ? /^\s*wait\s+([0-9]+)\s*$/i.exec(entry) : null;
          if (wait === null) return keyStep(entry, 0);
          const milliseconds = Number(wait[1]);
          if (milliseconds > 5000) throw new RangeError('A wait is at most 5000 ms.');
          return { wait: milliseconds };
        });
      }

      function keyTarget(options) {
        return choice(options, 'target', ['session', 'app', 'hid'], null);
      }

      // RichString (JS-7): formatted text, made from RTF, HTML or Markdown. The app converts it, because
      // what does that is AppKit's, which the helper does not have; it is asked once per string.

      const richSources = new WeakMap();

      function RichString(source, options) {
        if (!(this instanceof RichString)) throw new TypeError("RichString must be called with 'new'.");
        const format = choice(options, 'format', ['rtf', 'html', 'markdown'], 'rtf');
        richSources.set(this, { source: String(source), format: format, converted: null });
      }

      function rich(value) {
        const state = richSources.get(value);
        if (state === undefined) throw new TypeError('Not a RichString.');
        return state;
      }

      function converted(value) {
        const state = rich(value);
        if (state.converted === null) {
          state.converted = callHostNow(current, 'richText.convert', { source: state.source, format: state.format });
        }
        return state.converted;
      }

      defineProperty(RichString.prototype, 'rtf', { get: function () { return converted(this).rtf; }, configurable: true });
      defineProperty(RichString.prototype, 'html', { get: function () { return converted(this).html; }, configurable: true });
      install('RichString', RichString);

      // A share item: a string is text, a RichString rich text, a URL or `{ url }` an address.
      function shareItem(item) {
        if (typeof item === 'string') return { text: item };
        if (item instanceof RichString) {
          const state = rich(item);
          return { rich: { source: state.source, format: state.format } };
        }
        if (item instanceof URLClass) return { url: urlOf(item) };
        if (item !== null && typeof item === 'object' && typeof item.url === 'string') return { url: item.url };
        throw new TypeError('A share item is a string, a RichString, a URL or { url }.');
      }

      // pasteboard (JS-7)

      const pasteboard = {};
      defineProperty(pasteboard, 'text', {
        get: function () {
          const content = callHostNow(current, 'pasteboard.read', {});
          return typeof content[plainType] === 'string' ? content[plainType] : '';
        },
        set: function (value) {
          const content = {};
          content[plainType] = String(value);
          callHostNow(current, 'pasteboard.write', { content: content });
        },
        enumerable: true,
      });
      defineProperty(pasteboard, 'content', {
        get: function () { return freeze(callHostNow(current, 'pasteboard.read', {})); },
        set: function (value) { callHostNow(current, 'pasteboard.write', { content: contentOf(value) }); },
        enumerable: true,
      });
      install('pasteboard', freeze(pasteboard));

      // util (JS-6). What is pure is worked out here and never crosses (§10.2); the dictionary and the spell
      // checker are the system's, and are asked through the app.

      function bytesOf(data, name) {
        if (typeof data === 'string') return Buffer.from(data, 'utf8');
        if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
        if (data instanceof ArrayBuffer) return Buffer.from(data);
        throw new TypeError(name + ' must be a string or bytes.');
      }

      function base64Encode(data, options) {
        let encoded = bytesOf(data, 'The data').toString('base64');
        if (flag(options, 'urlSafe', false)) encoded = encoded.replace(/\+/g, '-').replace(/\//g, '_');
        if (flag(options, 'trimmed', false)) encoded = encoded.replace(/=+$/, '');
        return encoded;
      }

      // Standard or URL-safe, padded or not; anything outside the alphabet, such as line breaks, is ignored.
      function base64Decode(string, options) {
        const cleaned = String(string).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, '');
        const decoded = Buffer.from(cleaned, 'base64');
        if (flag(options, 'bytes', false)) return new Uint8Array(decoded);
        const text = decoded.toString('utf8');
        if (!Buffer.from(text, 'utf8').equals(decoded)) throw new Error('The decoded data is not text.');
        return text;
      }

      function rot13(text) {
        return text.replace(/[A-Za-z]/g, function (letter) {
          const base = letter <= 'Z' ? 65 : 97;
          return String.fromCharCode((letter.charCodeAt(0) - base + 13) % 26 + base);
        });
      }

      const digestAlgorithms = ['md5', 'sha1', 'sha224', 'sha256', 'sha384', 'sha512'];

      function digest(algorithm, data, key) {
        const name = String(algorithm).toLowerCase();
        if (digestAlgorithms.indexOf(name) < 0) throw new TypeError('The algorithm must be one of ' + digestAlgorithms.join(', ') + '.');
        const result = native.digest(name, bytesOf(data, 'The data').toString('base64'), key === null ? null : bytesOf(key, 'The key').toString('base64'));
        return new Uint8Array(Buffer.from(result, 'base64'));
      }

      function randomBytes(count) {
        return Buffer.from(native.random(count), 'base64');
      }

      const integerArrays = ['Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array', 'BigInt64Array', 'BigUint64Array'];

      function spellingLanguage(options) {
        if (options === undefined || options === null || typeof options.language !== 'string') throw new TypeError('A language is required.');
        return options.language;
      }

      const util = {
        // Titles of PopClip's own actions, in the user's language. The helper has no translations, and
        // the English is what it answers; the bar still shows it.
        localize: function localize(string) { return String(string); },
        hasDictionaryDefinition: function hasDictionaryDefinition(text) {
          return callHostNow(current, 'dictionary.define', { text: String(text) }) !== null;
        },
        getDictionaryDefinition: function getDictionaryDefinition(text) {
          const definition = callHostNow(current, 'dictionary.define', { text: String(text) });
          return definition === null ? undefined : definition;
        },
        getSpellingLanguages: function getSpellingLanguages() { return callHostNow(current, 'spelling.languages', {}); },
        getPreferredSpellingLanguages: function getPreferredSpellingLanguages() { return callHostNow(current, 'spelling.preferred', {}); },
        checkSpelling: function checkSpelling(text, options) {
          return callHostNow(current, 'spelling.check', { text: String(text), language: spellingLanguage(options) });
        },
        getSpellingGuesses: function getSpellingGuesses(text, options) {
          const limit = options && options.limit !== undefined ? Math.max(0, Math.floor(Number(options.limit))) : null;
          return callHostNow(current, 'spelling.guesses', { text: String(text), language: spellingLanguage(options), limit: limit });
        },
        htmlToMarkdown: function htmlToMarkdown(html, options) {
          const Turndown = loadLibrary('turndown');
          const settings = { headingStyle: 'atx' };
          if (options !== null && typeof options === 'object') for (const key of keys(options)) settings[key] = options[key];
          return new Turndown(settings).turndown(String(html));
        },
        cleanHtml: function cleanHtml(html) { return loadLibrary('sanitize-html')(String(html)); },
        base64Encode: base64Encode,
        base64Decode: base64Decode,
        buildQuery: function buildQuery(params) {
          if (params === null || typeof params !== 'object') throw new TypeError('The parameters must be an object.');
          return keys(params).filter(function (key) { return params[key] !== undefined && params[key] !== null; })
            .map(function (key) { return encodeURIComponent(key) + '=' + encodeURIComponent(String(params[key])); }).join('&');
        },
        parseQuery: function parseQuery(query) {
          const result = {};
          for (const pair of String(query).replace(/^\?/, '').split('&')) {
            if (pair === '') continue;
            const at = pair.indexOf('=');
            const name = at < 0 ? pair : pair.slice(0, at);
            const value = at < 0 ? '' : pair.slice(at + 1);
            try {
              result[decodeURIComponent(name)] = decodeURIComponent(value);
            } catch (error) {
              result[name] = value;
            }
          }
          return result;
        },
        // ROT13, then Base64, then JSON: how PopClip's extensions keep client identifiers out of plain sight.
        clarify: function clarify(obscured) { return parse(base64Decode(rot13(String(obscured)))); },
        sleep: global.sleep,
        getRandomValues: function getRandomValues(array) {
          if (!ArrayBuffer.isView(array) || integerArrays.indexOf(Object.prototype.toString.call(array).slice(8, -1)) < 0) {
            throw new TypeError('getRandomValues takes an integer typed array.');
          }
          if (array.byteLength > 65536) throw new RangeError('getRandomValues fills at most 65536 bytes.');
          new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(randomBytes(array.byteLength));
          return array;
        },
        randomUniform: function randomUniform(max) {
          const bound = Number(max) >>> 0;
          if (bound === 0xffffffff) return randomBytes(4).readUInt32LE(0);
          const range = bound + 1;
          const limit = Math.floor(0x100000000 / range) * range;
          for (;;) {
            const value = randomBytes(4).readUInt32LE(0);
            if (value < limit) return value % range;
          }
        },
        randomUuid: function randomUuid() {
          const bytes = randomBytes(16);
          bytes[6] = (bytes[6] & 0x0f) | 0x40;
          bytes[8] = (bytes[8] & 0x3f) | 0x80;
          const hex = bytes.toString('hex');
          return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
        },
        hash: function hash(data, algorithm) { return digest(algorithm, data, null); },
        hmac: function hmac(data, key, algorithm) { return digest(algorithm, data, key); },
        constant: freeze({
          MODIFIER_SHIFT: 131072,
          MODIFIER_CONTROL: 262144,
          MODIFIER_OPTION: 524288,
          MODIFIER_COMMAND: 1048576,
          KEY_RETURN: 0x24,
          KEY_TAB: 0x30,
          KEY_SPACE: 0x31,
          KEY_DELETE: 0x33,
          KEY_ESCAPE: 0x35,
          KEY_LEFTARROW: 0x7b,
          KEY_RIGHTARROW: 0x7c,
          KEY_DOWNARROW: 0x7d,
          KEY_UPARROW: 0x7e,
        }),
      };
      // Read afresh on each access, as PopClip's are.
      defineProperty(util, 'localeInfo', { get: function () { return freeze(native.locale()); }, enumerable: true });
      defineProperty(util, 'timeZoneInfo', { get: function () { return freeze(native.timeZone()); }, enumerable: true });
      install('util', freeze(util));

      // popclip (JS-3, JS-4)

      function ranged(items) {
        const values = items.map(function (item) { return item.value; });
        values.ranges = freeze(items.map(function (item) { return freeze({ location: item.location, length: item.length }); }));
        return freeze(values);
      }

      function inputOf(input) {
        const regex = input.regexResult;
        return freeze({
          text: input.text,
          matchedText: input.matchedText,
          regexResult: regex === undefined || regex === null ? undefined
            : freeze(regex.map(function (group) { return group === null ? undefined : group; })),
          html: input.html,
          xhtml: input.xhtml,
          markdown: input.markdown,
          rtf: input.rtf,
          content: freeze(Object.assign({}, input.content)),
          isUrl: input.isURL === true,
          data: freeze({
            urls: ranged(input.data.urls),
            nonHttpUrls: ranged(input.data.nonHTTPURLs),
            emails: ranged(input.data.emails),
            paths: ranged(input.data.paths),
          }),
        });
      }

      function contextOf(context) {
        return freeze({
          hasFormatting: context.hasFormatting,
          canPaste: context.canPaste,
          canCopy: context.canCopy,
          canCut: context.canCut,
          browserUrl: context.browserURL,
          browserTitle: context.browserTitle,
          appName: context.appName,
          appIdentifier: context.appIdentifier,
        });
      }

      // Booleans read as booleans. `authsecret`, until `auth` has stored one, throws "Not signed in", which
      // is the prefix that sends the user to the extension's settings (JS-11).
      function optionsOf(values, booleans) {
        const options = {};
        for (const key of keys(values)) options[key] = booleans.indexOf(key) >= 0 ? values[key] === '1' : values[key];
        if (typeof options.authsecret !== 'string' || options.authsecret === '') {
          delete options.authsecret;
          defineProperty(options, 'authsecret', { get: function () { throw new Error('Not signed in'); } });
        }
        return freeze(options);
      }

      // What is left for a later week: external scripts are JS-5, and they reject rather than being absent,
      // so a script that reaches for one says why it stopped.
      function notYet(name) {
        return function () {
          return PromiseConstructor.reject(new Error('popclip.' + name + ' is not available in this version of PappuClip.'));
        };
      }

      function popclipFor(state) {
        const invocation = state.invocation;
        function ask(method, args) { return callHost(invocation, method, args); }
        // For the methods that answer nothing: a refusal is the app's to report, and it does (SEC-7b).
        function tell(method, args) { ask(method, args).then(undefined, function () {}); }
        const modifiers = freeze({
          shift: state.modifiers.shift,
          control: state.modifiers.control,
          option: state.modifiers.option,
          command: state.modifiers.command,
        });
        return freeze({
          modifiers: modifiers,
          input: inputOf(state.input),
          context: contextOf(state.context),
          options: optionsOf(state.options, state.booleanOptions),
          pasteText: function pasteText(text, options) {
            return ask('pasteText', { text: String(text), restore: flag(options, 'restore', false) });
          },
          pasteContent: function pasteContent(content, options) {
            return ask('pasteContent', { content: contentOf(content), restore: flag(options, 'restore', false) });
          },
          copyText: function copyText(text, options) {
            return ask('copyText', { text: String(text), notify: flag(options, 'notify', true) });
          },
          copyContent: function copyContent(content, options) {
            return ask('copyContent', { content: contentOf(content), notify: flag(options, 'notify', true) });
          },
          performCommand: function performCommand(command, options) {
            const name = String(command);
            if (['cut', 'copy', 'paste'].indexOf(name) < 0) throw new TypeError('The command must be cut, copy or paste.');
            return ask('performCommand', { command: name, plain: choice(options, 'transform', ['none', 'plain'], 'none') === 'plain' });
          },
          showText: function showText(text, options) {
            tell('showText', {
              text: String(text),
              style: choice(options, 'style', ['compact', 'large'], 'compact'),
              preview: flag(options, 'preview', false),
            });
          },
          showSuccess: function showSuccess() { tell('showSuccess', {}); },
          showFailure: function showFailure() { tell('showFailure', {}); },
          showSettings: function showSettings() { tell('showSettings', {}); },
          signInRequiredError: function signInRequiredError(message) {
            return new Error('Not signed in' + (message === undefined ? '' : ': ' + String(message)));
          },
          settingsRequiredError: function settingsRequiredError(message) {
            return new Error('Settings error' + (message === undefined ? '' : ': ' + String(message)));
          },
          appear: function appear() { tell('appear', {}); },
          pressKey: function pressKey(key, modifiers, options) {
            return ask('pressKeys', { steps: [keyStep(key, modifiers)], target: keyTarget(options) });
          },
          pressKeys: function pressKeys(sequence, options) {
            return ask('pressKeys', { steps: keySteps(sequence), target: keyTarget(options) });
          },
          runAppleScript: notYet('runAppleScript'),
          runAppleScriptFile: notYet('runAppleScriptFile'),
          runShortcut: notYet('runShortcut'),
          runShellScript: notYet('runShellScript'),
          runShellScriptFile: notYet('runShellScriptFile'),
          performService: function performService(name, input) {
            if (typeof name !== 'string' || name === '') throw new TypeError('The service name is required.');
            let content;
            if (typeof input === 'string') {
              content = {};
              content[plainType] = input;
            } else {
              content = contentOf(input);
            }
            return ask('performService', { name: name, content: content });
          },
          revealFile: function revealFile(path) {
            if (typeof path !== 'string' || path === '') throw new TypeError('The path is required.');
            callHostNow(invocation, 'revealFile', { path: path });
          },
          openUrl: function openUrl(url, options) {
            return ask('openUrl', {
              url: urlOf(url),
              app: optionalText(options, 'app'),
              activate: flag(options, 'activate', true),
              backgroundTab: flag(options, 'backgroundTab', false),
            });
          },
          openTemplateUrl: function openTemplateUrl(template, query, options) {
            const values = {};
            const given = options && options.options;
            if (given !== null && typeof given === 'object') for (const key of keys(given)) values[key] = String(given[key]);
            return ask('openTemplateUrl', {
              template: String(template),
              query: String(query),
              clean: flag(options, 'clean', false),
              plus: flag(options, 'plus', false),
              verbatim: options && options.verbatim !== undefined ? Boolean(options.verbatim) : modifiers.option,
              copy: options && options.copy !== undefined ? Boolean(options.copy) : null,
              options: values,
              app: optionalText(options, 'app'),
              activate: flag(options, 'activate', true),
              backgroundTab: flag(options, 'backgroundTab', false),
            });
          },
          share: function share(service, items) {
            if (typeof service !== 'string' || service === '') throw new TypeError('The service name is required.');
            if (!isArray(items)) throw new TypeError('The items must be an array.');
            return ask('share', { service: service, items: items.map(shareItem) });
          },
        });
      }

      // `popclip` and `pappuclip` for the invocation about to run. The state is the app's JSON.
      function enter(state) {
        const popclip = popclipFor(state);
        defineProperty(global, 'popclip', { value: popclip, writable: false, configurable: true });
        defineProperty(global, 'pappuclip', { value: popclip, writable: false, configurable: true });
        current = state.invocation;
        return popclip;
      }

      // The settle the host gave, once every call the invocation made has been answered, which also lets go
      // of `current`.
      function leaving(invocation, settle) {
        return function (kind, value) {
          whenAnswered(invocation, function () {
            if (current === invocation) current = null;
            settle(kind, value);
          });
        };
      }

      function settleWith(promise, settle) {
        promise.then(
          function (value) { settle('returned', typeof value === 'string' ? value : null); },
          function (error) { settle('threw', describe(error)); }
        );
      }

      return freeze({
        fire: fire,
        answer: answer,

        run: function (source, url, base, stateJSON, reply, typeScript) {
          const state = parse(stateJSON);
          const settle = leaving(state.invocation, reply);
          let script;
          try {
            // An action's own file follows the rule `require` does: TypeScript, `.mjs`, and `.js` with
            // `import` or `export` statements are transpiled.
            const text = typeScript ? transpile(source, 'typescript', url) : base === '' ? source : commonJS(base, source);
            script = compile(text, url, scriptParameters, 'async ');
          } catch (error) {
            reply('threw', describe(error));
            return;
          }
          enter(state);
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
          settleWith(promise, settle);
        },

        // JS-12: what a module extension is. `{ exports, functions }`, or `{ error }`.
        describe: function (source, isFile, typeScript) {
          try {
            return describeExtension(extensionOf(loadModule(source, isFile, typeScript)));
          } catch (error) {
            return { error: describe(error) };
          }
        },

        // JS-12: run a module's action, the function at `path`, as PopClip calls it:
        // `code(input, options, context)`, with the action object as `this` when it has one.
        runExport: function (source, isFile, typeScript, path, stateJSON, reply) {
          const state = parse(stateJSON);
          const settle = leaving(state.invocation, reply);
          let promise;
          try {
            const action = exportedAction(extensionOf(loadModule(source, isFile, typeScript)), path);
            const popclip = enter(state);
            const result = typeof action === 'function'
              ? action.call(undefined, popclip.input, popclip.options, popclip.context)
              : action.code.call(action, popclip.input, popclip.options, popclip.context);
            promise = PromiseConstructor.resolve(result);
          } catch (error) {
            settle('threw', describe(error));
            return;
          }
          settleWith(promise, settle);
        }
      });
    })
    """#
}

/// Synchronous host calls in flight in one world (architecture §10.2's blocking form).
///
/// The world's queue waits in `answer(within:)`, so whatever ends a wait early has to reach it from
/// somewhere else: the app's answer, from the transport's queue, or `interrupt`, from the host's, for a
/// `drop` or a world that is going away.
final class BlockingCalls: Sendable {
    final class Wait: @unchecked Sendable {
        let invocation: UInt64
        private let given = Mutex<JSHostAnswer?>(nil)
        private let signal = DispatchSemaphore(value: 0)

        init(invocation: UInt64) {
            self.invocation = invocation
        }

        /// The first answer wins; any later one is ignored.
        func fulfil(_ answer: JSHostAnswer) {
            let first = given.withLock { given -> Bool in
                guard given == nil else { return false }
                given = answer
                return true
            }
            if first { signal.signal() }
        }

        /// Nil when nothing came within `limit`.
        func answer(within limit: Duration) -> JSHostAnswer? {
            let milliseconds = Int(limit / .milliseconds(1))
            _ = signal.wait(timeout: .now() + .milliseconds(milliseconds))
            return given.withLock { $0 }
        }
    }

    private let waits = Mutex<[ObjectIdentifier: Wait]>([:])

    func open(for invocation: UInt64) -> Wait {
        let wait = Wait(invocation: invocation)
        waits.withLock { $0[ObjectIdentifier(wait)] = wait }
        return wait
    }

    func close(_ wait: Wait) {
        waits.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(wait)) }
    }

    /// Answers each open wait `which` picks as refused: its action is being dropped, or its world is.
    func interrupt(_ which: (UInt64) -> Bool) {
        let all = waits.withLock { Array($0.values) }
        for wait in all where which(wait.invocation) { wait.fulfil(.refused("The action was stopped.")) }
    }
}
