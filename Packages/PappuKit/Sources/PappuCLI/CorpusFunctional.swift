import Foundation
import PappuCore
import PappuJSBridge
import PappuJSHost
import PappuRuntime
import Synchronization

/// The corpus's functional pass rate (PRD §3.3, implementation plan M3 week 7): of every package in
/// the frozen corpus, how many do what they are for when they are run, not just load.
///
/// **What a pass is.** A package passes when every action it offers passes, and an action passes when
/// the part of it that is the extension's own does its job headless:
///
/// - JavaScript runs in `JSHost`, the helper's own code, against `HeadlessHost`, and passes when it
///   returns a value or asks the app for an effect (a paste, a copy, a URL, a bar message), without
///   throwing.
/// - A URL action passes when its template expands to a URL with a scheme, and a key press when every
///   combo parses: opening a URL and posting a key are the app's shared code, tested on their own.
///
/// **What is not a pass, and is said separately** (PRD §3.3: the denominator is every package, and none
/// of these is folded into it as a pass):
///
/// - `blocked`: needs what a headless run cannot have — the network, a script runner, a macOS Service,
///   a Shortcut, a particular app, credentials, or a system service such as the dictionary.
/// - `loadOnly`: loads, but is AppleScript or a shell script, which a corpus run does not execute.
/// - `untested`: loads, but no sample selection shows the action, it is a built-in, it runs and does
///   nothing a headless run can observe, or its population function offers only what M4 will show.
/// - `failed`: will not load, will not describe, throws, or times out.
public struct CorpusFunctional: Sendable {
    public enum Verdict: String, Sendable, Codable, CaseIterable, Comparable {
        case passed
        case loadOnly = "load-only"
        case untested
        case blocked
        case failed

        /// Worst last: a package is as good as its worst action.
        var rank: Int { Self.allCases.firstIndex(of: self)! }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// Why an action is blocked.
    public enum Blocker: String, Sendable, Codable, CaseIterable {
        case network, script, service, shortcut, app, credentials
        case systemService = "system-service"
    }

    public struct ActionResult: Sendable, Equatable {
        public var title: String
        public var kind: ActionExecutor.Kind
        public var verdict: Verdict
        public var blocker: Blocker?
        public var detail: String

        public init(title: String, kind: ActionExecutor.Kind, verdict: Verdict, blocker: Blocker? = nil, detail: String) {
            self.title = title
            self.kind = kind
            self.verdict = verdict
            self.blocker = blocker
            self.detail = detail
        }
    }

    public struct PackageResult: Sendable, Equatable {
        /// Relative to the corpus root.
        public var path: String
        public var actions: [ActionResult]
        /// Set when the package failed or was untested as a whole: no load, no description, no actions.
        public var problem: String?
        /// Set with `problem`.
        public var problemVerdict: Verdict?

        public var verdict: Verdict {
            if let problemVerdict { return problemVerdict }
            return actions.map(\.verdict).max() ?? .untested
        }

        /// What stands in the way, for a blocked package.
        public var blockers: [Blocker] {
            Array(Set(actions.compactMap(\.blocker))).sorted { $0.rawValue < $1.rawValue }
        }

        public var detail: String {
            if let problem { return problem }
            let worst = actions.filter { $0.verdict == verdict }
            return worst.map { "\($0.title) (\($0.kind.rawValue)): \($0.detail)" }.joined(separator: "; ")
        }
    }

    public struct Report: Sendable, Equatable {
        public var packages: [PackageResult]

        public func count(_ verdict: Verdict) -> Int { packages.count { $0.verdict == verdict } }

        /// Passed over every package: the denominator is never reduced.
        public var rate: Double {
            packages.isEmpty ? 0 : Double(count(.passed)) / Double(packages.count)
        }

        public var rateText: String {
            String(
                format: "%d/%d functional (%.1f%%): %d blocked, %d load-only, %d untested, %d failed",
                count(.passed), packages.count, rate * 100, count(.blocked), count(.loadOnly), count(.untested), count(.failed)
            )
        }
    }

