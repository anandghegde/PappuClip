import Foundation
import PappuAnalysis
import PappuCore
import PappuRuntime
import PappuSelection
import PappuSurfaces

/// What the bridge talks back to: the bar, as far as an invocation needs it (BAR-12a).
///
/// `BarController` conforms without adding a line. The protocol exists so the bridge can be built and
/// tested against a recorder, and so the construction cycle has somewhere to break — the controller
/// needs the bridge at `init` and the bridge needs the controller, so the controller is attached after.
@MainActor
public protocol InvocationReporting: AnyObject, Sendable {
    func report(_ state: BarFeedbackState)
    func dismiss(_ reason: BarDismissalReason)
}

extension BarController: InvocationReporting {}

/// What the bridge hands on when a script asks something of the user (§8.4, ONB-5): its settings,
/// for a shell exit 2 or an AppleScript error 502, or the Automation permission it was refused.
@MainActor
public protocol AttentionPresenting: AnyObject, Sendable {
    func present(_ attention: ExtensionRunner.Attention, for action: String)
}

/// How long a finished action's answer stays on screen (BAR-12a).
public struct BridgeTiming: Sendable, Equatable {
    /// The tick, the shake or the word "Copied" is worth nothing if it is taken away in the same
    /// runloop turn it appeared in.
    public var confirmation: Duration

    public init(confirmation: Duration = .milliseconds(700)) {
        self.confirmation = confirmation
    }

    public static let initial = BridgeTiming()
}

