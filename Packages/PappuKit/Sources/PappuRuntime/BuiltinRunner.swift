import Foundation
import PappuAnalysis
import PappuCore
import PappuSelection

/// The seam for the clipboard's *kept* half: reading what is on it, and replacing it (PRD §7.4).
///
/// `TextPasting` is the other half — borrowing the clipboard for a moment and giving it back — and the
/// two are separate protocols because they are separate promises. A test of Copy wants to watch what
/// was left on the clipboard; a test of Paste wants to watch what was put back.
public protocol ClipboardKeeping: Sendable {
    func plainText() async -> String?
    func write(_ text: String, for invocation: InvocationID, into target: TargetApp) async -> ClipboardWriteResult
}

extension ClipboardBroker: ClipboardKeeping {}

/// Runs the five built-ins (PRD §7.4, architecture §8.7).
///
/// **The one executor M1 has.** `ActionExecutor` has a single case, `builtin`, and this is what stands
/// behind it: the five actions the bar ships with, each reached through the same manifest, the same
/// matching pipeline and the same `InvocationManager` lifecycle as anything a user will install in M2.
/// Nothing here is a shortcut past the run — a built-in is verified, cancelled, traced and finished
/// like everything else, and that is the property the milestone is for.
///
/// **What each one actually is.**
///
/// | Built-in | How it runs | Permit |
/// |---|---|---|
/// | Cut | the app's own ⌘X | yes — synthetic input into someone else's process |
/// | Copy | a kept clipboard write of text PappuClip already read | no — nothing is sent anywhere |
/// | Paste | the app's own ⌘V | yes |
/// | ⇧ Paste | `TextMutator`, holding the clipboard's plain text | yes |
/// | Search | `NSWorkspace`, one address | no |
/// | Open Link | `NSWorkspace`, one address per detection | no |
///
/// **Why Copy is not a ⌘C.** RUN-2a covers synthetic input, so a ⌘C would need a `MutationPermit`, and
/// `DestinationVerifier` mints one only for a destination that is *editable* (`.notEditable` fails both
/// tiers). Copy is offered wherever there is text — a web page, a PDF, a log — so a permit-shaped Copy
/// would be permanently broken in exactly the places people copy from most. Writing the text PappuClip
/// already has is not a second-best: it sends nothing into the other process, needs no verification,
/// cannot land in the wrong window, and in M1 produces the same thing a ⌘C would, because M1 has no
/// rich-text model at all (FLT-4 is M3). When it does, ⌘C-for-flavours arrives with it and with the ⇧
/// plain-text modifier that is the only way to tell the two apart.
///
/// **Not built here.** ⇧ Cut and ⇧ Copy — "plain text only" — wait on the same M3 work, and until then
/// the modifier is accepted and ignored rather than approximated. ⌘X already yields the app's own
/// flavours and nothing else could be honestly called plain-text-only without reading the clipboard
/// back and rewriting it, which is a transaction, a race and a lost clipboard away from the thing it
/// is trying to be.
public struct BuiltinRunner: Sendable {
    /// What one built-in run is given.
    ///
    /// Everything except `modifiers` is what the bar already resolved: the same `Match` `ActionResolver`
    /// produced, so a built-in acts on exactly what the pipeline said it acts on (§8.5 step 3).
    public struct Request: Sendable {
        public var invocation: InvocationID
        public var builtin: BuiltinAction
        public var match: ActionMatching.Match
        public var selection: AnalyzedSelection
        public var context: SelectionContext
        public var target: TargetApp
        /// The modifiers held when the action was chosen, whatever chose it — the bar's click, or a
        /// palette's return key (ALM-8).
        public var modifiers: PointerEvent.Modifiers

        public init(
            invocation: InvocationID,
            builtin: BuiltinAction,
            match: ActionMatching.Match,
            selection: AnalyzedSelection,
            context: SelectionContext,
            target: TargetApp,
            modifiers: PointerEvent.Modifiers = []
        ) {
            self.invocation = invocation
            self.builtin = builtin
            self.match = match
            self.selection = selection
            self.context = context
            self.target = target
            self.modifiers = modifiers
        }

        /// PRD §7.4: ⇧ is plain text, a background tab, or background tabs.
        public var isShifted: Bool { modifiers.contains(.shift) }
        /// PRD §7.4: ⌥ quotes the search term, or copies the addresses as a list.
        public var isOptioned: Bool { modifiers.contains(.option) }
    }

    /// How a built-in run ended. Codes only, as everywhere on this path.
    public enum Outcome: Sendable, Equatable {
        /// It did the thing. For the two that press a key, as close to that as RUN-4 allows: the
        /// keystroke went out and left the app's own trace and none of ours.
        case done
        /// RUN-2 said no. The block carries every rule that failed, for the explanation the bar owes
        /// the user (RUN-2e).
        case blocked(DestinationBlock)
        /// The run was cancelled, paused out or revoked before the effect (RUN-3b, RUN-3c).
        case notRunning
        /// It was asked for and did not happen: the events could not be posted, the browser refused the
        /// address, the clipboard was busy.
        case notPerformed
        /// There was nothing to act on — no text to copy, no address to open, an empty clipboard, a
        /// search template with no placeholder. Not a failure of the machinery, and named apart from
        /// one so that a diagnostic does not send anybody looking for a bug.
        case nothingToDo
    }