    /// Sample selections, tried in order until one shows the action: ordinary text first, then the
    /// shapes the corpus's regexes and requirements ask for (an IP address, a DOI, a hash, two lines,
    /// an encoded string, Chinese, Cyrillic, full-width letters, JSON, a handle, an empty selection
    /// where something can be pasted).
    static let samples: [MatchingFacts] = {
        func address(_ text: String, _ kind: NarrowingKind, single: Bool) -> MatchingFacts {
            MatchingFacts(
                text: text,
                addresses: [.init(kind: kind, span: TextSpan(location: 0, length: (text as NSString).length), value: text)],
                isSingleAddress: single
            )
        }
        let plain = [
            "Hello world", "The quick brown fox jumps over the lazy dog.", "hello_world example-text",
            "12345", "3.14", "#ff8800", "2024-01-15", "HELLO WORLD", "1700000000",
            "banana\napple\ncherry", "8.8.8.8", "example.com", "10.1000/xyz123", "index.home.raft",
            "Tom &amp; Jerry", "Hello%20world", "SGVsbG8gd29ybGQ=", "0123456789abcdef0123456789abcdef01234567",
            "你好世界", "Привет мир", "ＡＢＣ１２３", #"{"name": "value"}"#, "@pappuclip", "mdi:home", "10 km", "72 °F", "",
        ]
        return plain.map { MatchingFacts(text: $0) } + [
            address("https://example.com/page", .url, single: true),
            address("someone@example.com", .email, single: false),
            address("/Users/Shared", .path, single: false),
        ]
    }()

    /// The app a sample selection is in: a browser showing a page, so that an action that reads the
    /// context has one to read.
    static let context = JSSelectionContext(
        hasFormatting: true, canPaste: true, canCopy: true, canCut: true,
        browserURL: "https://example.com/page", browserTitle: "Example", appName: "Safari", appIdentifier: "com.apple.Safari"
    )

    /// Each action's time to run.
    public var timeout: Duration

    public init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
    }

    public func run(corpus root: URL, packages: [URL]) async -> Report {
        let rootPath = root.standardizedFileURL.path
        var results: [PackageResult] = []
        for url in packages {
            var path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") { path.removeFirst(rootPath.count + 1) }
            results.append(await check(url, path: path))
        }
        return Report(packages: results)
    }

    /// One package.
    public func check(_ url: URL, path: String) async -> PackageResult {
        var result = PackageResult(path: path, actions: [])
        func problem(_ verdict: Verdict, _ why: String) -> PackageResult {
            result.problem = why
            result.problemVerdict = verdict
            return result
        }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        var files: [String: String] = [:]
        var snippet: String?
        if isDirectory {
            guard case .success(let read) = PackageSources.read(url) else { return problem(.failed, "The package cannot be read.") }
            files = read
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return problem(.failed, "Not UTF-8 text.") }
            snippet = text
        }
        func load(_ settings: ExtensionLoader.Settings) throws(ManifestLoadFailure) -> ExtensionManifest {
            if let snippet { return try ExtensionLoader.loadSnippet(snippet, settings: settings).manifest }
            return try ExtensionLoader.loadPackage(at: url, settings: settings).manifest
        }

        var manifest: ExtensionManifest
        var populates = false
        do {
            manifest = try load(.init())
        } catch {
            return problem(.failed, "Does not load: " + error.errors.map(\.description).joined(separator: " "))
        }

        // One world per package, as the app has, with every grant: what is not served is refused after
        // the grant, so a blocked action says what blocked it.
        let session = Session(files: files, timeout: timeout)
        defer { session.close() }
        if let module = manifest.moduleSource {
            switch await session.describe(module) {
            case .failure(let why):
                return problem(.failed, "The module does not describe: \(why)")
            case .success(let exports):
                populates = exports.functions.contains("actions")
                do {
                    manifest = try load(.init(moduleExports: exports))
                } catch {
                    return problem(.failed, "The module's actions do not load: " + error.errors.map(\.description).joined(separator: " "))
                }
            }
        }
        let options = OptionValues.effective(manifest.options, stored: [:])
        let booleans = manifest.options.filter { $0.kind == .boolean }.compactMap(\.identifier).sorted()
        session.booleanOptions = booleans
        let needsCredentials = manifest.authServiceLabel != nil
            || manifest.options.contains { $0.kind == .secret || $0.kind == .password }
        for action in manifest.actions {
            result.actions.append(await check(action, options: options, needsCredentials: needsCredentials, session: session))
        }

