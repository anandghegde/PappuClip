import Foundation
import PappuAnalysis
import PappuCore
import PappuExtensions

/// Which actions this selection shows, and what each one acts on (FLT-1, FLT-5, architecture §6.3).
///
/// A pure function, called on the main thread inside the auto-appear budget (§4.7 allows it 20 ms
/// together with the analysis) and again by the palette, so that the two surfaces can never disagree
/// about what is available (ALM-8, BAR-16).
///
/// **Where it lives, and why here.** The resolver is the only thing that needs the analysis, the
/// context and the extension store at the same moment. `PappuAnalysis` may not know the store
/// (architecture §15); `PappuSelection` and `PappuAnalysis` may not know each other; `PappuCore` may
/// not know either, because the CLI and the registry's CI run the *pipeline* — `ActionMatching`, which
/// is in Core — on machines with no Accessibility tree. `PappuRuntime` is the first module above all
/// three, and it is also where the run that follows a click already lives.
///
/// **What this build runs of §6.3's six steps.**
///
/// | Step | M1 |
/// |---|---|
/// | 1. Drop unapproved, disabled, suspended, revoked | Disabled, and anything without an `ExecutionApproval` that covers its gates (M2 week 5, EXM-5). The store mints none for a suspended or revoked extension. |
/// | 2. App filters and option conditions | `ActionMatching` step 1, and option conditions against whatever values the caller has. |
/// | 3. `requirements`, negation, synonyms, narrowing | `ActionMatching` steps 2–5. |
/// | 4. `regex` | `ActionMatching` step 4 (M2). |
/// | 5. Per-app visibility (ALM-8) | M4. |
/// | 6. `dynamic` population (JS-16) | M3. |
///
/// Each missing step can only *remove* items, so an M1 bar is a superset of a finished one for any
/// manifest that uses those keys — and `ManifestBuilder` refuses such a manifest in M2 until the step
/// that reads it exists. That is the ordering that keeps a half-built pipeline honest rather than
/// permissive.
public struct ActionResolver: Sendable {
    /// One action the bar will show.
    public struct ResolvedAction: Sendable, Equatable {
        public var action: CatalogAction
        /// What it acts on (§8.5 steps 3 and 5).
        public var match: ActionMatching.Match
        /// What lets it run. Carried to the click so that the runner is handed the approval the bar
        /// was drawn with, not whatever it would find by looking again.
        public var approval: ExecutionApproval

        public var key: ActionKey { action.key }
    }

    /// Everything one resolution decided, including what it decided against.
    ///
    /// The refusals are not debris: DIA-2's inspector answers "why is Paste not here", and the only
    /// moment that answer exists is this one. They are keys and reasons — never selection text — so a
    /// resolution is safe to hand to a diagnostic (DIA-4).
    public struct Resolution: Sendable, Equatable {
        public var actions: [ResolvedAction]
        public var refusals: [ActionKey: Refusal]

        public var isEmpty: Bool { actions.isEmpty }

        public func match(for key: ActionKey) -> ActionMatching.Match? {
            actions.first { $0.key == key }?.match
        }
    }

    /// Why one action is not on this bar.
    public enum Refusal: Sendable, Equatable {
        /// ALM-4: the user turned it off. Checked before anything else, because a disabled action is
        /// not a question about the selection.
        case disabled
        /// EXM-5: nothing approves this extension's code — it is waiting for the user, its bytes
        /// changed since they approved it (SEC-8c), or they revoked it (SEC-4b).
        case notApproved
        /// EXM-5d: approved, but this action needs gated capabilities the user left at "Don't Allow".
        /// Absent rather than a button that fails, and the inspector can say which.
        case notGranted(Set<GatedCapability>)
        /// §8.5 said no.
        case filtered(ActionMatching.Refusal)
        /// A built-in's native condition said no (PRD §7.4): the clipboard is empty, or the selection
        /// is longer than Search will take.
        case builtinCondition(BuiltinAction)
    }

    /// The approval each action runs under, or nil. The app asks the store (`ExtensionStore.approvals`);
    /// the default approves only the app's own built-ins (EXM-5g), so a resolver that was never told
    /// about the store runs nothing an extension wrote.
    public typealias Approvals = @Sendable (CatalogAction) -> ExecutionApproval?

    private let approvals: Approvals