    /// One built-in run as the inspector will tell it (DIA-2, DIA-4).
    public struct Report: Sendable, Equatable {
        public let invocation: InvocationID
        public let builtin: BuiltinAction
        public let outcome: Outcome
        /// The keystroke's own account, for Cut and Paste.
        public let edit: EditReport?
        /// The mutation's own account, for ⇧ Paste.
        public let mutation: MutationReport?
        /// How many addresses were opened, for Search and Open Link.
        public let opened: Int
        /// The clipboard's own account, for Copy and ⌥ Open Link.
        public let clipboard: ClipboardWriteRecord?

        public var ran: Bool { outcome == .done }
        /// What stopped it, when RUN-2 did.
        public var block: DestinationBlock? {
            if case .blocked(let block) = outcome { return block }
            return nil
        }
    }

    private let manager: InvocationManager
    private let editor: SelectionEditor
    private let mutator: TextMutator
    private let clipboard: any ClipboardKeeping
    private let urls: any URLOpening
    private let engines: SearchEngines
    private let search: SearchPreference

    public init(
        manager: InvocationManager,
        editor: SelectionEditor,
        mutator: TextMutator,
        clipboard: any ClipboardKeeping,
        urls: any URLOpening,
        engines: SearchEngines = .fallback,
        search: SearchPreference = SearchPreference()
    ) {
        self.manager = manager
        self.editor = editor
        self.mutator = mutator
        self.clipboard = clipboard
        self.urls = urls
        self.engines = engines
        self.search = search
    }

    /// Runs one built-in and ends its invocation.
    ///
    /// The invocation is always finished here — with `completed`, `blocked` or `failed` — except when
    /// it was already invalidated, which is the one case where there is nothing left to finish
    /// (RUN-3c). A caller that begins a run therefore does not have to remember to end it.
    public func run(_ request: Request) async -> Report {
        switch request.builtin {
        case .cut: await edit(.cut, request)
        case .paste: await paste(request)
        case .copy: await copy(request)
        case .search: await performSearch(request)
        case .openLink: await openLink(request)
        }
    }

    // MARK: The two that press a key

    private func edit(_ command: EditCommand, _ request: Request) async -> Report {
        let verification = await manager.verifyDestination(of: request.invocation)
        switch consume verification {
        case .blocked(let block):
            return await finish(request, .blocked(block))
        case .verified(let permit):
            let report = await editor.post(command, using: permit)
            let outcome: Outcome = switch report.outcome {
            case .posted: .done
            case .notRunning: .notRunning
            case .notPosted: .notPerformed
            }
            return await finish(request, outcome, edit: report)
        }
    }

    private func paste(_ request: Request) async -> Report {
        guard request.isShifted else { return await edit(.paste, request) }

        // ⇧ Paste is the one built-in that writes text rather than asking the app to: to paste *as
        // plain* the clipboard's rich flavours have to be left behind, and the only way to leave them
        // behind is to hold the plain text ourselves for the length of one ⌘V (`TextMutator`).
        guard let text = await clipboard.plainText(), !text.isEmpty else {
            // The clipboard emptied, or turned into something with no text, between the bar appearing
            // and the click. `BuiltinConditions.clipboardHasText` is what normally keeps Paste off the
            // bar; this is the same answer a moment later.
            return await finish(request, .nothingToDo)
        }

        let verification = await manager.verifyDestination(of: request.invocation)
        switch consume verification {
        case .blocked(let block):
            return await finish(request, .blocked(block))
        case .verified(let permit):
            let report = await mutator.replaceSelection(with: text, using: permit)
            let outcome: Outcome = switch report.outcome {
            case .mutated: .done
            case .notRunning: .notRunning
            case .clipboardRefused: .notPerformed
            // The ⌘V went out and somebody else wrote while our text was up. The paste most likely
            // landed, so the run completed; what did not is the clipboard's restoration, and
            // `MutationReport.clipboard` is where that is said.
            case .clipboardContested: .done
            }
            return await finish(request, outcome, mutation: report)
        }
    }

    // MARK: The three that do not

    private func copy(_ request: Request) async -> Report {
        let text = request.match.value
        guard !text.isEmpty else { return await finish(request, .nothingToDo) }

        let result = await clipboard.write(text, for: request.invocation, into: request.target)
        // No permit, and no liveness check either: a cancelled run has nothing to take back off the
        // clipboard, and `manager.finish` below already answers false for one.
        return await finish(
            request,
            result.written ? .done : .notPerformed,
            clipboard: result.record
        )
    }