        // JS-13: a population function, for an extension with the dynamic entitlement, offers its
        // actions per selection. The first sample it offers any for is the one they are run with.
        if let module = manifest.moduleSource, populates, manifest.entitlements.contains(.dynamic) {
            var offered = false
            var leftOut = false
            for sample in Self.samples where !sample.text.isEmpty {
                let input = Self.input(facts: sample, match: ActionMatching.Match(narrowing: nil, span: nil, value: sample.text, fullText: sample.text))
                switch await session.populate(module, input: input, options: options) {
                case .failure(let why):
                    return problem(.failed, "The population function fails: \(why)")
                case .success(let (attempt, json)):
                    let actions = ManifestBuilder.populatedActions(
                        json, attempt: attempt, source: module, package: isDirectory ? PackageFiles(root: url) : nil
                    )
                    guard !actions.isEmpty else {
                        if json.contains("{") { leftOut = true }
                        continue
                    }
                    offered = true
                    for action in actions {
                        result.actions.append(await check(
                            action, options: options, needsCredentials: needsCredentials, session: session, samples: [sample]
                        ))
                    }
                }
                if offered { break }
            }
            if !offered, result.actions.isEmpty {
                return problem(.untested, leftOut
                    ? "Its population function offers only actions without code (shown disabled) or submenus, which arrive in M4."
                    : "Its population function offers nothing for any sample selection.")
            }
        }
        guard !result.actions.isEmpty else {
            return problem(.untested, "Offers no actions: its population function needs the dynamic entitlement, or it has none.")
        }
        return result
    }

    private func check(
        _ action: ActionManifest,
        options stored: [String: String],
        needsCredentials: Bool,
        session: Session,
        samples: [MatchingFacts] = CorpusFunctional.samples
    ) async -> ActionResult {
        // An action shown only under an option value is tried with that value: someone can choose it.
        var options = stored
        for requirement in action.requirements where !requirement.isNegated {
            if case .option(let id, let value) = requirement.condition { options[id] = value }
        }
        let title = action.title?.description ?? action.identifier ?? "(untitled)"
        let kind = action.executor.kind
        func verdict(_ verdict: Verdict, _ detail: String, blocker: Blocker? = nil) -> ActionResult {
            ActionResult(title: title, kind: kind, verdict: verdict, blocker: blocker, detail: detail)
        }
        if !action.requiredApps.isEmpty {
            return verdict(.blocked, "Shown only in \(action.requiredApps.joined(separator: ", ")).", blocker: .app)
        }
        // Every sample that shows it, each with the facts it was shown under.
        let shown: [(MatchingFacts, ActionMatching.Match)] = samples.compactMap { sample in
            for able in [true, false] {
                var facts = sample
                facts.canCut = able
                facts.canPaste = able
                facts.hasFormatting = able
                if let match = ActionMatching.match(action, against: facts, options: options).match { return (facts, match) }
            }
            return nil
        }
        guard let (facts, match) = shown.first else {
            return verdict(.untested, "No sample selection shows it.")
        }

        switch action.executor {
        case .builtin:
            return verdict(.untested, "A built-in, which the corpus does not have.")
        case .url(let url):
            guard let expanded = URLTemplate.expand(url, text: match.value, quoted: false, options: options),
                  let scheme = expanded.scheme, !scheme.isEmpty
            else { return verdict(.failed, "The template does not make a URL.") }
            return verdict(.passed, "Opens \(scheme): URL.")
        case .keyPress(let keys):
            do {
                for step in keys.steps { _ = try KeyCombo.parse(step) }
                return verdict(.passed, "Every combo parses.")
            } catch {
                return verdict(.failed, "A combo does not parse: \(error).")
            }
        case .service:
            return verdict(.blocked, "Needs a macOS Service from another app.", blocker: .service)
        case .shortcut:
            return verdict(.blocked, "Needs a Shortcut of the person's own.", blocker: .shortcut)
        case .appleScript:
            return verdict(.loadOnly, "AppleScript is not run by a corpus pass.")
        case .shellScript:
            return verdict(.loadOnly, "A shell script is not run by a corpus pass.")
        case .javaScript(let script):
            // The first sample that shows it decides, unless a later one passes: an action written for
            // one kind of text (Base64 to decode, a number to format) is judged on that kind.
            var first: ActionResult?
            for (facts, match) in shown {
                let outcome = await session.invoke(script, input: Self.input(facts: facts, match: match), options: options)
                let judged = Self.judge(outcome, needsCredentials: needsCredentials, title: title)
                if judged.verdict == .passed { return judged }
                if first == nil { first = judged }
                if outcome.ending == .timedOut { break }
            }
            return first!
        }
    }

    static func input(facts: MatchingFacts, match: ActionMatching.Match) -> JSInput {
        func detected(_ kind: NarrowingKind) -> [JSRangedString] {
            facts.addresses(kind).map { JSRangedString(value: $0.value, location: $0.span.location, length: $0.span.length) }
        }
        return JSInput(
            text: match.fullText,
            matchedText: match.value,
            regexResult: match.regexCaptures,
            isURL: facts.isSingleAddress,
            data: JSDetected(urls: detected(.url), emails: detected(.email), paths: detected(.path))
        )
    }

    /// A JavaScript action's verdict from what it did.
    static func judge(_ outcome: DevelopmentRun.Outcome, needsCredentials: Bool, title: String) -> ActionResult {
        func verdict(_ verdict: Verdict, _ detail: String, blocker: Blocker? = nil) -> ActionResult {
            ActionResult(title: title, kind: .javaScript, verdict: verdict, blocker: blocker, detail: detail)
        }
        let effects = outcome.calls.filter { $0.wasServed && $0.method != HostMethod.pasteboardRead.rawValue }
        if case .returned(let value) = outcome.ending, value != nil || !effects.isEmpty {
            let what = value != nil ? "returns a value" : "asks for \(effects.map(\.method).joined(separator: ", "))"
            return verdict(.passed, "Runs and \(what).")
        }
        let methods = Set(outcome.calls.map(\.method))
        if methods.contains(NetworkHostCalls.method) {
            return verdict(.blocked, "Makes a network request.", blocker: .network)
        }
        if !methods.isDisjoint(with: [ScriptHostCalls.shell, ScriptHostCalls.appleScript, ScriptHostCalls.shortcut]) {
            return verdict(.blocked, "Runs a script.", blocker: .script)
        }
        if let unavailable = outcome.calls.first(where: { if case .failed = $0.answer { true } else { false } }) {
            return verdict(.blocked, "Needs \(unavailable.method).", blocker: .systemService)
        }
        switch outcome.ending {
        case .returned:
            // Clearing a chat or a timer changes only the world's own state, which is not a failure and
            // is not something a headless run can see either.
            return verdict(.untested, "Runs without error, and does nothing a headless run can observe.")
        case .threw(let why):
            let lowered = why.lowercased()
            if lowered.hasPrefix("not signed in") || lowered.hasPrefix("settings error") || lowered.contains("api key")
                || needsCredentials {
                return verdict(.blocked, "Needs settings or a sign-in: \(why)", blocker: .credentials)
            }
            return verdict(.failed, "Throws: \(why)")
        case .notRun(let why):
            return verdict(.failed, "Does not start: \(why)")
        case .timedOut:
            return verdict(.failed, "Still running at the timeout.")
        }
    }
}

