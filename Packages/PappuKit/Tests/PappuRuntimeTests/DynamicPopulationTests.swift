import Foundation
import PappuAnalysis
import PappuCore
@testable import PappuExtensions
import PappuJSBridge
@testable import PappuRuntime
import Synchronization
import Testing

/// JS-16, JS-19: the helper is kept warm for the extensions that populate, and a cold one is never
/// waited for (architecture §10.6).
@Suite struct WarmHelperTests {
    static let config = """
    module.exports = { actions: (input) => [{ title: 'Say ' + input.text, code: (clicked) => 'said ' + clicked.text }] };
    """

    struct Setup {
        let base: JSHostClientTests.Setup
        var client: JSHostClient { base.client }
        var transport: InProcessJSHost { base.transport }

        init(limit: Duration = .seconds(5)) throws {
            base = try JSHostClientTests.Setup(files: ["Config.js": WarmHelperTests.config])
        }

        var module: WarmModule {
            WarmModule(owner: "ext-a", generation: "1", extensionName: "Extension A", directory: base.package)
        }

        func request(_ attempt: UInt64 = 1) -> PopulationRequest {
            PopulationRequest(
                owner: "ext-a",
                generation: "1",
                extensionName: "Extension A",
                module: ModuleSource(source: .file("Config.js"), isTypeScript: false),
                attempt: AttemptID(rawValue: attempt),
                input: JSInput(text: "hi", matchedText: "hi")
            )
        }

