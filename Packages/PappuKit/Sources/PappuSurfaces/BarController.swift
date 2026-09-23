import CoreGraphics
import Foundation
import PappuCore
import PappuSelection
import Synchronization
import os

/// What the bar shows, as the user has set it up. The settings screen that writes it is M1 week 5, and
/// the two P1 fields — the other colour modes and the size slider — are BAR-8b in M4.
public struct BarSettings: Sendable, Equatable {
    public var position: BarPosition
    public var colorPreference: BarColorPreference
    public var metrics: BarMetrics

    public init(
        position: BarPosition = .aboveText,
        colorPreference: BarColorPreference = .system,
        metrics: BarMetrics = .standard
    ) {
        self.position = position
        self.colorPreference = colorPreference
        self.metrics = metrics
    }
}

/// An `AppearancePermit`'s codes, once the permit has been consumed.
///
/// The permit is `~Copyable` and cannot cross to the main actor, which is exactly what it is for: it is
/// spent at the boundary, here, and what continues is a record of what it said.
public struct BarGrant: Sendable, Equatable {
    public var attempt: AttemptID
    public var route: ActivationRoute
    public var target: TargetApp
    public var remaining: Duration

    public init(_ permit: consuming AppearancePermit) {
        self.attempt = permit.attempt
        self.route = permit.route
        self.target = permit.target
        self.remaining = permit.remaining
    }

    /// For a caller that has no permit to spend: the tests, and M4's palette, which shows the same bar
    /// from a route of its own.
    public init(attempt: AttemptID, route: ActivationRoute, target: TargetApp, remaining: Duration) {
        self.attempt = attempt
        self.route = route
        self.target = target
        self.remaining = remaining
    }
}

/// Why a bar did not appear although the coordinator minted a permit for it. For the inspector (DIA-2).
public enum BarRefusal: String, Sendable, Codable, CaseIterable {
    /// The permit arrived with none of the hard cutoff left (ACT-16b, PRD §11.1).
    case outOfBudget
    /// Nothing resolved for this selection, so there is no bar to show (FLT-1).
    case noActions
    /// The display is too narrow for even one button.
    case noRoom
}

/// The bar: what it holds, where it goes, which key belongs to it and when it goes away.
///
/// It is the main-actor end of the auto-appear timeline (architecture §4.7) and the one implementation
/// of `BarPresenting`. Everything it decides is decided in a value type next door — `BarLayout`,
/// `BarKeyboardMode`, `BarDismissal`, `BarFeedback`, `BarAppearance` — and what is left here is the
/// wiring: consume the permit, ask for content, place it, take the key tap, and give it all back.
///
/// **Two isolation domains, on purpose.** The tap handlers run on the tap's own thread and must answer
/// at once — a key tap that waits for the main actor is a key tap macOS switches off (ACT-15). So the
/// small part of the state the taps need is in a `Mutex`, the handlers advance it and return a
/// disposition, and the main actor catches up afterwards. The mutex also closes the race the other way
/// round: a dismissal marks the bar down in the same locked step that decides it, so a key arriving
/// behind it finds no bar and passes through.
@MainActor
public final class BarController: BarPresenting {
    private struct Live {
        var isUp = false
        var attempt: AttemptID?
        /// Top-left screen coordinates, for `BarDismissal`'s hit test.
        var frame: CGRect = .null
        var keyboard = BarKeyboardMode(itemCount: 0)
    }

    private struct Shown {
        var grant: BarGrant
        var presentation: AttemptPresentation
        var content: BarContent
        var placement: BarPlacement
        /// Where the bar is now, when a result has moved it off `placement` (BAR-12b).
        var resized: BarPlacement?
    }

    private let window: any BarWindowing
    private let contentProvider: any BarContentProviding
    private let invoker: any BarActionInvoking
    private let screenSource: any BarScreenSource
    private let appearanceSource: any SystemAppearanceReading
    private let measurer: any BarMeasuring
    private let keyLeasing: any BarKeyLeasing

    private let live = Mutex(Live())
    private var shown: Shown?
    private var feedback = BarFeedback()
    private var keyLease: (any InputWatch)?

    public var settings: BarSettings

    /// For the inspector and the tests: what the last appearance did, and what took it away.
    public private(set) var lastRefusal: BarRefusal?
    public private(set) var lastDismissal: BarDismissalReason?

    public init(
        window: any BarWindowing,
        content: any BarContentProviding,
        invoker: any BarActionInvoking,
        screens: any BarScreenSource,
        appearance: any SystemAppearanceReading,
        measurer: any BarMeasuring,
        keys: any BarKeyLeasing,
        settings: BarSettings = BarSettings()
    ) {
        self.window = window
        self.contentProvider = content
        self.invoker = invoker
        self.screenSource = screens
        self.appearanceSource = appearance
        self.measurer = measurer
        self.keyLeasing = keys
        self.settings = settings
        self.window.events = self
    }

