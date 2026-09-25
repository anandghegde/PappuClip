import Foundation
import PappuJSBridge
@testable import PappuJSHost
import Synchronization
import Testing

/// The helper's side of §8.8 and SEC-1b, in this process rather than over XPC: the transport is
/// `JSHostClient`'s and is tested there. What is tested here is what a request does to a world.
@Suite struct JSHostTests {
    final class Harness: Sendable {
        final class Lines: Sendable {
            private let lines = Mutex<[(String, String)]>([])
            func append(_ line: (String, String)) { lines.withLock { $0.append(line) } }
            func withLock<T>(_ body: ([(String, String)]) -> T) -> T { lines.withLock { body($0) } }
        }

        let lines = Lines()
        let host: JSHost
        private let ids = Mutex<UInt64>(0)

        init() {
            let lines = lines
            // Below the test's own priority: a world spinning here must not starve its timers.
            host = JSHost(qos: .utility) { name, line in lines.append((name, line)) }
        }

        func ask(_ request: JSHostRequest) async -> JSHostReply {
            await withCheckedContinuation { continuation in
                host.handle(request) { continuation.resume(returning: $0) }
            }
        }

        @discardableResult
        func load(_ name: String, generation: String = "1", files: [String: String] = [:]) async -> JSHostReply {
            await ask(.load(JSLoad(extensionName: name, generation: generation, files: files)))
        }

        func nextID() -> UInt64 {
            ids.withLock { $0 += 1; return $0 }
        }

        func invoke(
            _ name: String,
            _ entry: JSInvoke.Entry,
            text: String = "hello",
            generation: String = "1",
            options: [String: String] = [:],
            typeScript: Bool = false,
            export: String? = nil,
            id: UInt64? = nil
        ) async -> JSHostReply {
            await ask(.invoke(JSInvoke(
                invocation: id ?? nextID(),
                extensionName: name,
                generation: generation,
                entry: entry,
                input: JSInput(text: text, matchedText: text),
                options: options,
                typeScript: typeScript,
                export: export
            )))
        }

        func describe(_ name: String, _ entry: JSInvoke.Entry, typeScript: Bool = false, generation: String = "1") async -> JSHostReply {
            await ask(.describe(JSDescribe(extensionName: name, generation: generation, entry: entry, typeScript: typeScript)))
        }

        func printed() -> [String] {
            lines.withLock { $0.map(\.1) }
        }

        func run(_ name: String, _ script: String, text: String = "hello") async -> JSHostReply {
            await invoke(name, .inline(script), text: text)
        }
    }

    // MARK: §8.8, JS-11

    @Test func aReturnedStringIsTheResult() async {
        let harness = Harness()
        #expect(await harness.load("a") == .loaded)
        #expect(await harness.run("a", "return popclip.input.text.toUpperCase()") == .returned("HELLO"))
    }