/// The join between the bar and the run (architecture §6.3, §15).
///
/// `PappuSurfaces` declares two questions — what should this bar hold, and what should a press do — and
/// `PappuRuntime` can answer both, but neither module may depend on the other, so the answer lives
/// here. That is the whole reason `PappuApp` exists.
///
/// **What one appearance costs.** `content(for:)` runs inside the auto-appear budget (§4.7 gives the
/// analysis and the resolve 20 ms together), and everything it does is bounded: the context probe has
/// its own budgets, the analyser has character and detection ceilings, and the resolve is a pure
/// function over what they found. It does no I/O of its own.
///
/// **Why the gate is asked twice.** The coordinator already passed §S1 to read the selection, and this
/// asks again before probing the context. It has to: `ContextProbe` reads the Accessibility tree and no
/// read happens without a `ReadPermit` (architecture §3.1), and the permit that read the selection was
/// consumed by the read that produced it. Asking again is not a formality — secure input can have begun
/// and the app can have been blocked in the moment since — and a second refusal returns an empty bar,
/// which `BarController` turns into no bar at all rather than an empty one.
///
/// **What it remembers, and for how long.** One attempt's resolution, replaced by the next. There is
/// one bar at a time (ACT-16a), so a click that names an older attempt finds nothing and does nothing.
/// The remembered selection text is the same string the bar was built from, which is what makes a click
/// act on what the user saw rather than on what is selected by the time they let go of the mouse.
public actor SelectionBridge: BarContentProviding, BarActionInvoking {
    /// What was decided for the attempt currently on screen.
    private struct Prepared {
        var attempt: AttemptID
        var selection: AnalyzedSelection
        var context: SelectionContext
        var resolution: ActionResolver.Resolution
    }

    private let catalog: @Sendable () -> ActionCatalog
    private let gate: PrivacyGate
    private let probe: ContextProbe
    private let analyzer: ContentAnalyzer
    private let resolver: ActionResolver
    private let manager: InvocationManager
    private let runner: BuiltinRunner
    private let extensions: ExtensionRunner
    private let conditions: @Sendable () -> BuiltinConditions
    private let secureInput: @Sendable () -> SecureInputState
    private let locale: @Sendable () -> Locale
    private let sleeper: any InvocationSleeping
    private let timing: BridgeTiming

    private weak var reporter: (any InvocationReporting)?
    private weak var attention: (any AttentionPresenting)?
    private var prepared: Prepared?
    /// The run a press started, so that the next press can take it back (RUN-3).
    private var running: InvocationID?

    public init(
        catalog: @escaping @Sendable () -> ActionCatalog,
        gate: PrivacyGate,
        probe: ContextProbe,
        analyzer: ContentAnalyzer,
        manager: InvocationManager,
        runner: BuiltinRunner,
        extensions: ExtensionRunner,
        // Read once per attempt rather than held, because the clipboard's contents and the user's
        // settings both move between one bar and the next (ACT-10, PRD §7.4).
        conditions: @escaping @Sendable () -> BuiltinConditions,
        secureInput: @escaping @Sendable () -> SecureInputState,
        resolver: ActionResolver = ActionResolver(),
        locale: @escaping @Sendable () -> Locale = { .current },
        sleeper: any InvocationSleeping = SystemInvocationSleep(),
        timing: BridgeTiming = .initial
    ) {
        self.catalog = catalog
        self.gate = gate
        self.probe = probe
        self.analyzer = analyzer
        self.resolver = resolver
        self.manager = manager
        self.runner = runner
        self.extensions = extensions
        self.conditions = conditions
        self.secureInput = secureInput
        self.locale = locale
        self.sleeper = sleeper
        self.timing = timing
    }

    /// The bar, once it exists. Separate from `init` because the controller is built with this bridge
    /// and this bridge has to be able to talk back to it; one of the two references has to be made
    /// second, and this is the one that may be absent without anything breaking.
    public func attach(_ reporter: any InvocationReporting) {
        self.reporter = reporter
    }

    /// Where a script's request for settings or permission goes. Attached after, like the bar.
    public func attach(attention presenter: any AttentionPresenting) {
        self.attention = presenter
    }

    // MARK: BarContentProviding

    public func content(for presentation: AttemptPresentation) async -> BarContent {
        // ACT-3's caret bar is a bar with no selection, and Paste has to be reachable there: it is the
        // one built-in whose requirements do not include `text`. The resolver already knows that, so all
        // this has to get right is handing it the empty selection rather than turning the attempt away
        // before it is asked. Any other verdict without text has nothing to act on, and an empty answer
        // is what `BarController` turns into no bar at all.
        let text = presentation.text ?? ""
        guard presentation.verdict.showsBar, presentation.verdict == .caret || !text.isEmpty else {
            prepared = nil
            return BarContent(items: [])
        }

        let decision = gate.evaluate(
            route: presentation.route,
            target: presentation.target,
            secureInput: secureInput()
        )
        guard let permit = decision.permit() else {
            prepared = nil
            return BarContent(items: [])
        }

        let context = await probe.probe(permit)
        let selection = analyzer.analyze(text)
        let resolution = resolver.resolve(
            catalog(),
            selection: selection,
            context: context,
            conditions: conditions()
        )

        prepared = Prepared(
            attempt: presentation.attempt,
            selection: selection,
            context: context,
            resolution: resolution
        )
        return BarContent(actions: resolution.actions.map(\.action), locale: locale())
    }

    // MARK: BarActionInvoking

    public func invoke(_ click: BarClick, for presentation: AttemptPresentation) async {
        guard let prepared, prepared.attempt == presentation.attempt,
              let resolved = prepared.resolution.actions.first(where: { BarItemID($0.key) == click.item })
        else {
            // A click on a bar whose attempt has been retired, or on a button that is not in the
            // resolution any more. Nothing runs, and the bar is told so rather than left spinning.
            await finish(.failed)
            return
        }

        let builtin = resolved.action.builtin
        let invocation = await manager.begin(
            InvocationRequest(
                attempt: presentation.attempt,
                route: presentation.route,
                target: presentation.target,
                action: resolved.key.description,
                mayMutate: builtin?.mayMutateTheDestination ?? resolved.action.manifest.mayMutateTheDestination,
                // The text the bar was built from, not the text that is selected now. RUN-1b's
                // verification is what decides whether it is still there.
                text: prepared.selection.text,
                range: presentation.range,
                strategy: presentation.strategy
            )
        )
        running = invocation

        let ending: Ending
        var request: ExtensionRunner.Attention?
        if let builtin {
            let report = await runner.run(
                BuiltinRunner.Request(
                    invocation: invocation,
                    builtin: builtin,
                    match: resolved.match,
                    selection: prepared.selection,
                    context: prepared.context,
                    target: presentation.target,
                    modifiers: click.modifiers
                )
            )
            ending = Ending(state: Self.feedback(for: report), then: .dismiss)
        } else {
            let report = await extensions.run(
                ExtensionRunner.Request(
                    invocation: invocation,
                    action: resolved.action,
                    match: resolved.match,
                    context: prepared.context,
                    target: presentation.target,
                    modifiers: click.modifiers,
                    // Option values come from the extension's settings, which are M3's (EXT-9); until
                    // then every option placeholder expands to nothing, as an unset option does.
                    options: [:],
                    selection: prepared.selection
                )
            )
            ending = Self.ending(for: report, stayVisible: resolved.action.manifest.stayVisible)
            request = report.attention
        }
        if running == invocation { running = nil }
        await finish(ending)
        // After the bar has said the action failed, so that the sheet or the alert is what follows
        // the X rather than something that covers it.
        if let request, let attention {
            await attention.present(request, for: resolved.action.title.text(for: locale()))
        }
    }

    /// RUN-3: the press that arrives while something is running means stop.
    ///
    /// Everything the bar started, rather than the one identifier it remembers, because an invocation
    /// that was begun and then left behind by a second press would otherwise stay live and keep its
    /// lease on the key tap.
    public func cancelRunningAction() async {
        running = nil
        for invocation in await manager.runningInvocations {
            await manager.cancel(invocation, reason: .cancelled)
        }
    }

    /// What the user is shown for each way a built-in can end (BAR-12a).
    ///
    /// `nothingToDo` shows the failure mark even though nothing is broken. The user pressed a button and
    /// the thing did not happen, and a tick would be a lie; the distinction the runner drew is for the
    /// inspector, which is where an explanation belongs (DIA-2).
    static func feedback(for report: BuiltinRunner.Report) -> BarFeedbackState {
        switch report.outcome {
        case .done:
            // Copy's own word, because a tick on a bar that is about to vanish does not say what
            // happened and "Copied" does.
            report.builtin == .copy ? .copied : .succeeded
        case .notRunning:
            // Cancelled, paused out or revoked. The bar went back to idle when the press was taken as
            // a stop; there is nothing further to say.
            .idle
        case .blocked, .notPerformed, .nothingToDo:
            .failed
        }
    }

    /// What the bar shows when a run ends, and what becomes of it afterwards.
    struct Ending: Equatable {
        enum Then: Equatable {
            /// The usual end: the answer, a moment to read it, and no bar.
            case dismiss
            /// `stayVisible`: the answer for the same moment, then the buttons again.
            case returnToButtons
            /// Left as it is until the user dismisses it the way any bar is dismissed (BAR-10). A
            /// result is read at the reader's pace, and a clock under it would be one the user loses to.
            case stay
        }

        var state: BarFeedbackState
        var then: Then
    }

    /// What the user is shown for each way an extension's action can end (BAR-12a, BAR-12b, §8.6).
    ///
    /// The outcomes read as the built-ins' do. What `after` adds is the display: its own word for a
    /// copy, the text for a result, and for `popclip-appear` the buttons back where they were.
    static func ending(for report: ExtensionRunner.Report, stayVisible: Bool) -> Ending {
        switch report.outcome {
        case .done:
            switch report.display {
            case .result(let text): return Ending(state: .result(text), then: .stay)
            case .reappear: return Ending(state: .idle, then: .stay)
            case .copied: return Ending(state: .copied, then: stayVisible ? .returnToButtons : .dismiss)
            case .status: return Ending(state: .succeeded, then: stayVisible ? .returnToButtons : .dismiss)
            }
        case .notRunning:
            return Ending(state: .idle, then: .dismiss)
        case .blocked, .notPerformed, .nothingToDo:
            return Ending(state: .failed, then: .dismiss)
        }
    }

    private func finish(_ state: BarFeedbackState) async {
        await finish(Ending(state: state, then: .dismiss))
    }

    /// Show the answer, leave it up long enough to be read, then take the bar away (BAR-12a, BAR-10).
    ///
    /// This is a clock, and BAR-10 says passive dismissal has none. It is not passive dismissal: the
    /// user pressed a button, the bar going away is the consequence of that press, and the wait exists
    /// only so the tick is on screen long enough to be seen. A bar dismissed in the same turn it
    /// reported success would report it to nobody.
    private func finish(_ ending: Ending) async {
        guard let reporter else { return }
        await reporter.report(ending.state)
        guard ending.state != .idle, ending.then != .stay else { return }
        await sleeper.sleep(for: timing.confirmation)
        switch ending.then {
        case .dismiss: await reporter.dismiss(.actionRun)
        case .returnToButtons: await reporter.report(.idle)
        case .stay: break
        }
    }
}