    /// Build the panel before any bar needs it (PRD §11.1).
    public func prepare() {
        window.prepare()
    }

    public var isShowing: Bool { shown != nil }
    public var feedbackState: BarFeedbackState { feedback.state }
    public var highlighted: Int? { live.withLock { $0.keyboard.highlighted } }

    // MARK: BarPresenting

    public nonisolated func show(_ presentation: AttemptPresentation, permit: consuming AppearancePermit) async {
        let grant = BarGrant(consume permit)
        await show(presentation, grant: grant)
    }

    /// The same appearance, from a grant that has already been taken out of its permit. This is the
    /// whole of `show` — the permit version does nothing but spend the permit — so a test drives this
    /// one and misses only that single line.
    public func show(_ presentation: AttemptPresentation, grant: BarGrant) async {
        let state = Self.signposter.beginInterval("bar.render", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("bar.render", state) }

        // What is left of the hard cutoff is what the render stage has. None left is not a late bar; it
        // is no bar (ACT-16b).
        guard grant.remaining > .zero else { return refuse(.outOfBudget) }

        let resolved = await contentProvider.content(for: presentation)
        guard !resolved.isEmpty else { return refuse(.noActions) }

        let widths = measurer.widths(for: resolved, metrics: settings.metrics)
        guard let placement = BarLayout.place(
            anchor: BarAnchor(presentation),
            itemWidths: widths,
            preference: settings.position,
            metrics: settings.metrics,
            screens: screenSource.screens()
        ), placement.itemsThatFit > 0 else { return refuse(.noRoom) }

        // Anything past what fits belongs to a further page, which is BAR-5a in M4.
        let content = BarContent(items: Array(resolved.items.prefix(placement.itemsThatFit)))
        let appearance = BarAppearance.resolve(appearanceSource.currentAppearance(), preference: settings.colorPreference)

        feedback.reset()
        lastRefusal = nil
        shown = Shown(grant: grant, presentation: presentation, content: content, placement: placement)
        window.show(content, placement: placement, appearance: appearance, metrics: settings.metrics)

        // ACT-6a: the shortcut opens compact keyboard mode; a gesture does not, so that ← and → stay
        // the app's own until the user asks the bar for them.
        let keyboard = BarKeyboardMode(itemCount: content.count, route: grant.route)
        window.highlight(keyboard.highlighted)
        live.withLock {
            $0.isUp = true
            $0.attempt = grant.attempt
            $0.frame = placement.windowFrame(metrics: settings.metrics)
            $0.keyboard = keyboard
        }

        // ACT-19: the key tap exists for exactly as long as this bar does.
        keyLease = keyLeasing.leaseKeys { [weak self] press in
            self?.handle(press) ?? .pass
        }
        window.announce(BarStrings.barAppeared)
    }

    private func refuse(_ refusal: BarRefusal) {
        lastRefusal = refusal
        if shown != nil { dismiss(.attemptRetired) }
    }

    // MARK: Keys (tap thread)

    private nonisolated func handle(_ press: KeyPress) -> TapDisposition {
        let key = BarKey(press)
        let outcome = live.withLock { live -> BarKeyOutcome in
            guard live.isUp else { return .ignored }
            let outcome = live.keyboard.press(key)
            // Marked down here, inside the lock, so that a second key arriving before the main actor
            // has hidden anything finds no bar and goes to the app.
            if outcome.dismisses { live.isUp = false }
            return outcome
        }
        if outcome != .ignored {
            Task { @MainActor [weak self] in self?.apply(outcome) }
        }
        return outcome.disposition
    }

    private func apply(_ outcome: BarKeyOutcome) {
        guard let shown else { return }
        switch outcome {
        case .moved(let index):
            // BAR-9a: the name goes with the highlight. On screen that is the tooltip; for somebody
            // listening it has to be said, or an icon-only bar is a row of unnamed things.
            window.highlight(index)
            if index < shown.content.items.count { window.announce(shown.content.items[index].name) }
        case .run(let index):
            guard index < shown.content.items.count else { return dismiss(.escape) }
            press(shown.content.items[index].id, modifiers: [], source: .keyboard)
        case .dismissed:
            dismiss(.escape)
        case .dismissedAndPassedOn:
            dismiss(.ordinaryKey)
        case .ignored:
            break
        }
    }

    // MARK: Pointer (tap thread)