    public init(approvals: @escaping Approvals = ExecutionApproval.bundled) {
        self.approvals = approvals
    }

    /// A resolver over the store's approvals, keyed by identity. Built-ins are approved by the app.
    public init(approvals table: [LocalIdentity: ExecutionApproval]) {
        self.init { action in
            if let bundled = ExecutionApproval.bundled(action) { return bundled }
            return action.owner.flatMap(LocalIdentity.init).flatMap { table[$0] }
        }
    }

    /// Resolve against an analysed selection and its context.
    public func resolve(
        _ catalog: ActionCatalog,
        selection: AnalyzedSelection,
        context: SelectionContext,
        conditions: BuiltinConditions = .none,
        options: [String: [String: String]] = [:]
    ) -> Resolution {
        resolve(
            catalog,
            facts: MatchingFacts(selection: selection, context: context),
            conditions: conditions,
            options: options
        )
    }

    /// Resolve against facts assembled elsewhere — what `pappu-dev` and the registry's CI call, with
    /// facts they wrote rather than read.
    ///
    /// `options` is keyed by extension identifier, then by option id: an action's option conditions
    /// are about *its own* extension's options (§8.9), and a flat table would let one extension's
    /// setting answer another's question.
    public func resolve(
        _ catalog: ActionCatalog,
        facts: MatchingFacts,
        conditions: BuiltinConditions = .none,
        options: [String: [String: String]] = [:]
    ) -> Resolution {
        var actions: [ResolvedAction] = []
        var refusals: [ActionKey: Refusal] = [:]

        for action in catalog.actions {
            guard action.isEnabled else {
                refusals[action.key] = .disabled
                continue
            }
            // Before matching: an unapproved extension's requirements are its own code's claims about
            // itself, and nothing it wrote is consulted until the user has agreed to it.
            guard let approval = approvals(action), approval.owner == action.owner else {
                refusals[action.key] = .notApproved
                continue
            }
            guard approval.permits(action) else {
                refusals[action.key] = .notGranted(action.gates.subtracting(approval.gates))
                continue
            }
            let outcome = ActionMatching.match(
                action.manifest,
                against: facts,
                options: options[action.key.extensionIdentifier] ?? [:]
            )
            guard let match = outcome.match else {
                if let refusal = outcome.refusal { refusals[action.key] = .filtered(refusal) }
                continue
            }
            switch action.executor {
            case .builtin(let builtin):
                guard builtin.isOffered(for: facts, given: conditions) else {
                    refusals[action.key] = .builtinCondition(builtin)
                    continue
                }
            case .url, .keyPress, .shortcut, .service, .appleScript, .shellScript, .javaScript:
                // `ExtensionRunner`: M2 weeks 3 and 4, and the JavaScript helper, which transpiles
                // TypeScript (M3 weeks 1 and 2).
                break
            }
            actions.append(ResolvedAction(action: action, match: match, approval: approval))
        }

        return Resolution(actions: actions, refusals: refusals)
    }
}

extension MatchingFacts {
    /// Flatten what the analyser and the probe found into the pipeline's vocabulary (§8.5).
    ///
    /// The one judgement here is that `Detection.url` and `Detection.nonHTTPURL` both become
    /// `NarrowingKind.url`. It is the same rule `AnalyzedSelection.isSingleURL` already follows, and
    /// the same one PRD §7.4 states for Open Link: an action that asks for a link means a link, and
    /// `omnifocus:///task/1` is one. Nothing downstream loses the distinction, because Open Link's
    /// runner reads the analysis rather than this.
    public init(selection: AnalyzedSelection, context: SelectionContext) {
        self.init(
            text: selection.text,
            addresses: selection.detections.map(MatchingFacts.Address.init),
            isSingleAddress: selection.isSingleURL,
            bundleID: context.app.bundleID,
            // FLT-6 was already applied to these by `ContextProbe`: read-only text says false here
            // whatever the Edit menu claimed.
            canCut: context.canCut,
            canPaste: context.canPaste,
            hasFormatting: context.hasFormatting
        )
    }
}

extension MatchingFacts.Address {
    init(_ detection: Detection) {
        let kind: NarrowingKind
        switch detection.kind {
        case .url, .nonHTTPURL: kind = .url
        case .email: kind = .email
        case .path: kind = .path
        }
        self.init(kind: kind, span: detection.span, value: detection.value)
    }
}
