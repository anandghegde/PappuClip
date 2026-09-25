import Foundation
import PappuAnalysis
import PappuCore
import PappuExtensions
import PappuJSBridge
import PappuSelection

/// Runs an extension's action: its `before` step, its executor, and its `after` step (§8.4, §8.6,
/// architecture §8.1).
///
/// **The step pipeline.** Three stages in order, each one a chance to stop:
///
/// 1. `before` — `cut`, `copy`, `paste` or `paste-plain`, whatever the action is.
/// 2. The executor — this build runs URL, Key Press, Shortcut, Service, AppleScript, Shell Script,
///    JavaScript and TypeScript, which the JavaScript helper transpiles (M3 week 2).
/// 3. `after` — what to do with the result, or, for the four edit commands, one more edit.
///
/// Between stages the invocation must still be live (RUN-3b): a cancelled Shortcut's late answer is
/// dropped at the gate rather than pasted or copied, and a run that ends early is not finished here,
/// because the manager already let go of it.
///
/// **Every stage that touches the destination verifies it again.** Each edit and each paste takes a
/// permit of its own, so a `before: cut` and an `after: paste-result` are two verifications, and the
/// second one sees the selection the first one removed. The Accessibility tier calls that a changed
/// selection and refuses. That is the safe answer and it is the one given: PopClip's corpus has no
/// action that cuts and then pastes (the pairing is how a transformer would be written in 2012, not
/// how anyone writes one now), and a permit that survived its own edit would be a permit for a
/// destination nobody verified.
///
/// **`paste-result`** (§8.6) has three answers:
///
/// | At invocation | Destination now | Effect |
/// |---|---|---|
/// | Paste unavailable | — | Copies, and shows "Copied" — PopClip's behaviour |
/// | Paste available | verified | Holds the result for one ⌘V (`TextMutator`), then leaves it on the clipboard unless `restorePasteboard` |
/// | Paste available | stale or unsafe | Blocked (RUN-2c). Nothing is pasted *and nothing is copied*: the user's clipboard is not a consolation prize |
///
/// PopClip leaves a pasted result on the clipboard too; that is what `restorePasteboard` exists to
/// turn off. The paste itself always goes through `TextMutator` so there is one path that writes text
/// into another app, and the copy, when there is one, comes after it as an ordinary kept write.
public struct ExtensionRunner: Sendable {
    /// What one run is given. The same shape as `BuiltinRunner.Request`, plus the options.
    public struct Request: Sendable {
        public var invocation: InvocationID
        public var action: CatalogAction
        /// No request without one: the type is how "no extension code path is reachable without an
        /// `ExecutionApproval`" is kept (EXM-5). `run` checks it covers `action` before anything else.
        public var approval: ExecutionApproval
        public var match: ActionMatching.Match
        public var context: SelectionContext
        public var target: TargetApp
        public var modifiers: PointerEvent.Modifiers
        /// This extension's option values, by option id (§8.9).
        public var options: [String: String]
        /// What analysis found in the selection: §8.7's `URLS`, `EMAILS` and `PATHS`. Nil gives a
        /// script empty ones.
        public var selection: AnalyzedSelection?
        /// FLT-4: the selection with how it looks, captured because an action on the bar asked. Nil
        /// makes an action that asks for HTML or RTF have them from the plain text.
        public var captured: StyledText?

        public init(
            invocation: InvocationID,
            action: CatalogAction,
            approval: ExecutionApproval,
            match: ActionMatching.Match,
            context: SelectionContext,
            target: TargetApp,
            modifiers: PointerEvent.Modifiers = [],
            options: [String: String] = [:],
            selection: AnalyzedSelection? = nil,
            captured: StyledText? = nil
        ) {
            self.invocation = invocation
            self.action = action
            self.approval = approval
            self.match = match
            self.context = context
            self.target = target
            self.modifiers = modifiers
            self.options = options
            self.selection = selection
            self.captured = captured
        }

        /// §8.4 URL: ⇧ opens in the background.
        public var isShifted: Bool { modifiers.contains(.shift) }
        /// §8.4 URL: ⌥ quotes the query.
        public var isOptioned: Bool { modifiers.contains(.option) }
    }

    /// Which stage a run ended in. The inspector's word for "where".
    public enum Stage: String, Sendable, Equatable, CaseIterable {
        case before, executor, after
    }

