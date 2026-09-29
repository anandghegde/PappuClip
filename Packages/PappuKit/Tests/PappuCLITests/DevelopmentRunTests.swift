import Foundation
import PappuCLI
import PappuCore
import PappuJSBridge
import Testing

/// DEV-2: `pappuclip run`, driven as the executable drives it, against packages written to a folder.
@Suite struct DevelopmentRunTests {
    /// A package folder, `Test.popclipext`, holding `files`, and the URL of one of them.
    static func package(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pappuclip-run-\(UUID().uuidString)")
            .appending(path: "Test.popclipext")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func run(_ files: [String: String], file: String, _ configure: (inout DevelopmentRun.Request) -> Void = { _ in }) async throws -> DevelopmentRun.Outcome {
        let root = try package(files)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var request = DevelopmentRun.Request(file: root.appending(path: file), timeout: .seconds(10))
        configure(&request)
        return await DevelopmentRun().run(request)
    }

    // MARK: Exit status

    @Test func aModulesTestFunctionThatReturnsExitsZero() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = (input) => { print('ran'); return input.text.toUpperCase(); };"],
            file: "Config.js"
        ) { $0.text = "abc" }
        #expect(outcome.ending == .returned("ABC"))
        #expect(outcome.log == ["ran"])
        #expect(outcome.exitCode == 0)
    }

    @Test func aFunctionThatThrowsExitsOne() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = () => { throw new Error('expected 2, got 3'); };"],
            file: "Config.js"
        )
        guard case .threw(let why) = outcome.ending else { Issue.record("\(outcome.ending)"); return }
        #expect(why.contains("expected 2, got 3"))
        #expect(outcome.exitCode == 1)
    }

    @Test func aRejectedPromiseExitsOne() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = async () => { await null; throw new Error('late'); };"],
            file: "Config.js"
        )
        #expect(outcome.exitCode == 1)
    }

    @Test func aNamedFunctionIsCalledInsteadOfTest() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = () => { throw new Error('wrong one'); }; exports.other = () => 'other';"],
            file: "Config.js"
        ) { $0.function = "other" }
        #expect(outcome.ending == .returned("other"))
    }

    @Test func aMissingFunctionIsNotRunAndExitsOne() async throws {
        let outcome = try await Self.run(["Config.js": "exports.actions = [];"], file: "Config.js")
        #expect(outcome.ending == .notRun("The module exports no function test."))
        #expect(outcome.exitCode == 1)
    }

    @Test func aFileThatWillNotCompileExitsOne() async throws {
        let outcome = try await Self.run(["Config.js": "exports.test = () => {"], file: "Config.js")
        #expect(outcome.exitCode == 1)
    }

    @Test func aMissingFileExitsOne() async throws {
        let outcome = await DevelopmentRun().run(DevelopmentRun.Request(file: URL(filePath: "/nonexistent/Config.js")))
        guard case .notRun = outcome.ending else { Issue.record("\(outcome.ending)"); return }
        #expect(outcome.exitCode == 1)
    }

    @Test func aRunStillGoingAtTheTimeoutExitsOne() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = () => new Promise(() => {});"],
            file: "Config.js"
        ) { $0.timeout = .milliseconds(200) }
        #expect(outcome.ending == .timedOut)
        #expect(outcome.exitCode == 1)
    }

    // MARK: What runs

    @Test func aTestFunctionBesideADefaultExportIsFound() async throws {
        // `export default` is the extension object, and `test` is a named export beside it.
        let outcome = try await Self.run(
            ["Config.js": "export default { actions: [{ title: 'A', code: () => 'a' }] };\nexport function test() { return 'tested'; }"],
            file: "Config.js"
        )
        #expect(outcome.ending == .returned("tested"))
    }

    @Test func anActionPathStillMeansTheExtensionObjects() async throws {
        let outcome = try await Self.run(
            ["Config.js": "export default { actions: [{ title: 'A', code: () => 'from the object' }] };\nexport function test() { return 'named'; }"],
            file: "Config.js"
        ) { $0.function = "actions.0" }
        #expect(outcome.ending == .returned("from the object"))
    }

    @Test func aFileWithNoExportsRunsAsAnActionScript() async throws {
        let outcome = try await Self.run(["action.js": "return popclip.input.text + '!';"], file: "action.js") { $0.text = "hi" }
        #expect(outcome.ending == .returned("hi!"))
    }

    @Test func aModuleCanBeForcedToRunAsAScript() async throws {
        let outcome = try await Self.run(["action.js": "exports.x = 1; return 'script';"], file: "action.js") { $0.asScript = true }
        #expect(outcome.ending == .returned("script"))
    }

    @Test func thePackagesOtherFilesCanBeRequired() async throws {
        let outcome = try await Self.run(
            ["Config.js": "const lib = require('./lib/words.js'); exports.test = () => lib.word;", "lib/words.js": "exports.word = 'from lib';"],
            file: "Config.js"
        )
        #expect(outcome.ending == .returned("from lib"))
    }

    @Test func typeScriptIsTranspiled() async throws {
        let outcome = try await Self.run(
            ["Config.ts": "export function test(input: { text: string }): string { const n: number = input.text.length; return String(n); }"],
            file: "Config.ts"
        ) { $0.text = "four" }
        #expect(outcome.ending == .returned("4"))
    }

    @Test func optionsReachTheFunction() async throws {
        let outcome = try await Self.run(["Config.js": "exports.test = (input, options) => options.greeting;"], file: "Config.js") {
            $0.options = ["greeting": "hej"]
        }
        #expect(outcome.ending == .returned("hej"))
    }

    @Test func modulesAndScriptsAreToldApart() {
        #expect(DevelopmentRun.looksLikeModule("export default {}"))
        #expect(DevelopmentRun.looksLikeModule("import x from 'y';\n"))
        #expect(DevelopmentRun.looksLikeModule("module.exports = {}"))
        #expect(DevelopmentRun.looksLikeModule("exports.test = 1"))
        #expect(DevelopmentRun.looksLikeModule("defineExtension({})"))
        #expect(!DevelopmentRun.looksLikeModule("return popclip.input.text;"))
        #expect(!DevelopmentRun.looksLikeModule("// exporting nothing\npopclip.pasteText('x');"))
        #expect(!DevelopmentRun.looksLikeModule("const kinds = { exports: typeof exports, module: typeof module };\nreturn 'ok';"))
    }

    @Test func thePackageIsTheNearestPackageFolder() {
        let file = URL(filePath: "/tmp/a/Thing.popclipext/src/lib/x.js")
        #expect(DevelopmentRun.packageRoot(of: file).path == "/tmp/a/Thing.popclipext")
        #expect(DevelopmentRun.packageRoot(of: URL(filePath: "/tmp/b/x.js")).path == "/tmp/b")
    }

    // MARK: Host calls: the app's refusals, no effects

    @Test func hostCallsAreRecordedAndNotPerformed() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = async () => { await popclip.pasteText('pasted'); popclip.openUrl('https://example.com'); popclip.showSuccess(); };"],
            file: "Config.js"
        )
        #expect(outcome.ending == .returned(nil))
        #expect(outcome.calls.map(\.method) == ["pasteText", "openUrl", "showSuccess"])
        #expect(outcome.calls.allSatisfy { $0.wasServed })
    }

    @Test func aGatedCallIsRefusedInTheAppsWordsWithoutItsGrant() async throws {
        let script = ["Config.js": "exports.test = async () => { await popclip.pressKey('cmd b'); };"]
        let refused = try await Self.run(script, file: "Config.js")
        #expect(refused.exitCode == 1)
        #expect(refused.calls.first?.answer == .refused("pressKeys needs the synthetic-input permission, which this extension does not have."))

        let granted = try await Self.run(script, file: "Config.js") { $0.gates = [.syntheticInput] }
        #expect(granted.exitCode == 0)
        #expect(granted.calls.first?.method == "pressKeys")
        #expect(granted.calls.first?.answer == .done)
    }

    @Test func noRequestIsSentEvenWithTheNetworkGrant() async throws {
        let script = ["Config.js": "exports.test = async () => { const axios = require('axios'); await axios.get('https://example.com'); };"]
        let refused = try await Self.run(script, file: "Config.js")
        #expect(refused.exitCode == 1)
        #expect(refused.calls.first?.answer == .refused("httpRequest needs the network permission, which this extension does not have."))

        let granted = try await Self.run(script, file: "Config.js") { $0.gates = [.network] }
        #expect(granted.exitCode == 1)
        #expect(granted.calls.first?.answer == .refused("httpRequest is not available in a headless run."))
    }

    @Test func theHeadlessClipboardKeepsWhatWasCopied() async throws {
        let outcome = try await Self.run(
            ["Config.js": "exports.test = async () => { popclip.copyText('kept'); return pasteboard.text; };"],
            file: "Config.js"
        ) { $0.clipboard = "before" }
        #expect(outcome.ending == .returned("kept"))
    }

    @Test func anUnknownMethodIsRefused() {
        let host = HeadlessHost()
        let answer = host.answer(JSHostCall(invocation: 1, extensionName: "x", method: "launchMissiles"))
        #expect(answer == .refused("There is no host method launchMissiles."))
        #expect(host.recorded.count == 1)
    }

    @Test func scriptsAreNeverRunHeadless() {
        let host = HeadlessHost(gates: [.script])
        #expect(host.answer(JSHostCall(invocation: 1, extensionName: "x", method: "runShellScript", arguments: #"{"script":"rm -rf /"}"#))
            == .refused("runShellScript is not available in a headless run."))
        #expect(HeadlessHost().answer(JSHostCall(invocation: 1, extensionName: "x", method: "runShellScript"))
            == .refused("runShellScript needs the script permission, which this extension does not have."))
    }

    // MARK: What it prints

    @Test func theReportEndsWithTheVerdict() {
        let passed = DevelopmentReport.lines(for: DevelopmentRun.Outcome(
            ending: .returned("value"),
            log: ["a line"],
            calls: [HeadlessHost.Call(method: "copyText", arguments: #"{"text":"x"}"#, answer: .done)]
        ))
        #expect(passed.map(\.text) == ["a line", #"host: copyText {"text":"x"} -> done"#, "value", "passed"])
        #expect(passed.map(\.isError) == [false, true, false, true])

        let quiet = DevelopmentReport.lines(for: DevelopmentRun.Outcome(ending: .threw("Error: no"), log: [], calls: [
            HeadlessHost.Call(method: "copyText", arguments: "{}", answer: .done),
        ]), showingCalls: false)
        #expect(quiet.map(\.text) == ["failed: Error: no"])
    }

    // MARK: §17: the API conformance suite, run by `pappuclip run`

    static let conformance = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/conformance")

    @Test func theAPISectionOfTheConformanceSuitePasses() async throws {
        let suite = Self.conformance.appending(path: "api/suite.js")
        try #require(FileManager.default.fileExists(atPath: suite.path), "Tests/conformance/api/suite.js is missing")
        let outcome = await DevelopmentRun().run(DevelopmentRun.Request(file: suite, timeout: .seconds(60)))
        #expect(outcome.ending == .returned("ok"))
        let methods = Set(outcome.calls.map(\.method))
        #expect(methods.isSuperset(of: ["pasteText", "copyText", "pasteboard.read", "pasteboard.write", "performCommand", "openUrl"]))
        let refused = outcome.calls.filter { !$0.wasServed }.map(\.method)
        #expect(refused == ["pressKeys", "performService", "runShellScript", "httpRequest"])
    }

    @Test func theConformanceSuitePassesUnderPappuclipRun() async throws {
        let suite = Self.conformance.appending(path: "environment/suite.js")
        try #require(FileManager.default.fileExists(atPath: suite.path), "Tests/conformance/environment/suite.js is missing")
        let outcome = await DevelopmentRun().run(DevelopmentRun.Request(file: suite, text: "hello", timeout: .seconds(60)))
        #expect(outcome.ending == .returned("ok"))
        #expect(outcome.exitCode == 0)
    }
}