    /// The mouse tap's half of BAR-10. The tap never consumes, so this returns nothing.
    public nonisolated func pointer(_ event: PointerEvent) {
        let reason = live.withLock { live -> BarDismissalReason? in
            guard live.isUp, let reason = BarDismissal.reason(for: event, barFrame: live.frame) else { return nil }
            live.isUp = false
            return reason
        }
        guard let reason else { return }
        Task { @MainActor [weak self] in self?.dismiss(reason) }
    }

    /// ACT-16a from outside: the attempt this bar belongs to is no longer the current one.
    public nonisolated func invalidate(_ attempt: AttemptID) {
        let matches = live.withLock { live -> Bool in
            guard live.isUp, live.attempt == attempt else { return false }
            live.isUp = false
            return true
        }
        guard matches else { return }
        Task { @MainActor [weak self] in self?.dismiss(.attemptRetired) }
    }

    /// Pause, a hard block or secure input arriving while a bar is up (ACT-12, ACT-17a, ACT-18).
    public nonisolated func privacyStateChanged() {
        let wasUp = live.withLock { live -> Bool in
            defer { live.isUp = false }
            return live.isUp
        }
        guard wasUp else { return }
        Task { @MainActor [weak self] in self?.dismiss(.privacyState) }
    }

    // MARK: BarWindowEvents

    public func barPressed(_ item: BarItemID, modifiers: PointerEvent.Modifiers) {
        press(item, modifiers: modifiers, source: .mouse)
    }

    private func press(_ item: BarItemID, modifiers: PointerEvent.Modifiers, source: BarClick.Source) {
        guard let shown else { return }

        // RUN-3: while something is running, a press is "stop", not "run something else".
        if feedback.state.isCancellable {
            Task { [invoker] in await invoker.cancelRunningAction() }
            change(to: .idle)
            return
        }
        // A tick, a word or a result is on screen instead of the buttons, and Return on the key that
        // was highlighted before it appeared is not a choice of anything the user can see.
        guard feedback.state.showsButtons else { return }
        guard let entry = shown.content.items.first(where: { $0.id == item }), entry.isEnabled else { return }

        let click = BarClick(item: item, modifiers: modifiers, source: source)
        change(to: .running(cancellable: true))
        let presentation = shown.presentation
        Task { [invoker] in await invoker.invoke(click, for: presentation) }
    }

    /// What an invocation reports back (BAR-12a). `InvocationManager` is M1 week 5; until then a test
    /// is the caller.
    public func report(_ state: BarFeedbackState) {
        guard shown != nil else { return }
        change(to: state)
    }

    private func change(to state: BarFeedbackState) {
        let announcement = feedback.change(to: state)
        let appearance = BarAppearance.resolve(appearanceSource.currentAppearance(), preference: settings.colorPreference)
        resize(for: state, appearance: appearance)
        window.present(state, motion: state.motion(under: appearance))
        if let announcement { window.announce(announcement) }
    }

    /// BAR-12b: a result gets the bar's width, measured and capped, in place of the buttons' — placed
    /// by the same rules against the same selection, so it points where the buttons pointed. The
    /// buttons' own placement comes back if the bar returns to them.
    private func resize(for state: BarFeedbackState, appearance: BarAppearance) {
        guard var shown else { return }
        let placement: BarPlacement
        switch state {
        case .result(let text):
            let width = min(measurer.width(ofResult: text, metrics: settings.metrics), settings.metrics.resultMaximumWidth)
            guard let fitted = BarLayout.place(
                anchor: BarAnchor(shown.presentation),
                itemWidths: [width],
                preference: settings.position,
                metrics: settings.metrics,
                screens: screenSource.screens()
            ) else { return }
            placement = fitted
            shown.resized = fitted
        case .idle where shown.resized != nil:
            placement = shown.placement
            shown.resized = nil
        default:
            return
        }
        self.shown = shown
        window.show(shown.content, placement: placement, appearance: appearance, metrics: settings.metrics)
        let frame = placement.windowFrame(metrics: settings.metrics)
        live.withLock { $0.frame = frame }
    }

    // MARK: Going away

    public func dismiss(_ reason: BarDismissalReason) {
        lastDismissal = reason
        live.withLock {
            $0.isUp = false
            $0.attempt = nil
            $0.frame = .null
            $0.keyboard = BarKeyboardMode(itemCount: 0)
        }
        keyLease?.stop()
        keyLease = nil
        feedback.reset()
        shown = nil
        window.hide()
    }

    private static let signposter = OSSignposter(subsystem: ProductIdentity.logSubsystem, category: "bar")
}

extension BarController: BarWindowEvents {}
