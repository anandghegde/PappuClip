import Foundation
import PappuJSBridge
@testable import PappuJSHost
import Synchronization
import Testing

/// JS-13: a population function runs in its extension's world with nothing to act through, and the
/// actions it offers are the ones that run when clicked (architecture §10.6).
@Suite struct PopulationTests {
    final class Harness: Sendable {
        let host: JSHost
        let app = JSHostAPITests.App()

        init() {
            let app = app
            host = JSHost(qos: .utility, call: { call, reply in app.handle(call, reply) }) { _, _ in }
        }

        var calls: [JSHostCall] { app.calls }

        func ask(_ request: JSHostRequest) async -> JSHostReply {
            await withCheckedContinuation { continuation in
                host.handle(request) { continuation.resume(returning: $0) }
            }
        }

        func load(_ source: String) async {
            _ = await ask(.load(JSLoad(extensionName: "a", generation: "1", files: ["Config.js": source])))
        }

        func populate(attempt: UInt64 = 1, text: String = "hello", options: [String: String] = [:], generation: String = "1") async -> JSHostReply {
            await ask(.populate(JSPopulate(
                attempt: attempt,
                extensionName: "a",
                generation: generation,
                entry: .file("Config.js"),
                input: JSInput(text: text, matchedText: text),
                context: JSSelectionContext(appName: "Notes"),
                options: options
            )))
        }

        func invoke(_ export: String, id: UInt64 = 100) async -> JSHostReply {
            await ask(.invoke(JSInvoke(
                invocation: id,
                extensionName: "a",
                generation: "1",
                entry: .file("Config.js"),
                input: JSInput(text: "clicked", matchedText: "clicked"),
                export: export
            )))
        }

        /// The titles of what was offered.
        func titles(_ reply: JSHostReply) -> [String] {
            guard case .populated(let population) = reply,
                  let data = population.actions.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return list.compactMap { $0["title"] as? String }
        }
    }

    static let offering = """
    module.exports = {
      actions: (input, options, context) => [
        { title: input.text + ' in ' + context.appName + options.suffix, code: (clicked) => 'first:' + clicked.text },
        { title: 'Plain', icon: 'P' },
        () => 'bare',
      ],
    };
    """

    @Test func theActionsOfferedAreDescribedAsData() async {
        let harness = Harness()
        await harness.load(Self.offering)
        let reply = await harness.populate(options: ["suffix": "!"])
        #expect(reply == .populated(JSPopulation(actions: #"[{"title":"hello in Notes!","code":true},{"title":"Plain","icon":"P"},{"code":true}]"#)))
    }

    @Test func anOfferedActionRunsTheCodeKeptForItsAttempt() async {
        let harness = Harness()
        await harness.load(Self.offering)
        _ = await harness.populate(attempt: 7)
        #expect(await harness.invoke("populated.7.0") == .returned("first:clicked"))
        #expect(await harness.invoke("populated.7.2", id: 101) == .returned("bare"))
        #expect(await harness.invoke("populated.7.1", id: 102) == .threw("The action is no longer offered."))
        #expect(await harness.invoke("populated.8.0", id: 103) == .threw("The action is no longer offered."))
    }

    @Test func onlyTheLastFewAttemptsAreKept() async {
        let harness = Harness()
        await harness.load(Self.offering)
        for attempt in 1...5 { _ = await harness.populate(attempt: UInt64(attempt)) }
        #expect(await harness.invoke("populated.1.0") == .threw("The action is no longer offered."))
        #expect(await harness.invoke("populated.5.0", id: 101) == .returned("first:clicked"))
    }

    /// No timers, no `popclip` methods, no pasteboard, and no host call through a `popclip` an action
    /// left behind.
    @Test func aPopulationFunctionCannotActOrWait() async {
        let harness = Harness()
        await harness.load("""
        let saved = null;
        module.exports = {
          action: { title: 'Keep', code: () => { saved = popclip; return 'kept'; } },
          actions: () => {
            const tried = [];
            const attempt = (name, run) => {
              try { run(); tried.push(name + ': ok'); } catch (error) { tried.push(name + ': ' + error.message); }
            };
            attempt('timer', () => setTimeout(() => {}, 1));
            attempt('interval', () => setInterval(() => {}, 1));
            attempt('method', () => popclip.copyText('x'));
            attempt('pasteboard', () => pasteboard.text);
            attempt('saved', () => { saved.copyText('x').catch(() => {}); });
            return tried.map((title) => ({ title, code: () => title }));
          },
        };
        """)
        #expect(await harness.invoke("action", id: 1) == .returned("kept"))
        let titles = harness.titles(await harness.populate())
        #expect(titles.count == 5)
        #expect(titles[0] == "timer: A timer is not available in a population function.")
        #expect(titles[1] == "interval: A timer is not available in a population function.")
        #expect(titles[2].hasPrefix("method: ") && titles[2] != "method: ok")
        #expect(titles[3].hasPrefix("pasteboard: ") && titles[3].hasSuffix("is not available in a population function."))
        #expect(titles[4] == "saved: ok")
        // The saved `popclip`'s call was refused in the helper, and never reached the app.
        #expect(harness.calls.isEmpty)
        // Afterwards the world is as it was: an action still has its methods.
        #expect(await harness.invoke("action", id: 2) == .returned("kept"))
    }

    @Test func aPromiseIsNotActions() async {
        let harness = Harness()
        await harness.load("module.exports = { actions: async () => [{ title: 'Late', code: () => 1 }] };")
        #expect(await harness.populate() == .threw("A population function must return its actions, not a promise."))
    }

    @Test func oneActionOrNoneIsAList() async {
        let harness = Harness()
        await harness.load("module.exports = { actions: (input) => input.text === 'one' ? { title: 'One', code: () => 1 } : undefined };")
        #expect(harness.titles(await harness.populate(text: "one")) == ["One"])
        #expect(await harness.populate(attempt: 2, text: "none") == .populated(JSPopulation(actions: "[]")))
    }

    @Test func aThrowAndAMissingFunctionSayWhy() async {
        let harness = Harness()
        await harness.load("module.exports = { actions: () => { throw new Error('nope'); } };")
        #expect(await harness.populate() == .threw("nope"))
        let other = Harness()
        await other.load("module.exports = { actions: [] };")
        #expect(await other.populate() == .threw("The module has no population function."))
        #expect(await other.populate(generation: "2") == .notLoaded)
    }

    @Test func aPingIsAnsweredAtOnce() async {
        #expect(await Harness().ask(.ping) == .pong)
    }
}