    /// What the bar shows once the run is over (BAR-12b). The one thing in a report that can carry
    /// text, because showing the result is what `show-result` is for; it goes to the bar and nowhere
    /// else.
    public enum Display: Sendable, Equatable {
        /// The ordinary ending: a tick or an X.
        case status
        /// `copy-result`, and `paste-result` when it copied instead.
        case copied
        /// `show-result` and `preview-result`: the result, already cut to `previewLimit`.
        case result(String)
        /// `popclip-appear`: the bar comes back with its actions.
        case reappear
        /// A script's `showFailure` (JS-4): the X, though the action ran.
        case failure
    }

    /// Something a run asks of the user once it is over, beyond its tick or its X.
    public enum Attention: Sendable, Equatable {
        /// §8.4: shell exit 2 or AppleScript error 502. The extension's settings want looking at.
        case settings
        /// ONB-5: an AppleScript was not allowed to control the app it talks to. The user is sent to
        /// Privacy & Security → Automation, where the permission is.
        case automationPermission
        /// EXM-10: the extension needs an app that is not installed. The user is offered its website.
        case missingApp(name: String, link: URL?)
    }

    /// Why a run did not get as far as running, when the bar should say so in words (BAR-13). A code;
    /// the words are the bar's.
    public enum Problem: Sendable, Equatable {
        /// The action's code or script could not be started: its package would not read, the helper
        /// would not load it, its extension is suspended, or its script or interpreter is missing. The
        /// Debug Console says which.
        case didNotStart
    }

    /// §8.6: "truncated to 160 characters".
    public static let previewLimit = 160

    public typealias Outcome = BuiltinRunner.Outcome

    /// One run as the inspector will tell it (DIA-2, DIA-4).
    public struct Report: Sendable, Equatable {
        public let invocation: InvocationID
        public let outcome: Outcome
        /// Where it ended: the stage that failed, or `after` for a run that got to the end.
        public let stage: Stage
        public let display: Display
        /// Whether the executor produced text for `after`. Whether, never what.
        public let returnedText: Bool
        public let keyPress: KeyPressReport?
        public let attention: Attention?
        public let problem: Problem?

        public var ran: Bool { outcome == .done }
        public var block: DestinationBlock? {
            if case .blocked(let block) = outcome { return block }
            return nil
        }
    }

    private let manager: InvocationManager
    private let editor: SelectionEditor
    private let mutator: TextMutator
    private let presser: KeyPresser
    private let clipboard: any ClipboardKeeping
    private let urls: any URLOpening
    private let shortcuts: any ShortcutRunning
    private let shell: any ShellScriptRunning
    private let appleScripts: any AppleScriptRunning
    private let services: any ServiceRunning
    private let javaScript: any JavaScriptRunning
    private let system: any HostServices
    private let installed: any InstalledAppChecking

    public init(
        manager: InvocationManager,
        editor: SelectionEditor,
        mutator: TextMutator,
        presser: KeyPresser,
        clipboard: any ClipboardKeeping,
        urls: any URLOpening,
        shortcuts: any ShortcutRunning,
        shell: any ShellScriptRunning,
        appleScripts: any AppleScriptRunning,
        services: any ServiceRunning,
        javaScript: any JavaScriptRunning = NoJavaScript(),
        system: any HostServices = NoHostServices(),
        installed: any InstalledAppChecking = EveryAppInstalled()
    ) {
        self.manager = manager
        self.editor = editor
        self.mutator = mutator
        self.presser = presser
        self.clipboard = clipboard
        self.urls = urls
        self.shortcuts = shortcuts
        self.shell = shell
        self.appleScripts = appleScripts
        self.services = services
        self.javaScript = javaScript
        self.system = system
        self.installed = installed
    }

