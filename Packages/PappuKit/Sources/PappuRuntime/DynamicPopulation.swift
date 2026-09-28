import Foundation
import PappuAnalysis
import PappuCore
import PappuJSBridge

/// JS-13: one attempt's population of one module extension, for the helper.
public struct PopulationRequest: Sendable, Equatable {
    /// The installed extension, as its local identity's text: which world it runs in.
    public var owner: String
    /// The approved bytes' digest. Only a world loaded from these bytes is asked.
    public var generation: String
    /// For the Debug Console.
    public var extensionName: String
    public var module: ModuleSource
    public var attempt: AttemptID
    public var input: JSInput
    public var context: JSSelectionContext
    /// The option values without the secret ones (architecture §10.6).
    public var options: [String: String]
    public var booleanOptions: [String]

    public init(
        owner: String,
        generation: String,
        extensionName: String,
        module: ModuleSource,
        attempt: AttemptID,
        input: JSInput,
        context: JSSelectionContext = JSSelectionContext(),
        options: [String: String] = [:],
        booleanOptions: [String] = []
    ) {
        self.owner = owner
        self.generation = generation
        self.extensionName = extensionName
        self.module = module
        self.attempt = attempt
        self.input = input
        self.context = context
        self.options = options
        self.booleanOptions = booleanOptions
    }
}

/// How one population ended, as the helper's client saw it.
public enum PopulationAnswer: Sendable, Equatable {
    /// The actions, as `JSPopulation.actions`.
    case offered(String)
    /// Not asked: the helper is not running, or has not loaded this extension's world.
    case cold
    /// Asked, and not answered within the limit. The answer is dropped when it comes.
    case late
    case failed(String)
    case suspended
}

/// Runs population functions in the helper (architecture §10.6).
public protocol ModulePopulating: Sendable {
    /// Never waits for the helper to start or load: a helper that is not ready is `cold`, at once.
    func populate(_ request: PopulationRequest, within limit: Duration) async -> PopulationAnswer
}

/// One extension the helper should hold loaded, so that its population is never the one that waits
/// for a launch (JS-16).
public struct WarmModule: Sendable, Equatable {
    public var owner: String
    public var generation: String
    public var extensionName: String
    public var directory: URL

    public init(owner: String, generation: String, extensionName: String, directory: URL) {
        self.owner = owner
        self.generation = generation
        self.extensionName = extensionName
        self.directory = directory
    }
}

/// JS-16, JS-19: keeps the helper running and loaded for the extensions that populate.
public protocol HelperWarming: Sendable {
    /// These, and only these, are kept loaded. An empty list starts nothing.
    func keepWarm(_ modules: [WarmModule])
    /// A mouse-down: the helper is woken, and started and loaded if it went away. Never waits.
    func ping()
}

/// JS-13, JS-16: asks every dynamic extension for its actions, inside the population stage's deadline,
/// and resolves what they offered as the static actions were resolved.
///
/// **The deadline.** Each extension is given what is left of the population stage, and no more than
/// `BudgetTable.populationPerFunction`; they are asked together, so the stage costs its longest one.
/// Past the target budget nothing is asked at all (PRD §11.1: a late bar is a static bar), and a
/// helper that is cold is never waited for: the extension is skipped, the helper warmed for the next
/// attempt, and the skip is in the attempt's record.
///
/// **The same rules as every other action.** What a population function offers is read by
/// `ManifestBuilder.populatedActions` with a module action's rules, catalogued with its extension's
/// manifest, so it has that extension's gates, and resolved by the same resolver against the same facts:
/// an action the approval does not cover, or whose requirements this selection does not meet, is
/// refused here as it would be anywhere.
public struct DynamicPopulator: Sendable {
    /// One extension that populates.
    public struct Source: Sendable, Equatable {
        /// Its manifest, folder, owner and scan, as the catalog has them.
        public var entry: ActionCatalog.Entry
        public var owner: String
        public var generation: String
        public var module: ModuleSource

        public init(entry: ActionCatalog.Entry, owner: String, generation: String, module: ModuleSource) {
            self.entry = entry
            self.owner = owner
            self.generation = generation
            self.module = module
        }
    }

    /// When population must be over.
    public struct Deadline: Sendable {
        /// Time left in the population stage.
        public var remaining: @Sendable () -> Duration
        /// The target budget is spent.
        public var isPastTarget: @Sendable () -> Bool
        public var perFunction: Duration

        public init(
            remaining: @escaping @Sendable () -> Duration,
            isPastTarget: @escaping @Sendable () -> Bool,
            perFunction: Duration
        ) {
            self.remaining = remaining
            self.isPastTarget = isPastTarget
            self.perFunction = perFunction
        }

        /// From the attempt's own clock, on the path its selection was read by.
        public static func of(_ clock: AttemptClock, on path: DetectionPath) -> Deadline {
            Deadline(
                remaining: { clock.remaining(in: .stage(.population), on: path) },
                isPastTarget: { clock.isPastTargetBudget(on: path) },
                perFunction: clock.budgets.populationPerFunction
            )
        }