    @Test func anythingButAStringIsNoResult() async {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.run("a", "return 42") == .returned(nil))
        #expect(await harness.run("a", "const x = 1") == .returned(nil))
    }

    @Test func theScriptIsAnAsyncFunction() async {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.run("a", "const x = await Promise.resolve('later'); return x") == .returned("later"))
    }

    @Test func aThrownErrorIsItsMessage() async {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.run("a", "throw new Error('Settings error: no key')") == .threw("Settings error: no key"))
        #expect(await harness.run("a", "await Promise.reject('nope')") == .threw("nope"))
        #expect(await harness.run("a", "undefinedThing()") == .threw("Can't find variable: undefinedThing"))
    }

    @Test func aScriptThatDoesNotParseThrows() async {
        let harness = Harness()
        await harness.load("a")
        guard case .threw = await harness.run("a", "return (") else {
            Issue.record("A syntax error should be thrown")
            return
        }
    }

    @Test func optionsAndInputAreReadOnly() async {
        let harness = Harness()
        await harness.load("a")
        let script = """
        'use strict';
        try { popclip.input.text = 'x' } catch (e) { return 'frozen:' + popclip.options.lang }
        return 'writable'
        """
        #expect(await harness.invoke("a", .inline(script), options: ["lang": "fr"]) == .returned("frozen:fr"))
    }

    // MARK: JS-1

    @Test func thereIsNoFetchProcessDOMOrFileSystem() async {
        let harness = Harness()
        await harness.load("a")
        let script = "return [typeof fetch, typeof process, typeof document, typeof XMLHttpRequest].join()"
        #expect(await harness.run("a", script) == .returned("undefined,undefined,undefined,undefined"))
        // `window` is only the global object, for libraries that look for one (JS-2).
        #expect(await harness.run("a", "return String(window === globalThis)") == .returned("true"))
        #expect(await harness.run("a", "return typeof require('fs')") == .returned("undefined"))
    }

    @Test func printGoesToTheLog() async {
        let harness = Harness()
        await harness.load("a")
        _ = await harness.run("a", "print('one', 2, {three: 3}); console.log('four')")
        let lines = harness.lines.withLock { $0.map { "\($0.0): \($0.1)" } }
        #expect(lines == ["a: one 2 {\"three\":3}", "a: four"])
    }

    @Test func aLongLineIsCut() async {
        let harness = Harness()
        await harness.load("a")
        _ = await harness.run("a", "print('x'.repeat(10000))")
        let line = harness.lines.withLock { $0.first?.1 ?? "" }
        #expect(line.count == ExtensionVM.lineLimit + 1)
    }

    // MARK: JS-10

    @Test func requireIsRelativeToTheRequiringFile() async {
        let harness = Harness()
        await harness.load("a", files: [
            "lib/greet.js": "const name = require('./name'); module.exports = (s) => 'hi ' + name + ' ' + s",
            "lib/name.json": "\"pappu\"",
            "main.js": "return require('./lib/greet.js')(popclip.input.text)",
        ])
        #expect(await harness.invoke("a", .file("main.js")) == .returned("hi pappu hello"))
        #expect(await harness.run("a", "return require('./lib/greet')('there')") == .returned("hi pappu there"))
    }

    @Test func requireCannotLeaveThePackage() async {
        let harness = Harness()
        await harness.load("a", files: ["lib/x.js": "module.exports = require('../../etc/passwd')"])
        #expect(await harness.run("a", "return require('../secret')") == .threw("Cannot find module '../secret'"))
        #expect(await harness.run("a", "return require('/etc/passwd')") == .threw("Cannot find module '/etc/passwd'"))
        #expect(await harness.run("a", "require('./lib/x')") == .threw("Cannot find module '../../etc/passwd'"))
    }

    @Test func aModuleIsEvaluatedOncePerWorld() async {
        let harness = Harness()
        await harness.load("a", files: ["count.js": "globalThis.loads = (globalThis.loads || 0) + 1; module.exports = {n: 0}"])
        _ = await harness.run("a", "require('./count').n += 1")
        #expect(await harness.run("a", "return require('./count').n + '/' + loads") == .returned("1/1"))
    }

    @Test func aMissingScriptFileThrows() async {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.invoke("a", .file("nope.js")) == .threw("Cannot find the script nope.js."))
    }

    // MARK: The environment (JS-2, JS-9, JS-10, JS-14)

    /// The implementation plan's "done when" for M3 week 2: the conformance suite's environment
    /// section, `Tests/conformance/environment`, run as the package it is.
    @Test func theEnvironmentSectionOfTheConformanceSuitePasses() async throws {
        let suite = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/conformance/environment")
        let files = try Self.files(in: suite)
        try #require(files["suite.js"] != nil, "Tests/conformance/environment/suite.js is missing")
        let harness = Harness()
        #expect(await harness.load("conformance", files: files) == .loaded)
        #expect(await harness.invoke("conformance", .file("suite.js")) == .returned("ok"))
    }

    /// The scripts and JSON under `folder`, by path relative to it: what `PackageSources` would send.
    static func files(in folder: URL) throws -> [String: String] {
        let root = folder.standardizedFileURL.path + "/"
        var files: [String: String] = [:]
        let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = walker?.nextObject() as? URL {
            guard ["js", "cjs", "mjs", "ts", "json"].contains(url.pathExtension),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            files[String(url.standardizedFileURL.path.dropFirst(root.count))] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    @Test func aTimerOutlivesItsInvocation() async throws {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.run("a", "setTimeout(() => print('later'), 20); return 'now'") == .returned("now"))
        // The world runs below the test's priority, so give it a while rather than a deadline.
        for _ in 0..<200 where harness.printed().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.printed() == ["later"])
    }

    /// A world that is abandoned — unloaded or replaced — runs nothing it scheduled. The script sets its
    /// timer as it starts and the world is abandoned in the same turn of its queue, so the timer's
    /// turn can only come afterwards: no race with the test's own timing.
    @Test func aTimerDoesNotOutliveItsWorld() async throws {
        let lines = Harness.Lines()
        let machine = ExtensionVM(load: JSLoad(extensionName: "a", generation: "1", files: [:]), qos: .utility) { line in
            lines.append(("a", line))
        }
        #expect(machine.queue.sync { machine.prepare() } == nil)
        machine.queue.sync {
            let invocation = JSInvoke(
                invocation: 1,
                extensionName: "a",
                generation: "1",
                entry: .inline("setTimeout(() => print('never'), 0)"),
                input: JSInput(text: "", matchedText: "")
            )
            machine.invoke(invocation) { _ in }
            machine.abandon()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.withLock { $0.isEmpty })
    }

    @Test func aTimerCallbackThatThrowsIsWrittenDownAndNothingElse() async {
        let harness = Harness()
        await harness.load("a")
        let script = "setTimeout(() => { throw new Error('boom') }, 0); await sleep(20); return 'still here'"
        #expect(await harness.run("a", script) == .returned("still here"))
        #expect(harness.printed() == ["Uncaught boom"])
    }

    @Test func anInlineTypeScriptActionIsTranspiledImportsIncluded() async {
        let harness = Harness()
        await harness.load("a")
        let script = "import yaml from 'js-yaml'\nconst n: number = yaml.load('a: 2').a\nreturn String(n * 2) as string"
        #expect(await harness.invoke("a", .inline(script), typeScript: true) == .returned("4"))
    }

    /// An action's own file follows `require`'s rule: `.mjs`, and `.js` with `import` statements.
    @Test func anActionFileWithImportStatementsIsTranspiled() async {
        let harness = Harness()
        await harness.load("a", files: [
            "main.mjs": "import yaml from 'js-yaml'\nreturn yaml.dump({ a: 1 }).trim()",
            "main.js": "import { x } from './x.mjs'\nreturn x",
            "x.mjs": "export const x = 'x'",
        ])
        #expect(await harness.invoke("a", .file("main.mjs")) == .returned("a: 1"))
        #expect(await harness.invoke("a", .file("main.js")) == .returned("x"))
    }

    @Test func aTypeScriptSyntaxErrorIsThrownWithItsPlace() async {
        let harness = Harness()
        await harness.load("a")
        guard case .threw(let message) = await harness.invoke("a", .inline("const x: = 1"), typeScript: true) else {
            Issue.record("A syntax error should be thrown")
            return
        }
        #expect(message.hasPrefix("pappuclip:action: "))
    }

    @Test func aBareNameIsLookedForInThePackageBeforeTheLibraries() async {
        let harness = Harness()
        await harness.load("own", files: ["js-yaml.js": "module.exports = 'the package\u{2019}s own'"])
        await harness.load("plain")
        #expect(await harness.run("own", "return require('js-yaml')") == .returned("the package\u{2019}s own"))
        #expect(await harness.run("plain", "return typeof require('js-yaml').load") == .returned("function"))
    }

    @Test func whatIsNotFoundIsUndefinedAndTheConsoleSaysSo() async {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.run("a", "return String(require('lodash'))") == .returned("undefined"))
        #expect(harness.printed() == ["require('lodash') found nothing, so it is undefined."])
    }

    /// PopClip's `module`, `define` and the rest are globals, which a script may shadow. Here they are
    /// the script's own, from a scope outside it, so it still may.
    @Test func aScriptMayDeclareTheNamesItIsGiven() async {
        let harness = Harness()
        await harness.load("a")
        let script = "const module = 'm'; let define = 'd'; class exports {}; const require = 1; return module + define + typeof exports + require"
        #expect(await harness.run("a", script) == .returned("mdfunction1"))
    }

    @Test func twoExtensionsDoNotShareALibrary() async {
        let harness = Harness()
        await harness.load("a")
        await harness.load("b")
        _ = await harness.run("a", "require('js-yaml').added = 1; Buffer.added = 1; URL.prototype.added = 1")
        let script = "return [typeof require('js-yaml').added, typeof Buffer.added, typeof URL.prototype.added].join()"
        #expect(await harness.run("b", script) == .returned("undefined,undefined,undefined"))
    }

    // MARK: Modules (JS-12)

    static let moduleFiles = [
        "Config.js": """
        defineExtension({
          options: [{ identifier: 'suffix', type: 'string' }],
          regex: /^h/i,
          action: { title: 'Solo', code(input, options) { return this.title + ':' + input.text + options.suffix } },
          actions: [(input) => input.matchedText.toUpperCase(), { title: 'Label' }],
          test() {},
        })
        """,
    ]

    @Test func aModuleIsDescribedAsDataWithItsCodeMarked() async {
        let harness = Harness()
        await harness.load("a", files: Self.moduleFiles)
        let exports = #"{"options":[{"identifier":"suffix","type":"string"}],"regex":"(?i)^h","action":{"title":"Solo","code":true},"actions":[{"code":true},{"title":"Label"}]}"#
        #expect(await harness.describe("a", .file("Config.js")) == .described(JSModuleDescription(exports: exports, functions: ["test"])))
    }

    @Test func aModulesActionRunsTheCodeAtItsExport() async {
        let harness = Harness()
        await harness.load("a", files: Self.moduleFiles)
        #expect(await harness.invoke("a", .file("Config.js"), options: ["suffix": "!"], export: "action") == .returned("Solo:hello!"))
        #expect(await harness.invoke("a", .file("Config.js"), export: "actions.0") == .returned("HELLO"))
        #expect(await harness.invoke("a", .file("Config.js"), export: "actions.1") == .threw("The module has no action at actions.1."))
    }

    @Test func aSnippetThatIsAModuleIsItsOwnText() async {
        let harness = Harness()
        await harness.load("a")
        let text = "// #popclip\n// name: S\nexport default { action: (input: { text: string }) => `${input.text}?` }"
        #expect(await harness.describe("a", .inline(text), typeScript: true) == .described(JSModuleDescription(exports: #"{"action":{"code":true}}"#, functions: [])))
        #expect(await harness.invoke("a", .inline(text), typeScript: true, export: "action") == .returned("hello?"))
    }

    @Test func aModuleThatCannotBeDescribedSaysWhy() async {
        let harness = Harness()
        await harness.load("a", files: ["throws.js": "throw new Error('at load')", "number.js": "module.exports = 42"])
        #expect(await harness.describe("a", .file("throws.js")) == .threw("at load"))
        #expect(await harness.describe("a", .file("number.js")) == .threw("The module exports number, not an extension object."))
        #expect(await harness.describe("a", .file("../outside.js")) == .threw("Cannot find the module ../outside.js."))
    }

    @Test func describingNeedsTheWorldAtThatGeneration() async {
        let harness = Harness()
        #expect(await harness.describe("a", .file("Config.js")) == .notLoaded)
        await harness.load("a", generation: "1", files: Self.moduleFiles)
        #expect(await harness.describe("a", .file("Config.js"), generation: "2") == .notLoaded)
    }

    // MARK: SEC-1b

    @Test func twoExtensionsCannotSeeEachOthersGlobals() async {
        let harness = Harness()
        await harness.load("a")
        await harness.load("b")
        _ = await harness.run("a", "globalThis.secret = 'a-only'; Array.prototype.leak = 1; print = () => {}")
        #expect(await harness.run("b", "return typeof secret + ',' + typeof [].leak") == .returned("undefined,undefined"))
        _ = await harness.run("b", "print('b still prints')")
        #expect(harness.lines.withLock { $0.map(\.1) } == ["b still prints"])
        #expect(await harness.run("a", "return secret") == .returned("a-only"))
    }

    @Test func twoExtensionsCannotSeeEachOthersModuleCaches() async {
        let harness = Harness()
        let files = ["state.js": "module.exports = {value: 'fresh'}"]
        await harness.load("a", files: files)
        await harness.load("b", files: files)
        _ = await harness.run("a", "require('./state').value = 'changed by a'")
        #expect(await harness.run("b", "return require('./state').value") == .returned("fresh"))
        #expect(await harness.run("a", "return require('./state').value") == .returned("changed by a"))
    }

    // MARK: Lifecycle

    @Test func anExtensionThatIsNotLoadedIsSaid() async {
        let harness = Harness()
        #expect(await harness.run("a", "return 'x'") == .notLoaded)
        await harness.load("a", generation: "1")
        #expect(await harness.invoke("a", .inline("return 'x'"), generation: "2") == .notLoaded)
    }

    @Test func reloadingStartsAFreshWorld() async {
        let harness = Harness()
        await harness.load("a", generation: "1")
        _ = await harness.run("a", "globalThis.kept = 'yes'")
        await harness.load("a", generation: "2")
        #expect(await harness.invoke("a", .inline("return typeof kept"), generation: "2") == .returned("undefined"))
    }

    @Test func unloadForgetsTheWorld() async {
        let harness = Harness()
        await harness.load("a")
        #expect(await harness.ask(.unload(extension: "a")) == .unloaded)
        #expect(harness.host.loaded.isEmpty)
        #expect(await harness.run("a", "return 'x'") == .notLoaded)
    }

    @Test func dropAnswersAScriptThatNeverSettles() async {
        let harness = Harness()
        await harness.load("a")
        let id = harness.nextID()
        async let invoked = harness.invoke("a", .inline("await new Promise(() => {})"), id: id)
        // The invocation has to reach the world before it can be dropped; the queue is serial, so a
        // second request behind it proves it has.
        #expect(await harness.run("a", "return 'behind'") == .returned("behind"))
        #expect(await harness.ask(.drop(invocation: id)) == .dropped)
        #expect(await invoked == .dropped)
    }

    @Test func aSlowExtensionDoesNotHoldUpAnother() async {
        let harness = Harness()
        await harness.load("slow")
        await harness.load("fast")
        let id = harness.nextID()
        // Busy for about a second on its own queue.
        async let slow = harness.invoke("slow", .inline("const end = Date.now() + 1000; while (Date.now() < end) {}; return 'done'"), id: id)
        let start = ContinuousClock.now
        #expect(await harness.run("fast", "return 'quick'") == .returned("quick"))
        #expect(start.duration(to: .now) < .milliseconds(500))
        #expect(await slow == .returned("done"))
    }
}

