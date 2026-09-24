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
            host = JSHost { name, line in lines.append((name, line)) }
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
            id: UInt64? = nil
        ) async -> JSHostReply {
            await ask(.invoke(JSInvoke(
                invocation: id ?? nextID(),
                extensionName: name,
                generation: generation,
                entry: entry,
                input: JSInput(text: text, matchedText: text),
                options: options
            )))
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
        let script = "return [typeof fetch, typeof process, typeof document, typeof XMLHttpRequest, typeof window].join()"
        #expect(await harness.run("a", script) == .returned("undefined,undefined,undefined,undefined,undefined"))
        #expect(await harness.run("a", "require('fs')") == .threw("Cannot find module 'fs'"))
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

@Suite struct ModulePathTests {
    @Test func normalises() {
        #expect(ModulePath.normalize("a/./b/../c.js") == "a/c.js")
        #expect(ModulePath.normalize("./x.js") == "x.js")
        #expect(ModulePath.normalize("../x.js") == nil)
        #expect(ModulePath.normalize("/x.js") == nil)
        #expect(ModulePath.normalize("a/../..") == nil)
    }

    @Test func resolvesAsNodeDoesForRelativePaths() {
        let files: Set = ["lib/a.js", "lib/b/index.js", "data.json"]
        #expect(ModulePath.resolve("./a", from: "lib/main.js", in: files) == "lib/a.js")
        #expect(ModulePath.resolve("./b", from: "lib/main.js", in: files) == "lib/b/index.js")
        #expect(ModulePath.resolve("../data", from: "lib/main.js", in: files) == "data.json")
        #expect(ModulePath.resolve("./data.json", from: "", in: files) == "data.json")
        #expect(ModulePath.resolve("lodash", from: "", in: files) == nil)
        #expect(ModulePath.resolve("../data", from: "", in: files) == nil)
    }
}