    private func performSearch(_ request: Request) async -> Report {
        let term = request.isOptioned ? "\"\(request.match.value)\"" : request.match.value
        guard !term.isEmpty else { return await finish(request, .nothingToDo) }
        // A template with no placeholder cannot take the selection, so there is no search to run — the
        // same judgement `SearchPreference.engine(in:)` makes about a custom URL, one step further on.
        guard let engine = search.engine(in: engines), let url = engine.url(searching: term) else {
            return await finish(request, .nothingToDo)
        }

        let opened = await urls.open([open(url, for: request)])
        return await finish(request, opened == 1 ? .done : .notPerformed, opened: opened)
    }

    private func openLink(_ request: Request) async -> Report {
        let addresses = self.addresses(in: request)
        guard !addresses.isEmpty else { return await finish(request, .nothingToDo) }

        // ⌥: the addresses as a list, one to a line, and nothing opened. The list is what the user
        // would have typed out by hand, which is why it is the normalised values and not the substrings
        // — a bare `example.com` in the selection is `https://example.com` here, because that is the
        // address it means.
        guard !request.isOptioned else {
            let result = await clipboard.write(
                addresses.map(\.absoluteString).joined(separator: "\n"),
                for: request.invocation,
                into: request.target
            )
            return await finish(
                request,
                result.written ? .done : .notPerformed,
                clipboard: result.record
            )
        }

        let opened = await urls.open(addresses.map { open($0, for: request) })
        // Partly opened is still opened: three tabs asked for and two given is not a run that failed,
        // and the count is in the report for anyone who needs the difference.
        return await finish(request, opened > 0 ? .done : .notPerformed, opened: opened)
    }

    /// Every address Open Link acts on, in the order they appear in the selection.
    ///
    /// The `urls` requirement does not narrow (§8.5 step 3), so the ordinary answer is all of them. A
    /// manifest that asked for `url` or `isurl` instead narrowed to one, and that one is what it gets:
    /// the runner follows the pipeline rather than second-guessing it.
    private func addresses(in request: Request) -> [URL] {
        if request.match.narrowing == .url {
            return [request.match.value].compactMap(URL.init(string:))
        }
        return request.selection.detections
            .filter { $0.kind == .url || $0.kind == .nonHTTPURL }
            .compactMap { URL(string: $0.value) }
    }

    /// PRD §7.4's browser rule, and ⇧.
    private func open(_ url: URL, for request: Request) -> URLOpenRequest {
        URLOpenRequest(
            url: url,
            activates: !request.isShifted,
            // "…open in the current app if it is a known browser, otherwise in the default browser."
            // A browser page is exactly what `ContextProbe` answering with one means: it found an
            // `AXWebArea` in the app in front, which no non-browser has.
            browserBundleID: request.context.browser == nil ? nil : request.context.app.bundleID
        )
    }

    // MARK: Ending

    private func finish(
        _ request: Request,
        _ outcome: Outcome,
        edit: EditReport? = nil,
        mutation: MutationReport? = nil,
        opened: Int = 0,
        clipboard: ClipboardWriteRecord? = nil
    ) async -> Report {
        switch outcome {
        case .done:
            await manager.finish(request.invocation, outcome: .completed)
        case .blocked:
            // RUN-2c's word: the effect could not be applied where it came from. In M1 the bar has
            // nothing to offer instead; BAR-17's explicit copy is M4.
            await manager.finish(request.invocation, outcome: .blocked)
        case .notPerformed, .nothingToDo:
            await manager.finish(request.invocation, outcome: .failed)
        case .notRunning:
            // Already cancelled, paused or revoked: the manager let go of it then, and finishing it now
            // would only answer false.
            break
        }
        return Report(
            invocation: request.invocation,
            builtin: request.builtin,
            outcome: outcome,
            edit: edit,
            mutation: mutation,
            opened: opened,
            clipboard: clipboard
        )
    }
}

extension BuiltinAction {
    /// Whether a run of this built-in can end in host-controlled input reaching the destination, and so
    /// whether its `InvocationRequest` says `mayMutate` (RUN-2a, RUN-2g).
    ///
    /// This is the table in `BuiltinRunner`'s documentation, as the one line of code that reads it. It
    /// decides two things at `begin`, before anything runs: whether the key tap is held for the length
    /// of the run so that the quiescence tier is reachable, and whether a `MutationPermit` will be
    /// asked for at all. Getting it wrong in the safe direction costs a tap nobody needed; getting it
    /// wrong in the other means a synthetic keystroke with no verification behind it, which is the one
    /// thing RUN-2 exists to prevent.
    ///
    /// Copy says false and it is not an oversight — see `BuiltinRunner`'s "Why Copy is not a ⌘C". It
    /// writes text PappuClip already read and sends nothing into the other process.
    public var mayMutateTheDestination: Bool {
        switch self {
        case .cut, .paste: true
        case .copy, .search, .openLink: false
        }
    }
}