/// The host API from the helper's side (JS-3, JS-4, JS-6, JS-7, architecture §10.2): what a script's
/// calls send to the app, what comes back, and what the helper works out without asking.
@Suite struct JSHostAPITests {
    /// The app, as far as the helper can tell: it keeps each call and answers as the test says, in line,
    /// or never.
    final class App: Sendable {
        private let received = Mutex<[JSHostCall]>([])
        private let answering: @Sendable (JSHostCall) -> JSHostAnswer?

        init(_ answering: @escaping @Sendable (JSHostCall) -> JSHostAnswer? = { _ in .done }) {
            self.answering = answering
        }

        var calls: [JSHostCall] { received.withLock { $0 } }

        func handle(_ call: JSHostCall, _ reply: @escaping @Sendable (JSHostAnswer) -> Void) {
            received.withLock { $0.append(call) }
            if let answer = answering(call) { reply(answer) }
        }
    }

    /// A helper whose app is `app`.
    struct Harness: Sendable {
        let app: App
        let host: JSHost

        init(_ answering: @escaping @Sendable (JSHostCall) -> JSHostAnswer? = { _ in .done }) {
            let app = App(answering)
            self.app = app
            host = JSHost(qos: .utility, call: { call, reply in app.handle(call, reply) }) { _, _ in }
        }