        /// For an attempt with no clock: the stage's own budget, from now.
        public static func stage(_ budgets: BudgetTable = .initial, on path: DetectionPath = .accessibility) -> Deadline {
            let start = ContinuousClock.now
            let stage = budgets.budget(for: .population, on: path)
            return Deadline(
                remaining: { max(.zero, stage - start.duration(to: .now)) },
                isPastTarget: { false },
                perFunction: budgets.populationPerFunction
            )
        }
    }

    public struct Result: Sendable {
        public var actions: [ActionResolver.ResolvedAction]
        /// Nil when there was nothing to populate.
        public var record: PopulationRecord?
    }

    private let helper: any ModulePopulating
    private let sources: @Sendable () -> [Source]
    private let resolver: ActionResolver
    private let options: @Sendable (Source) -> [String: String]

    /// - Parameters:
    ///   - sources: The dynamic extensions, read at each attempt.
    ///   - options: An extension's option values without its secrets.
    public init(
        helper: any ModulePopulating,
        sources: @escaping @Sendable () -> [Source],
        resolver: ActionResolver = ActionResolver(),
        options: @escaping @Sendable (Source) -> [String: String] = { _ in [:] }
    ) {
        self.helper = helper
        self.sources = sources
        self.resolver = resolver
        self.options = options
    }

    public func populate(
        attempt: AttemptID,
        deadline: Deadline,
        selection: AnalyzedSelection,
        context: SelectionContext,
        conditions: BuiltinConditions = .none,
        matchingOptions: [String: [String: String]] = [:]
    ) async -> Result {
        let sources = sources()
        guard !sources.isEmpty else { return Result(actions: [], record: nil) }
        let started = ContinuousClock.now
        if deadline.isPastTarget() {
            return Result(actions: [], record: PopulationRecord(skipped: .pastTargetBudget))
        }
        let limit = min(deadline.perFunction, deadline.remaining())
        guard limit > .zero else { return Result(actions: [], record: PopulationRecord(skipped: .noTimeLeft)) }

        let input = Self.input(selection)
        let jsContext = Self.context(context)
        let answers = await withTaskGroup(of: (Int, PopulationAnswer).self) { group in
            for (index, source) in sources.enumerated() {
                let request = PopulationRequest(
                    owner: source.owner,
                    generation: source.generation,
                    extensionName: source.entry.manifest.name.english,
                    module: source.module,
                    attempt: attempt,
                    input: input,
                    context: jsContext,
                    options: options(source),
                    booleanOptions: source.entry.manifest.options.filter { $0.kind == .boolean }.compactMap(\.identifier).sorted()
                )
                group.addTask { [helper] in (index, await helper.populate(request, within: limit)) }
            }
            var answers: [Int: PopulationAnswer] = [:]
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }

        let facts = MatchingFacts(selection: selection, context: context)
        var actions: [ActionResolver.ResolvedAction] = []
        var entries: [PopulationRecord.Entry] = []
        for (index, source) in sources.enumerated() {
            let outcome: PopulationRecord.Outcome
            switch answers[index] ?? .late {
            case .offered(let json):
                let resolved = resolve(json, from: source, attempt: attempt, facts: facts, conditions: conditions, options: matchingOptions)
                actions += resolved
                outcome = .offered(resolved.count)
            case .cold: outcome = .cold
            case .late: outcome = .late
            case .failed: outcome = .failed
            case .suspended: outcome = .suspended
            }
            entries.append(PopulationRecord.Entry(owner: source.owner, outcome: outcome))
        }
        return Result(actions: actions, record: PopulationRecord(entries: entries, elapsed: started.duration(to: .now)))
    }

    private func resolve(
        _ json: String,
        from source: Source,
        attempt: AttemptID,
        facts: MatchingFacts,
        conditions: BuiltinConditions,
        options: [String: [String: String]]
    ) -> [ActionResolver.ResolvedAction] {
        var entry = source.entry
        entry.manifest.actions = ManifestBuilder.populatedActions(json, attempt: attempt.rawValue, source: source.module)
        guard !entry.manifest.actions.isEmpty else { return [] }
        let catalog = ActionCatalog(entries: [entry]).rekeyed {
            ActionKey(extensionIdentifier: $0.extensionIdentifier, action: "populated.\($0.action)")
        }
        return resolver.resolve(catalog, facts: facts, conditions: conditions, options: options).actions
    }

    /// `popclip.input` for a population function: the whole selection, and what analysis found in it.
    static func input(_ selection: AnalyzedSelection) -> JSInput {
        func detected(_ kind: Detection.Kind) -> [JSRangedString] {
            selection.detections(kind).map { JSRangedString(value: $0.value, location: $0.span.location, length: $0.span.length) }
        }
        return JSInput(
            text: selection.text,
            matchedText: selection.text,
            isURL: selection.isSingleURL,
            data: JSDetected(urls: detected(.url), nonHTTPURLs: detected(.nonHTTPURL), emails: detected(.email), paths: detected(.path))
        )
    }

    static func context(_ context: SelectionContext) -> JSSelectionContext {
        JSSelectionContext(
            hasFormatting: context.hasFormatting,
            canPaste: context.canPaste,
            canCopy: context.canCopy,
            canCut: context.canCut,
            browserURL: context.browser?.url?.absoluteString ?? "",
            browserTitle: context.browser?.title ?? "",
            appName: context.app.name ?? "",
            appIdentifier: context.app.bundleID ?? ""
        )
    }
}
