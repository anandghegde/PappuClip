import Foundation
import PappuJSBridge
@testable import PappuJSHost
import Synchronization
import Testing

/// DEV-1: a development folder's world is inspectable and logs what it does, when asked; no other
/// world is either, and the log never carries what the extension read or sent.
@Suite struct DevelopmentDebugTests {
    private static func prepared(_ debug: JSDebug?) -> ExtensionVM {
        let vm = ExtensionVM(load: JSLoad(extensionName: "a", generation: "1", files: [:], debug: debug), qos: .utility) { _ in }
        vm.queue.sync { #expect(vm.prepare() == nil) }
        return vm
    }

    @Test func onlyAWorldThatAsksIsInspectable() {
        let plain = Self.prepared(nil)
        let quiet = Self.prepared(JSDebug(verbose: true))
        let inspectable = Self.prepared(JSDebug(inspectable: true))
        #expect(plain.queue.sync { plain.isInspectable } == false)
        #expect(quiet.queue.sync { quiet.isInspectable } == false)
        #expect(inspectable.queue.sync { inspectable.isInspectable } == true)
    }

    @Test func aLoadFromAnOlderAppHasNoDebugging() throws {
        let json = #"{"extensionName":"a","generation":"1","files":{}}"#
        let load = try JSONDecoder().decode(JSLoad.self, from: Data(json.utf8))
        #expect(load.debug == nil)
        let round = try JSONDecoder().decode(JSLoad.self, from: JSONEncoder().encode(
            JSLoad(extensionName: "a", generation: "1", files: [:], debug: JSDebug(inspectable: true, verbose: true))
        ))
        #expect(round.debug == JSDebug(inspectable: true, verbose: true))
    }

    final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    final class App: Sendable {
        let lines = Lines()
        let host: JSHost

        init() {
            let lines = lines
            host = JSHost(qos: .utility, call: { call, reply in
                reply(call.method == "pasteboard.read" ? .value(#"{"public.utf8-plain-text":"secret clip"}"#) : .done)
            }) { _, line in lines.append(line) }
        }

        func ask(_ request: JSHostRequest) async -> JSHostReply {
            await withCheckedContinuation { continuation in
                host.handle(request) { continuation.resume(returning: $0) }
            }
        }
    }

    private func run(verbose: Bool) async -> [String] {
        let app = App()
        let debug = verbose ? JSDebug(verbose: true) : nil
        #expect(await app.ask(.load(JSLoad(extensionName: "a", generation: "0123456789abcdef", files: [:], debug: debug))) == .loaded)
        let script = "await popclip.pasteText('hidden text'); const t = pasteboard.text; print('printed'); return t"
        let reply = await app.ask(.invoke(JSInvoke(
            invocation: 9, extensionName: "a", generation: "0123456789abcdef", entry: .inline(script),
            input: JSInput(text: "selected words", matchedText: "selected words")
        )))
        #expect(reply == .returned("secret clip"))
        return app.lines.all
    }

    @Test func verboseLinesNameWhatHappenedAndNothingItCarried() async {
        let lines = await run(verbose: true)
        let development = lines.filter { $0.hasPrefix(ExtensionVM.verbosePrefix) }
        #expect(development.contains { $0.contains("loaded 0 files, generation 0123456789ab") })
        #expect(development.contains { $0.contains("invocation 9 started") })
        #expect(development.contains { $0.contains("calls pasteText") })
        #expect(development.contains { $0.contains("pasteText done") })
        #expect(development.contains { $0.contains("invocation 9 returned") })
        #expect(lines.contains("printed"))
        for line in development {
            #expect(!line.contains("hidden text"))
            #expect(!line.contains("secret clip"))
            #expect(!line.contains("selected words"))
        }
    }

    @Test func withoutDevelopmentOnlyTheScriptPrints() async {
        #expect(await run(verbose: false) == ["printed"])
    }
}