        func ask(_ request: JSHostRequest) async -> JSHostReply {
            await withCheckedContinuation { continuation in
                host.handle(request) { continuation.resume(returning: $0) }
            }
        }

        func run(_ script: String, id: UInt64 = 1, input: JSInput = JSInput(text: "hello", matchedText: "hello")) async -> JSHostReply {
            _ = await ask(.load(JSLoad(extensionName: "a", generation: "1", files: [:])))
            return await ask(.invoke(JSInvoke(invocation: id, extensionName: "a", generation: "1", entry: .inline(script), input: input)))
        }
    }

    /// The world fills in whose call it is; the script says only what it wants.
    @Test func aCallCarriesItsInvocationAndItsWorld() async {
        let tests = Harness()
        #expect(await tests.run("await popclip.pasteText('x', { restore: true }); return 'ok'", id: 42) == .returned("ok"))
        #expect(tests.app.calls == [JSHostCall(invocation: 42, extensionName: "a", method: "pasteText", arguments: #"{"text":"x","restore":true}"#)])
    }

    @Test func aRefusalRejectsThePromise() async {
        let tests = Harness { _ in .refused("Not for you.") }
        #expect(await tests.run("try { await popclip.copyText('x') } catch (e) { return e.message }") == .returned("Not for you."))
    }