/// One package's world in an in-process helper.
final class Session: Sendable {
    let host = HeadlessHost(gates: Set(GatedCapability.allCases))
    let jsHost: JSHost
    let files: [String: String]
    let timeout: Duration
    /// Nil until loaded, then the load's failure or "".
    private let loaded = Mutex<String?>(nil)
    static let name = "corpus"

    init(files: [String: String], timeout: Duration) {
        jsHost = JSHost(qos: .userInitiated, call: host.serve) { _, _ in }
        self.files = files
        self.timeout = timeout
    }

    func close() {
        let jsHost = jsHost
        jsHost.handle(.unload(extension: Self.name)) { _ in }
    }

    /// The package's files, loaded once. Nil when they loaded, or why not.
    private func load() async -> String? {
        if let done = loaded.withLock({ $0 }) { return done.isEmpty ? nil : done }
        let why: String? = switch await ask(jsHost, .load(JSLoad(extensionName: Self.name, generation: "1", files: files))) {
        case .loaded: nil
        case .loadFailed(let why): why
        case let other: "The package did not load: \(other)."
        }
        loaded.withLock { $0 = why ?? "" }
        return why
    }

    private static func entry(_ source: ScriptSource) -> JSInvoke.Entry {
        switch source {
        case .inline(let text): .inline(text)
        case .file(let path): .file(path)
        }
    }