    /// Runs the action and ends its invocation, on the same terms as `BuiltinRunner.run`: finished
    /// with `completed`, `blocked` or `failed`, unless it was invalidated first.
    public func run(_ request: Request) async -> Report {
        let manifest = request.action.manifest
        var run = Run(request: request)

        // The approval came with the request, but a request is a value anyone can assemble from pieces;
        // this is where "the approval is for *this* action" is checked, once, before any stage runs.
        guard request.approval.covers(request.action) else { return await finish(run, .notRunning, at: .before) }

        // EXM-10: an app the extension says it needs, and checks for, is not here. Nothing runs, and the
        // user is offered the app's website instead.
        if let missing = Self.missingApp(of: request.action, installed: installed) {
            run.attention = .missingApp(name: missing.name, link: missing.link.flatMap(Self.website))
            return await finish(run, .notPerformed, at: .before)
        }

        if let before = manifest.before {
            let outcome = await edit(before, request)
            guard outcome == .done else { return await finish(run, outcome, at: .before) }
        }

        guard await manager.accepts(request.invocation) else { return await finish(run, .notRunning, at: .executor) }
        let executed = await execute(request, into: &run)
        guard executed == .done else { return await finish(run, executed, at: .executor) }

        guard await manager.accepts(request.invocation) else { return await finish(run, .notRunning, at: .after) }
        guard let after = manifest.after else { return await finish(run, .done, at: .after) }
        let outcome = await self.after(after, request, into: &run)
        return await finish(run, outcome, at: .after)
    }

    /// What one run has gathered on its way through the stages.
    struct Run {
        let request: Request
        var result: String?
        var display: Display = .status
        var keyPress: KeyPressReport?
        var attention: Attention?
        var problem: Problem?
    }

    // MARK: Executors

    private func execute(_ request: Request, into run: inout Run) async -> Outcome {
        switch request.action.executor {
        case .url(let action): return await openURL(action, request)
        case .keyPress(let action):
            let verification = await manager.verifyDestination(of: request.invocation)
            switch consume verification {
            case .blocked(let block): return .blocked(block)
            case .verified(let permit):
                let report = await presser.press(action, using: permit)
                run.keyPress = report
                return switch report.outcome {
                case .posted: .done
                case .notRunning: .notRunning
                case .notPosted: .notPerformed
                }
            }
        case .shortcut(let action):
            let (outcome, text) = await runShortcut(action, request)
            run.result = text
            return outcome
        case .service(let action):
            return await runScript(request, into: &run) {
                await services.start(service: action.name, text: request.match.value)
            }
        case .appleScript(let action):
            let variables = Self.variables(for: request)
            guard let job = Self.appleScriptJob(action, directory: request.action.directory, variables: variables) else {
                return .notPerformed
            }
            return await runScript(request, into: &run) { await appleScripts.start(job) }
        case .shellScript(let action):
            let job = ShellScriptJob(action: action, directory: request.action.directory, variables: Self.variables(for: request))
            return await runScript(request, into: &run) { await shell.start(job) }
        case .javaScript(let action):
            // One dispatcher for the run's host calls, with the grants it was approved with (SEC-7b).
            let host = HostAPIDispatcher(
                run: HostAPIDispatcher.Run(
                    invocation: request.invocation,
                    gates: request.approval.gates,
                    context: request.context,
                    target: request.target,
                    text: request.match.fullText
                ),
                effects: HostAPIDispatcher.Effects(
                    manager: manager,
                    mutator: mutator,
                    editor: editor,
                    presser: presser,
                    clipboard: clipboard,
                    urls: urls,
                    services: services,
                    system: system
                )
            )
            guard let job = Self.javaScriptJob(action, request, host: host) else {
                run.problem = .didNotStart
                return .notPerformed
            }
            let outcome = await runScript(request, into: &run) { await javaScript.start(job) }
            Self.apply(host.requests, to: &run)
            return outcome
        case .builtin:
            // Built-ins are `BuiltinRunner`'s; a request that gets here came from somewhere that
            // skipped the resolver.
            return .notPerformed
        }
    }

    /// Service, AppleScript and Shell Script: the same wait as a Shortcut's, with two more endings.
    private func runScript(
        _ request: Request,
        into run: inout Run,
        start: () async -> (any ScriptRun)?
    ) async -> Outcome {
        guard let started = await start() else {
            run.problem = .didNotStart
            return .notPerformed
        }
        // Registered before the wait, so that Escape reaches a script that hangs (RUN-3d).
        guard await manager.attach(started, to: request.invocation) else {
            _ = await started.cancel()
            return .notRunning
        }
        let ended = await started.result()
        // RUN-3c: a result that arrives after cancellation is thrown away, not passed to `after`.
        guard await manager.accepts(request.invocation) else { return .notRunning }
        switch ended {
        case .returned(let text):
            run.result = text
            return .done
        case .needsSettings:
            run.attention = .settings
            return .notPerformed
        case .automationDenied:
            run.attention = .automationPermission
            return .notPerformed
        case .failed: return .notPerformed
        case .stopped: return .notRunning
        }
    }