    /// An un-awaited call at the end of a script is done before its run is over.
    @Test func aRunEndsOnlyOnceItsCallsAreAnswered() async {
        let tests = Harness()
        #expect(await tests.run("popclip.copyText('x'); popclip.showSuccess(); return 'ok'") == .returned("ok"))
        #expect(tests.app.calls.map(\.method) == ["copyText", "showSuccess"])
    }

    @Test func aSynchronousCallIsAnsweredInLine() async {
        let tests = Harness { call in
            call.method == "pasteboard.read" ? .value(#"{"public.utf8-plain-text":"clip"}"#) : .done
        }
        #expect(await tests.run("const t = pasteboard.text; pasteboard.text = t + '!'; return t") == .returned("clip"))
        #expect(tests.app.calls.map(\.method) == ["pasteboard.read", "pasteboard.write"])
    }

    /// A script waiting in a synchronous call holds its world's queue; a drop ends the wait from outside
    /// it rather than waiting `blockingLimit` for the app.
    @Test func aDropEndsAWaitingCall() async {
        let tests = Harness { _ in nil }
        _ = await tests.ask(.load(JSLoad(extensionName: "a", generation: "1", files: [:])))
        let start = ContinuousClock.now
        async let invoked = tests.ask(.invoke(JSInvoke(
            invocation: 7, extensionName: "a", generation: "1", entry: .inline("return pasteboard.text"), input: JSInput(text: "", matchedText: "")
        )))
        for _ in 0..<500 where tests.app.calls.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(tests.app.calls.map(\.method) == ["pasteboard.read"])
        #expect(await tests.ask(.drop(invocation: 7)) == .dropped)
        #expect(await invoked == .dropped)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    /// JS-6: the digests are CommonCrypto's and CryptoKit's, checked against the standard vectors.
    @Test func hashesAndHMACsAreTheStandardOnes() async {
        let script = """
        const hex = (bytes) => Buffer.from(bytes).toString('hex');
        const abc = Buffer.from('abc');
        const fox = Buffer.from('The quick brown fox jumps over the lazy dog');
        const key = Buffer.from('key');
        return [
          hex(util.hash(abc, 'md5')), hex(util.hash(abc, 'sha1')), hex(util.hash(abc, 'sha224')),
          hex(util.hash(abc, 'sha256')), hex(util.hash(abc, 'sha512')).slice(0, 16),
          hex(util.hmac(fox, key, 'md5')), hex(util.hmac(fox, key, 'sha1')), hex(util.hmac(fox, key, 'sha224')),
          hex(util.hmac(fox, key, 'sha256')),
        ].join(' ');
        """
        let expected = [
            "900150983cd24fb0d6963f7d28e17f72", "a9993e364706816aba3e25717850c26c9cd0d89d",
            "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "ddaf35a193617aba",
            "80070713463e7749b90c2dc24911e275", "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9",
            "88ff8b54675d39b8f72322e65ff945c52d96379988ada25639747e69",
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
        ].joined(separator: " ")
        #expect(await Harness().run(script) == .returned(expected))
    }

    @Test func randomValuesComeFromTheSystem() async {
        let script = """
        const a = util.randomUuid(), b = util.randomUuid();
        const bytes = util.getRandomValues(new Uint8Array(32));
        return [a !== b, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(a), bytes.some((x) => x !== 0)].join();
        """
        #expect(await Harness().run(script) == .returned("true,true,true"))
    }

    @Test func theLocaleAndTimeZoneAreTheSystems() async {
        let locale = ExtensionVM.localeInfo()
        let zone = ExtensionVM.timeZoneInfo()
        let script = "return [util.localeInfo.localeIdentifier, util.localeInfo.currencyCode, util.timeZoneInfo.identifier].join('|')"
        let expected = [locale["localeIdentifier"] ?? "", locale["currencyCode"] ?? "", zone["identifier"] as? String ?? ""].joined(separator: "|")
        #expect(await Harness().run(script) == .returned(expected))
    }

    /// JS-3: the input as the app sends it, under PopClip's names.
    @Test func theInputIsPopClipsShape() async {
        let input = JSInput(
            text: "mail a@b.test",
            matchedText: "a@b.test",
            regexResult: ["a@b.test", nil],
            isURL: false,
            data: JSDetected(emails: [JSRangedString(value: "a@b.test", location: 5, length: 8)])
        )
        let script = "const i = popclip.input; return JSON.stringify([i.matchedText, i.regexResult.length, i.regexResult[1] === undefined, i.data.emails, i.data.emails.ranges, i.content, i.isUrl])"
        let expected = #"["a@b.test",2,true,["a@b.test"],[{"location":5,"length":8}],{"public.utf8-plain-text":"mail a@b.test"},false]"#
        #expect(await Harness().run(script, input: input) == .returned(expected))
    }
}

@Suite struct ModulePathTests {
    @Test func normalises() {
        #expect(ModulePath.normalize("a/./b/../c.js") == "a/c.js")
        #expect(ModulePath.normalize("./x.js") == "x.js")
        #expect(ModulePath.normalize("../x.js") == nil)
        #expect(ModulePath.normalize("/x.js") == nil)
        #expect(ModulePath.normalize("a/../..") == nil)
    }

    static let files: Set = ["lib/a.js", "lib/b/index.js", "lib/c.ts", "data.json", "types/index.ts"]

    @Test func resolvesAsNodeDoesForRelativePaths() {
        let files = Self.files
        #expect(ModulePath.resolve("./a", from: "lib/main.js", in: files) == .file("lib/a.js"))
        #expect(ModulePath.resolve("./b", from: "lib/main.js", in: files) == .file("lib/b/index.js"))
        #expect(ModulePath.resolve("./c", from: "lib/main.js", in: files) == .file("lib/c.ts"))
        #expect(ModulePath.resolve("../data", from: "lib/main.js", in: files) == .file("data.json"))
        #expect(ModulePath.resolve("./data.json", from: "", in: files) == .file("data.json"))
        #expect(ModulePath.resolve("./nope", from: "", in: files) == .missing)
    }

    /// JS-10 and PopClip: anything but `./` and `../` is from the package root, whoever asks.
    @Test func otherPathsAreFromThePackageRoot() {
        let files = Self.files
        #expect(ModulePath.resolve("lib/a", from: "lib/deep/main.js", in: files) == .file("lib/a.js"))
        #expect(ModulePath.resolve("types", from: "", in: files) == .file("types/index.ts"))
        #expect(ModulePath.resolve("lodash", from: "", in: files) == .missing)
    }

    @Test func anAbsolutePathOrAnEscapeIsInvalid() {
        let files = Self.files
        #expect(ModulePath.resolve("../data", from: "", in: files) == .invalid)
        #expect(ModulePath.resolve("../../data", from: "lib/main.js", in: files) == .invalid)
        #expect(ModulePath.resolve("/data.json", from: "", in: files) == .invalid)
        #expect(ModulePath.resolve("lib/../../data", from: "", in: files) == .invalid)
        #expect(ModulePath.resolve("", from: "", in: files) == .invalid)
    }
}

@Suite struct TranspilerTests {
    @Test func typesAreRemovedAndModulesBecomeCommonJS() throws {
        let transpiler = Transpiler()
        let typeScript = try transpiler.transform("const x: number = 1\nexport default x", as: .typeScript).get()
        #expect(typeScript.contains("const x = 1"))
        #expect(typeScript.contains("exports. default = x"))
        let module = try transpiler.transform("import a from 'a'\nexport const b = a", as: .module).get()
        #expect(module.contains("require('a')"))
    }

    @Test func linesStayWhereTheAuthorPutThem() throws {
        let output = try Transpiler().transform("type A = string\n\nconst a: A = 'x'\nthrow new Error(a)", as: .typeScript).get()
        #expect(output.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
    }

    @Test func aSyntaxErrorSaysWhere() {
        guard case .failure(let error) = Transpiler().transform("const x: = 1", as: .typeScript) else {
            Issue.record("A syntax error should fail")
            return
        }
        #expect(error.message.contains("(1:"))
    }
}

@Suite struct JavaScriptResourcesTests {
    /// JS-9's list: every name but `buffer`, which the environment serves, is a file of its own.
    @Test func everyBundledLibraryIsThere() {
        let names = [
            "axios", "case-anything", "content-type", "dom-serializer", "emoji-regex", "entities",
            "fast-json-stable-stringify", "fast-plist", "htmlparser2", "js-yaml", "linkedom", "linkifyjs",
            "oauth-1.0a", "rot13-cipher", "sanitize-html", "sucrase", "turndown", "valibot",
        ]
        #expect(Set(JavaScriptResources.libraryFiles.keys) == Set(names))
        #expect(names.filter { JavaScriptResources.library($0) == nil } == [])
        #expect(JavaScriptResources.environment != nil)
    }

    @Test func aNameIsLookedUpAndNeverMadeIntoAPath() {
        #expect(JavaScriptResources.library("../environment") == nil)
        #expect(JavaScriptResources.library("libraries/axios") == nil)
        #expect(JavaScriptResources.library("buffer") == nil)
    }
}