    func describe(_ module: ModuleSource) async -> Result<ModuleExports, DescribeFailure> {
        if let why = await load() { return .failure(DescribeFailure(why)) }
        let request = JSHostRequest.describe(JSDescribe(
            extensionName: Self.name, generation: "1", entry: Self.entry(module.source), typeScript: module.isTypeScript
        ))
        switch await ask(jsHost, request, within: timeout) {
        case .described(let description):
            do {
                return .success(try ModuleExports(json: description.exports, functions: description.functions))
            } catch {
                return .failure(DescribeFailure("What it exported cannot be read: \(error)"))
            }
        case .threw(let why): return .failure(DescribeFailure(why))
        case nil: return .failure(DescribeFailure("Still loading at the timeout."))
        case let other?: return .failure(DescribeFailure("The helper answered \(other)."))
        }
    }

    private let invocations = Counter()
    private let booleans = Mutex<[String]>([])

    /// The extension's boolean options, which the helper hands a script as booleans.
    var booleanOptions: [String] {
        get { booleans.withLock { $0 } }
        set { booleans.withLock { $0 = newValue } }
    }

    /// JS-13: one attempt's population, as the attempt number and the actions' JSON.
    func populate(_ module: ModuleSource, input: JSInput, options: [String: String]) async -> Result<(UInt64, String), DescribeFailure> {
        if let why = await load() { return .failure(DescribeFailure(why)) }
        let attempt = invocations.next()
        let request = JSHostRequest.populate(JSPopulate(
            attempt: attempt,
            extensionName: Self.name,
            generation: "1",
            entry: Self.entry(module.source),
            typeScript: module.isTypeScript,
            input: input,
            context: CorpusFunctional.context,
            options: options,
            booleanOptions: booleanOptions
        ))
        switch await ask(jsHost, request, within: timeout) {
        case .populated(let population)?: return .success((attempt, population.actions))
        case .threw(let why)?: return .failure(DescribeFailure(why))
        case nil: return .failure(DescribeFailure("Still running at the timeout."))
        case let other?: return .failure(DescribeFailure("The helper answered \(other)."))
        }
    }

    func invoke(_ script: JavaScriptAction, input: JSInput, options: [String: String]) async -> DevelopmentRun.Outcome {
        let before = host.recorded.count
        let finish = { (ending: DevelopmentRun.Ending) in
            DevelopmentRun.Outcome(ending: ending, log: [], calls: Array(self.host.recorded.dropFirst(before)))
        }
        if let why = await load() { return finish(.notRun(why)) }
        let invocation = invocations.next()
        let request = JSInvoke(
            invocation: invocation,
            extensionName: Self.name,
            generation: "1",
            entry: Self.entry(script.source),
            input: input,
            context: CorpusFunctional.context,
            options: options,
            booleanOptions: booleanOptions,
            typeScript: script.isTypeScript,
            export: script.export
        )
        switch await ask(jsHost, .invoke(request), within: timeout) {
        case nil:
            _ = await ask(jsHost, .drop(invocation: invocation))
            return finish(.timedOut)
        case .returned(let value)?: return finish(.returned(value))
        case .threw(let why)?: return finish(.threw(why))
        case let other?: return finish(.notRun("The helper answered \(other)."))
        }
    }
}

struct DescribeFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Invocation numbers, from 1.
final class Counter: Sendable {
    private let value = Mutex<UInt64>(0)
    func next() -> UInt64 { value.withLock { $0 += 1; return $0 } }
}