        /// Until the warm-up has loaded the extension, or a second has gone.
        func warm() async -> Bool {
            for _ in 0..<500 {
                if client.isWarm("ext-a", generation: "1"), !client.isWarming { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
    }

    @Test func aColdHelperIsNotWaitedForButIsWarmedForNextTime() async throws {
        let setup = try Setup()
        // Not kept warm: nothing to warm, and population says so at once.
        #expect(await setup.client.populate(setup.request(), within: .milliseconds(15)) == .cold)
        #expect(setup.transport.opened == 0)

        setup.client.keepWarm([setup.module])
        #expect(await setup.warm())
        #expect(setup.transport.opened == 1)
        #expect(await setup.client.populate(setup.request(), within: .seconds(1)) == .offered(#"[{"title":"Say hi","code":true}]"#))
    }

    @Test func keepingNothingWarmStartsNothing() async throws {
        let setup = try Setup()
        setup.client.keepWarm([])
        setup.client.ping()
        #expect(!setup.client.isWarming)
        #expect(setup.transport.opened == 0)
    }

    /// JS-19: whatever took it down, the helper is re-created and the extensions loaded into it again.
    @Test func aCrashedHelperIsRecreatedAndLoadedAgain() async throws {
        let setup = try Setup()
        setup.client.keepWarm([setup.module])
        #expect(await setup.warm())
        setup.transport.current?.crash()
        // The client learns of it at its next request, or at a ping.
        setup.client.ping()
        for _ in 0..<500 where setup.transport.opened < 2 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(await setup.warm())
        #expect(setup.transport.opened == 2)
        #expect(setup.transport.current?.loads == 1)
        #expect(await setup.client.populate(setup.request(2), within: .seconds(1)) == .offered(#"[{"title":"Say hi","code":true}]"#))
    }

    /// A crash seen by a population answers that one `failed`, and warms the next helper.
    @Test func aCrashDuringPopulationWarmsTheNextHelper() async throws {
        let setup = try Setup()
        setup.client.keepWarm([setup.module])
        #expect(await setup.warm())
        setup.transport.current?.crash()
        #expect(await setup.client.populate(setup.request(), within: .seconds(1)) == .failed("The JavaScript helper stopped."))
        for _ in 0..<500 where setup.transport.opened < 2 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(await setup.warm())
    }

    @Test func noTimeIsLate() async throws {
        let setup = try Setup()
        setup.client.keepWarm([setup.module])
        #expect(await setup.warm())
        #expect(await setup.client.populate(setup.request(), within: .zero) == .late)
    }

    @Test func aPopulationThatThrowsIsInTheConsole() async throws {
        let setup = try JSHostClientTests.Setup(files: ["Config.js": "module.exports = { actions: () => { throw new Error('no') } };"])
        setup.client.keepWarm([WarmModule(owner: "ext-a", generation: "1", extensionName: "Extension A", directory: setup.package)])
        for _ in 0..<500 where !setup.client.isWarm("ext-a", generation: "1") { try? await Task.sleep(for: .milliseconds(2)) }
        let request = PopulationRequest(
            owner: "ext-a", generation: "1", extensionName: "Extension A",
            module: ModuleSource(source: .file("Config.js"), isTypeScript: false),
            attempt: AttemptID(rawValue: 1), input: JSInput(text: "hi", matchedText: "hi")
        )
        #expect(await setup.client.populate(request, within: .seconds(1)) == .failed("no"))
        #expect(setup.kinds("Extension A").contains(.threw))
    }
}

/// JS-13, JS-16: population inside the deadline, resolved as every other action is.
@Suite struct DynamicPopulatorTests {
    /// Answers as told, and counts what it was asked.
    final class Helper: ModulePopulating {
        let answer: @Sendable (PopulationRequest) -> PopulationAnswer
        let asked = Mutex<[PopulationRequest]>([])
        let limits = Mutex<[Duration]>([])

        init(_ answer: @escaping @Sendable (PopulationRequest) -> PopulationAnswer) {
            self.answer = answer
        }

        func populate(_ request: PopulationRequest, within limit: Duration) async -> PopulationAnswer {
            asked.withLock { $0.append(request) }
            limits.withLock { $0.append(limit) }
            return answer(request)
        }
    }

    static let owner = LocalIdentity().description

    static func source() throws -> DynamicPopulator.Source {
        let snippet = "// #popclip\n// name: Dynamo\n// identifier: com.example.dynamo\n// entitlements: [dynamic]\ndefineExtension({})"
        let loaded = try ExtensionLoader.loadSnippet(snippet)
        return DynamicPopulator.Source(
            entry: ActionCatalog.Entry(manifest: loaded.manifest, origin: .installed, owner: owner),
            owner: owner,
            generation: "g1",
            module: ModuleSource(source: .inline("defineExtension({})"), isTypeScript: false)
        )
    }

    static func populator(_ helper: Helper, sources: [DynamicPopulator.Source]) -> DynamicPopulator {
        DynamicPopulator(
            helper: helper,
            sources: { sources },
            resolver: ActionResolver { .approving($0, gates: Set(GatedCapability.allCases), digest: "g1") },
            options: { _ in ["unit": "cm"] }
        )
    }

    static func deadline(remaining: Duration = .milliseconds(30), pastTarget: Bool = false) -> DynamicPopulator.Deadline {
        DynamicPopulator.Deadline(remaining: { remaining }, isPastTarget: { pastTarget }, perFunction: .milliseconds(15))
    }

    static let selection = AnalyzedSelection(text: "hello", detections: [])
    static let context = SelectionContext(app: AppIdentity(pid: 1, bundleID: "com.example.Notes", name: "Notes"))

    func run(_ helper: Helper, deadline: DynamicPopulator.Deadline, sources: [DynamicPopulator.Source]? = nil) async throws -> DynamicPopulator.Result {
        let sources = try sources ?? [Self.source()]
        return await Self.populator(helper, sources: sources).populate(
            attempt: AttemptID(rawValue: 9),
            deadline: deadline,
            selection: Self.selection,
            context: Self.context
        )
    }

    @Test func offeredActionsAreResolvedAndRunTheirAttemptsCode() async throws {
        let helper = Helper { _ in .offered(#"[{"title":"One","code":true},{"title":"Two","identifier":"two","code":true},{"title":"Needs a URL","code":true,"requirements":["url"]}]"#) }
        let result = try await run(helper, deadline: Self.deadline())
        #expect(result.actions.map { $0.action.manifest.title?.english } == ["One", "Two"])
        #expect(result.actions.map(\.key.action) == ["populated.0", "populated.two"])
        if case .javaScript(let script) = result.actions.first?.action.manifest.executor {
            #expect(script.export == "populated.9.0")
        } else {
            Issue.record("not a JavaScript action")
        }
        #expect(result.record?.entries == [PopulationRecord.Entry(owner: Self.owner, outcome: .offered(2))])
        #expect(result.record?.skipped == nil)

        let request = try #require(helper.asked.withLock { $0.first })
        #expect(request.attempt == AttemptID(rawValue: 9))
        #expect(request.input.text == "hello")
        #expect(request.context.appName == "Notes")
        #expect(request.options == ["unit": "cm"])
        #expect(helper.limits.withLock { $0 } == [.milliseconds(15)])
    }

    @Test func eachFunctionIsGivenNoMoreThanWhatIsLeft() async throws {
        let helper = Helper { _ in .offered("[]") }
        _ = try await run(helper, deadline: Self.deadline(remaining: .milliseconds(4)))
        #expect(helper.limits.withLock { $0 } == [.milliseconds(4)])
    }

    /// The done-when: population never delays a bar past the target budget.
    @Test func pastTheTargetBudgetNothingIsAsked() async throws {
        let helper = Helper { _ in .offered("[]") }
        let result = try await run(helper, deadline: Self.deadline(pastTarget: true))
        #expect(helper.asked.withLock { $0.isEmpty })
        #expect(result.actions.isEmpty)
        #expect(result.record?.skipped == .pastTargetBudget)
    }

    @Test func withTheStageSpentNothingIsAsked() async throws {
        let helper = Helper { _ in .offered("[]") }
        let result = try await run(helper, deadline: Self.deadline(remaining: .zero))
        #expect(helper.asked.withLock { $0.isEmpty })
        #expect(result.record?.skipped == .noTimeLeft)
    }

    /// The done-when: a cold helper skips population, and the trace says so.
    @Test func aColdHelperIsRecorded() async throws {
        let result = try await run(Helper { _ in .cold }, deadline: Self.deadline())
        #expect(result.actions.isEmpty)
        #expect(result.record?.sawColdHelper == true)
        #expect(result.record?.entries.map(\.outcome) == [.cold])
    }

    @Test func lateFailedAndSuspendedAreRecordedAndOfferNothing() async throws {
        for (answer, outcome) in [(PopulationAnswer.late, PopulationRecord.Outcome.late), (.failed("x"), .failed), (.suspended, .suspended)] {
            let result = try await run(Helper { _ in answer }, deadline: Self.deadline())
            #expect(result.actions.isEmpty)
            #expect(result.record?.entries.map(\.outcome) == [outcome])
        }
    }

    @Test func noDynamicExtensionIsNoRecord() async throws {
        let result = try await run(Helper { _ in .cold }, deadline: Self.deadline(), sources: [])
        #expect(result.record == nil)
    }

    @Test func anActionTheApprovalDoesNotCoverIsRefused() async throws {
        let helper = Helper { _ in .offered(#"[{"title":"One","code":true}]"#) }
        let populator = DynamicPopulator(helper: helper, sources: { [try! Self.source()] }, resolver: ActionResolver { _ in nil })
        let result = await populator.populate(attempt: AttemptID(rawValue: 1), deadline: Self.deadline(), selection: Self.selection, context: Self.context)
        #expect(result.actions.isEmpty)
    }

    @Test func thePopulationLogKeepsARecordForItsAttempt() {
        let log = PopulationLog()
        log.record(PopulationRecord(skipped: .noTimeLeft), for: AttemptID(rawValue: 1))
        #expect(log.take(for: AttemptID(rawValue: 2)) == nil)
        #expect(log.take(for: AttemptID(rawValue: 1))?.skipped == .noTimeLeft)
        #expect(log.take(for: AttemptID(rawValue: 1)) == nil)
    }
}