    /// §8.7's table for this run.
    static func variables(for request: Request) -> ScriptVariables {
        var modifiers: ScriptVariables.ModifierFlags = []
        if request.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if request.modifiers.contains(.control) { modifiers.insert(.control) }
        if request.modifiers.contains(.option) { modifiers.insert(.option) }
        if request.modifiers.contains(.command) { modifiers.insert(.command) }
        let selection = request.selection
        // FLT-4: an action that asked for HTML has it, sanitised and raw, and Markdown with it. The HTML
        // is written from the captured runs and is already sanitised, so the two are the same.
        let styled = request.action.manifest.captureHTML ? styledText(for: request) : nil
        return ScriptVariables(ScriptVariables.Inputs(
            text: request.match.value,
            fullText: request.match.fullText,
            html: styled?.html ?? "",
            rawHTML: styled?.html ?? "",
            markdown: styled?.markdown ?? "",
            urls: selection?.urls ?? [],
            emails: selection?.emails ?? [],
            paths: selection?.paths ?? [],
            modifiers: modifiers,
            bundleIdentifier: request.context.app.bundleID ?? "",
            appName: request.context.app.name ?? "",
            browserTitle: request.context.browser?.title ?? "",
            browserURL: request.context.browser?.url?.absoluteString ?? "",
            extensionIdentifier: request.action.key.extensionIdentifier,
            actionIdentifier: request.action.manifest.identifier ?? "",
            options: request.options
        ))
    }

    /// What the Runner is asked to run: inline source with its placeholders filled in, or a file
    /// found inside the package; and a handler's parameters looked up by name. Nil for a file that is
    /// missing or outside its package.
    static func appleScriptJob(
        _ action: AppleScriptAction,
        directory: URL?,
        variables: ScriptVariables
    ) -> AppleScriptRunRequest? {
        let source: AppleScriptRunRequest.Source
        switch action.source {
        case .inline(let text):
            source = .text(variables.substitutingPlaceholders(in: text))
        case .file(let relative):
            guard let directory, let file = PackageFile.resolve(relative, in: directory) else { return nil }
            source = .file(file)
        }
        return AppleScriptRunRequest(
            source: source,
            handler: action.call?.handler,
            arguments: action.call?.parameters.map { variables.value(forPlaceholder: $0) ?? "" } ?? []
        )
    }

    /// What the helper is asked to run, TypeScript included (the helper transpiles it). Nil for an
    /// action with no package or no approved bytes to load — a built-in, which is never JavaScript.
    static func javaScriptJob(_ action: JavaScriptAction, _ request: Request, host: HostAPIDispatcher? = nil) -> JavaScriptRunRequest? {
        guard let owner = request.approval.owner,
              let digest = request.approval.digest,
              let directory = request.action.directory
        else { return nil }
        return JavaScriptRunRequest(
            owner: owner,
            generation: digest.hex,
            extensionName: request.action.extensionName.description,
            directory: directory,
            action: action,
            input: input(for: request),
            context: context(for: request),
            modifiers: JSModifiers(
                shift: request.modifiers.contains(.shift),
                control: request.modifiers.contains(.control),
                option: request.modifiers.contains(.option),
                command: request.modifiers.contains(.command)
            ),
            options: request.options,
            booleanOptions: request.action.booleanOptions.sorted(),
            host: host
        )
    }

    /// `popclip.input` (JS-3). HTML, XHTML and Markdown are there for an action that asked for HTML, and
    /// RTF for one that asked for RTF (FLT-4), each also under its type in `content`. The XHTML is the
    /// HTML, which is written well-formed.
    static func input(for request: Request) -> JSInput {
        let match = request.match
        let manifest = request.action.manifest
        func detected(_ kind: Detection.Kind) -> [JSRangedString] {
            (request.selection?.detections(kind) ?? []).map {
                JSRangedString(value: $0.value, location: $0.span.location, length: $0.span.length)
            }
        }
        var content = [JSInput.plainTextType: match.fullText]
        var html = "", markdown = "", rtf = ""
        if manifest.captureHTML || manifest.captureRTF {
            let styled = styledText(for: request)
            if manifest.captureHTML {
                html = styled.html
                markdown = styled.markdown
                content[JSInput.htmlType] = html
            }
            if manifest.captureRTF {
                rtf = styled.rtf
                content[JSInput.rtfType] = rtf
            }
        }
        return JSInput(
            text: match.fullText,
            matchedText: match.value,
            regexResult: match.regexCaptures,
            html: html,
            xhtml: html,
            markdown: markdown,
            rtf: rtf,
            content: content,
            isURL: request.selection?.isSingleURL ?? false,
            data: JSDetected(urls: detected(.url), nonHTTPURLs: detected(.nonHTTPURL), emails: detected(.email), paths: detected(.path))
        )
    }

