import Foundation
@testable import PappuCLI
import PappuCore
import PappuJSBridge
import PappuRuntime
import Testing

/// PRD §3.3 (implementation plan M3 week 7): the corpus functional pass, which says what share of the
/// corpus works when run, and never counts what it could not run as a pass.
@Suite struct CorpusFunctionalTests {
    typealias Verdict = CorpusFunctional.Verdict

    static func outcome(_ ending: DevelopmentRun.Ending, calls: [HeadlessHost.Call] = []) -> DevelopmentRun.Outcome {
        DevelopmentRun.Outcome(ending: ending, log: [], calls: calls)
    }

    static func judge(_ outcome: DevelopmentRun.Outcome, needsCredentials: Bool = false) -> CorpusFunctional.ActionResult {
        CorpusFunctional.judge(outcome, needsCredentials: needsCredentials, title: "Action")
    }

    // MARK: Judging a JavaScript run

    @Test func aValueOrAServedEffectIsAPass() {
        #expect(Self.judge(Self.outcome(.returned("X"))).verdict == .passed)
        let paste = HeadlessHost.Call(method: HostMethod.pasteText.rawValue, arguments: "{}", answer: .done)
        #expect(Self.judge(Self.outcome(.returned(nil), calls: [paste])).verdict == .passed)
    }

    @Test func readingTheClipboardAloneIsNotAnEffect() {
        let read = HeadlessHost.Call(method: HostMethod.pasteboardRead.rawValue, arguments: "{}", answer: .value("\"\""))
        let judged = Self.judge(Self.outcome(.returned(nil), calls: [read]))
        #expect(judged.verdict == .untested)
    }

    @Test func whatAHeadlessRunCannotHaveIsBlockedAndSaysWhy() {
        let network = HeadlessHost.Call(method: NetworkHostCalls.method, arguments: "{}", answer: .refused("no"))
        let script = HeadlessHost.Call(method: ScriptHostCalls.shell, arguments: "{}", answer: .refused("no"))
        let dictionary = HeadlessHost.Call(method: HostMethod.dictionaryDefine.rawValue, arguments: "{}", answer: .failed("none"))
        #expect(Self.judge(Self.outcome(.threw("offline"), calls: [network])).blocker == .network)
        #expect(Self.judge(Self.outcome(.threw("no"), calls: [script])).blocker == .script)
        #expect(Self.judge(Self.outcome(.threw("no"), calls: [dictionary])).blocker == .systemService)
        for judged in [
            Self.judge(Self.outcome(.threw("Not signed in"))),
            Self.judge(Self.outcome(.threw("API Key is required."))),
            Self.judge(Self.outcome(.threw("anything")), needsCredentials: true),
        ] {
            #expect(judged.verdict == .blocked)
            #expect(judged.blocker == .credentials)
        }
    }

    @Test func aThrowATimeoutOrNoStartIsAFailure() {
        #expect(Self.judge(Self.outcome(.threw("TypeError: x is undefined"))).verdict == .failed)
        #expect(Self.judge(Self.outcome(.timedOut)).verdict == .failed)
        #expect(Self.judge(Self.outcome(.notRun("broken"))).verdict == .failed)
    }

    // MARK: The rate

    @Test func aPackageIsAsGoodAsItsWorstAction() {
        #expect(Verdict.allCases == [.passed, .loadOnly, .untested, .blocked, .failed])
        let passed = CorpusFunctional.ActionResult(title: "A", kind: .url, verdict: .passed, detail: "")
        let blocked = CorpusFunctional.ActionResult(title: "B", kind: .service, verdict: .blocked, blocker: .service, detail: "")
        let package = CorpusFunctional.PackageResult(path: "P", actions: [passed, blocked])
        #expect(package.verdict == .blocked)
        #expect(package.blockers == [.service])
        #expect(CorpusFunctional.PackageResult(path: "Q", actions: []).verdict == .untested)
    }

    @Test func theDenominatorIsEveryPackage() {
        func package(_ verdict: Verdict) -> CorpusFunctional.PackageResult {
            CorpusFunctional.PackageResult(path: "p", actions: [.init(title: "t", kind: .javaScript, verdict: verdict, detail: "")])
        }
        let report = CorpusFunctional.Report(packages: [
            package(.passed), package(.passed), package(.blocked), package(.loadOnly), package(.untested), package(.failed),
            CorpusFunctional.PackageResult(path: "broken", actions: [], problem: "Does not load", problemVerdict: .failed),
            package(.passed),
        ])
        #expect(report.count(.passed) == 3)
        #expect(report.count(.failed) == 2)
        #expect(report.rate == 3.0 / 8.0)
        #expect(report.rateText == "3/8 functional (37.5%): 1 blocked, 1 load-only, 1 untested, 2 failed")
        #expect(CorpusFunctional.Report(packages: []).rate == 0)
    }

    // MARK: Packages, run

    static func check(_ files: [String: String]) async throws -> CorpusFunctional.PackageResult {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "corpus-functional-\(UUID().uuidString)")
            .appending(path: "Test.popclipext")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return await CorpusFunctional(timeout: .seconds(10)).check(root, path: "Test.popclipext")
    }

    @Test func aURLActionPassesWhenItMakesAURL() async throws {
        let result = try await Self.check([
            "Config.json": #"{"name":"T","actions":[{"title":"Search","url":"https://example.com/?q=***"}]}"#,
        ])
        #expect(result.verdict == .passed)
    }

    @Test func aModuleActionPassesWhenItReturnsAValue() async throws {
        let result = try await Self.check([
            "Config.js": """
            // #popclip
            // name: T
            exports.actions = [{ title: "Upper", code: (input) => input.text.toUpperCase() }];
            """,
        ])
        #expect(result.verdict == .passed, "\(result.detail)")
        #expect(result.actions.map(\.kind) == [.javaScript])
    }

    @Test func aModuleActionThatThrowsFails() async throws {
        let result = try await Self.check([
            "Config.js": """
            // #popclip
            // name: T
            exports.actions = [{ title: "Broken", code: () => { throw new Error("nope"); } }];
            """,
        ])
        #expect(result.verdict == .failed)
        #expect(result.detail.contains("nope"))
    }

    @Test func anAppleScriptIsLoadOnlyAndAServiceIsBlocked() async throws {
        let script = try await Self.check([
            "Config.json": #"{"name":"T","actions":[{"title":"Say","applescript":"say \"{popclip text}\""}]}"#,
        ])
        #expect(script.verdict == .loadOnly)
        let service = try await Self.check([
            "Config.json": #"{"name":"T","actions":[{"title":"Svc","service name":"Make New Sticky Note"}]}"#,
        ])
        #expect(service.verdict == .blocked)
        #expect(service.blockers == [.service])
    }

    @Test func aPackageThatDoesNotLoadFails() async throws {
        let result = try await Self.check(["Config.json": #"{"name":"T","actions":"nope"}"#])
        #expect(result.verdict == .failed)
        #expect(result.problem?.hasPrefix("Does not load") == true)
    }
}