    /// FLT-4's chain as this build has it: the captured runs when they are the selection, else the plain
    /// text. A capture of other text than the run's is never used.
    static func styledText(for request: Request) -> StyledText {
        if let captured = request.captured, captured.string == request.match.fullText { return captured }
        return StyledText(plain: request.match.fullText)
    }

    /// `popclip.context` (JS-3).
    static func context(for request: Request) -> JSSelectionContext {
        let context = request.context
        return JSSelectionContext(
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

    /// EXM-10: the first app the action's extension checks for that has none of its bundle identifiers
    /// installed. An app that names no identifier cannot be checked and is taken to be there.
    static func missingApp(of action: CatalogAction, installed: any InstalledAppChecking) -> AppReference? {
        action.apps.first { app in
            app.checkInstalled && !app.bundleIdentifiers.isEmpty && !app.bundleIdentifiers.contains(where: installed.isInstalled)
        }
    }

    /// A link the alert may open: a web page, nothing else.
    public static func website(_ link: String) -> URL? {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// What a script's host calls asked of the bar (JS-4), for when the run ends. An `after` step that
    /// shows something of its own still has the last word.
    static func apply(_ requests: HostRequests, to run: inout Run) {
        if requests.settings { run.attention = .settings }
        switch requests.display {
        case .success?: run.display = .status
        case .failure?: run.display = .failure
        case .copied?: run.display = .copied
        case .text(let text)?: run.display = .result(text)
        case .appear?: run.display = .reappear
        case nil: break
        }
    }

    private func openURL(_ action: URLAction, _ request: Request) async -> Outcome {
        guard let url = URLTemplate.expand(
            action,
            text: request.match.value,
            quoted: request.isOptioned,
            options: request.options
        ) else { return .notPerformed }
        let opened = await urls.open([URLOpenRequest(
            url: url,
            activates: !request.isShifted,
            // PRD §7.4's browser rule, the same one Search and Open Link follow.
            browserBundleID: request.context.browser == nil ? nil : request.context.app.bundleID
        )])
        return opened == 1 ? .done : .notPerformed
    }

    private func runShortcut(_ action: ShortcutAction, _ request: Request) async -> (Outcome, String?) {
        guard let started = shortcuts.start(action.name, input: request.match.value) else {
            return (.notPerformed, nil)
        }
        // Registered before the wait, so Escape during a Shortcut that stopped to ask something reaches
        // it. A run cancelled before it could register is stopped here instead.
        guard await manager.attach(started, to: request.invocation) else {
            _ = await started.cancel()
            return (.notRunning, nil)
        }
        let ended = await started.result()
        // RUN-3c: a result that arrives after cancellation is thrown away, not passed to `after`.
        guard await manager.accepts(request.invocation) else { return (.notRunning, nil) }
        return switch ended {
        case .returned(let text): (.done, text)
        case .failed: (.notPerformed, nil)
        case .stopped: (.notRunning, nil)
        }
    }

    // MARK: Steps

    /// The four edit commands, which are the same in `before` and in `after`.
    private func edit(_ step: StepCommand, _ request: Request) async -> Outcome {
        switch step {
        case .cut: return await post(.cut, request)
        case .paste: return await post(.paste, request)
        case .pastePlain:
            guard let text = await clipboard.plainText(), !text.isEmpty else { return .nothingToDo }
            return await replace(with: text, request)
        case .copy:
            return await keep(request.match.value, request) ? .done : .notPerformed
        case .copyResult, .pasteResult, .previewResult, .showResult, .showStatus, .popclipAppear, .copySelection:
            // The builder refuses these in `before` (§8.6), so they cannot reach here from a manifest.
            return .notPerformed
        }
    }

    private func after(_ step: StepCommand, _ request: Request, into run: inout Run) async -> Outcome {
        switch step {
        case .cut, .copy, .paste, .pastePlain:
            return await edit(step, request)
        case .showStatus:
            return .done
        case .popclipAppear:
            run.display = .reappear
            return .done
        case .copySelection:
            return await keep(request.match.fullText, request) ? .done : .notPerformed
        case .copyResult, .pasteResult, .previewResult, .showResult:
            break
        }

        // The four that act on a result. An action that returned nothing has nothing to act on, and
        // that is not a failure: a Shortcut that only does something ends here, done.
        guard let result = run.result, !result.isEmpty else { return .done }

        switch step {
        case .pasteResult where request.context.canPaste:
            let outcome = await replace(with: result, request)
            guard outcome == .done, !request.action.manifest.restorePasteboard else { return outcome }
            // The paste landed; PopClip leaves the result on the clipboard as well. A clipboard that
            // would not take it does not undo the paste, so the run still completed.
            _ = await keep(result, request)
            return .done
        case .copyResult, .pasteResult:
            guard await keep(result, request) else { return .notPerformed }
            run.display = .copied
            return .done
        case .previewResult, .showResult:
            guard await keep(result, request) else { return .notPerformed }
            run.display = .result(Self.preview(result))
            return .done
        default:
            return .done
        }
    }

    private func post(_ command: EditCommand, _ request: Request) async -> Outcome {
        let verification = await manager.verifyDestination(of: request.invocation)
        switch consume verification {
        case .blocked(let block): return .blocked(block)
        case .verified(let permit):
            return switch await editor.post(command, using: permit).outcome {
            case .posted: .done
            case .notRunning: .notRunning
            case .notPosted: .notPerformed
            }
        }
    }

    private func replace(with text: String, _ request: Request) async -> Outcome {
        let verification = await manager.verifyDestination(of: request.invocation)
        switch consume verification {
        case .blocked(let block): return .blocked(block)
        case .verified(let permit):
            return switch await mutator.replaceSelection(with: text, using: permit).outcome {
            case .mutated, .clipboardContested: .done
            case .notRunning: .notRunning
            case .clipboardRefused: .notPerformed
            }
        }
    }

    private func keep(_ text: String, _ request: Request) async -> Bool {
        guard !text.isEmpty else { return false }
        return await clipboard.write(text, for: request.invocation, into: request.target).written
    }

    /// §8.6's 160 characters, with an ellipsis when something was cut.
    static func preview(_ text: String) -> String {
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit - 1)) + "…"
    }

    // MARK: Ending

    private func finish(_ run: Run, _ outcome: Outcome, at stage: Stage) async -> Report {
        switch outcome {
        case .done: await manager.finish(run.request.invocation, outcome: .completed)
        case .blocked: await manager.finish(run.request.invocation, outcome: .blocked)
        case .notPerformed, .nothingToDo: await manager.finish(run.request.invocation, outcome: .failed)
        case .notRunning: break
        }
        return Report(
            invocation: run.request.invocation,
            outcome: outcome,
            stage: stage,
            display: outcome == .done ? run.display : .status,
            returnedText: !(run.result ?? "").isEmpty,
            keyPress: run.keyPress,
            attention: run.attention,
            problem: run.problem
        )
    }
}

extension ActionManifest {
    /// Whether a run of this action can end in host-controlled input reaching the destination, and
    /// so whether its `InvocationRequest` says `mayMutate` (RUN-2a, RUN-2g) — `BuiltinAction`'s
    /// property of the same name, for extensions.
    ///
    /// A key press is synthetic input whatever keys it presses. Among the steps, the edit commands
    /// and `paste-result` put something into the destination, and `preview-result` will when its
    /// click-to-paste arrives (M3) — it says true now so that the tap is held for a run that will
    /// need it, which is the direction `InvocationRequest.mayMutate` asks callers to err in.
    public var mayMutateTheDestination: Bool {
        if case .keyPress = executor { return true }
        // A script can paste and press keys through the host API (JS-4), whatever its steps say.
        if case .javaScript = executor { return true }
        return [before, after].contains { step in
            switch step {
            case .cut, .paste, .pastePlain, .pasteResult, .previewResult: true
            default: false
            }
        }
    }
}
