import CoreGraphics
import PappuAX
import PappuCore

/// The Accessibility reads of ACT-9: strategy 1, and strategy 3, which is strategy 1 with a switch
/// thrown first (architecture §4.5).
///
/// One body serves both, because that is what strategy 3 *is* — "enable the Chromium or Electron tree,
/// then read as for strategy 1" — and writing it twice would be two places for the read to drift.
///
/// `@AXActor`, so it shares the one serial queue with `AXFocusProbe`: a wedged app costs a timeout on
/// that queue and nothing anywhere else. Every call it makes is bounded by
/// `AXUIElementSetMessagingTimeout` from the read stage's budget.
///
/// **What it does not read.** A caret is answered from the range alone — an empty `AXSelectedTextRange`
/// is a caret by definition (ACT-3) — so the attribute that holds the user's text is never asked for in
/// the case where there is no selection to read. That is a round trip saved and, more to the point, a
/// read of somebody's document not made.
@AXActor
public final class AXSelectionReader {
    private let world: any AXWorld
    private let budgets: BudgetTable

    /// The processes whose Accessibility tree we have switched on, and with which attributes.
    ///
    /// Enable-and-hold rather than enable-per-read: the switch is a message to another process about
    /// itself, and sending it before every read is both slower and ruder. Which of the two M0 spike 4
    /// says is safe per app is the spike's to answer; until it has, holding is the cheaper default and
    /// `release(_:)` is how the app puts an app back the way it found it.
    private var switchedOn: [pid_t: AXTreeEnabling] = [:]

    public init(world: any AXWorld = SystemAXWorld(), budgets: BudgetTable = .initial) {
        self.world = world
        self.budgets = budgets
    }

    /// Strategy 1: `AXSelectedText` and friends on the focused element.
    ///
    /// - Parameter timeout: Defaults to the read stage's budget on the Accessibility path (PRD §11.1).
    public func read(in target: TargetApp, timeout: Duration? = nil) -> StrategyRead {
        read(in: target, timeout: timeout, carrying: nil)
    }

    /// Strategy 3: switch the app's Accessibility tree on, then read it.
    ///
    /// The read runs even when every switch faulted, and that is deliberate. An app that answers
    /// `.unsupported` to `AXManualAccessibility` may have had its tree on all along — a second copy of
    /// PappuClip, a screen reader, or the user's own setting — and the fault is carried into the trace
    /// rather than turned into a refusal the inspector would have to explain away. One round trip is
    /// what that costs in the case where the app really has nothing to switch on.
    public func read(
        enabling: AXTreeEnabling,
        in target: TargetApp,
        timeout: Duration? = nil
    ) -> StrategyRead {
        var fault: AXFault?
        if switchedOn[target.pid] != enabling {
            let application = application(for: target.pid, timeout: timeout)
            var wrote = false
            for which in enabling.switches {
                switch world.setTree(which, to: true, of: application) {
                case .success:
                    wrote = true
                case .failure(let failure):
                    if fault == nil { fault = failure }
                }
            }
            // Only a switch that was taken is remembered, so a later attempt tries again rather than
            // believing a tree is on because we once asked.
            if wrote { switchedOn[target.pid] = enabling }
        }
        return read(in: target, timeout: timeout, carrying: fault)
    }

    /// Switches a tree we turned on back off, and forgets it.
    ///
    /// The app calls this when a process quits and when PappuClip does, so that nothing we did to
    /// another program outlives us. A switch that cannot be written back is dropped from the map all the
    /// same: the process is usually gone, which is the commonest reason the write fails.
    @discardableResult
    public func release(_ pid: pid_t) -> Bool {
        guard let enabling = switchedOn.removeValue(forKey: pid) else { return false }
        let application = world.application(pid: pid)
        world.setMessagingTimeout(budgets.messagingTimeout(), on: application)
        for which in enabling.switches {
            _ = world.setTree(which, to: false, of: application)
        }
        return true
    }

    public func releaseAll() {
        for pid in switchedOn.keys { release(pid) }
    }

    /// Whether this process's tree is one we switched on. For the inspector, and for the tests that
    /// assert the switch is written once and not once per attempt.
    public func isTreeSwitchedOn(for pid: pid_t) -> Bool { switchedOn[pid] != nil }

    // MARK: The read

    private func read(in target: TargetApp, timeout: Duration?, carrying carried: AXFault?) -> StrategyRead {
        let seconds = budgets.messagingTimeout(timeout)
        let application = application(for: target.pid, timeout: timeout)

        let element: AXElement
        switch world.attribute(.focusedUIElement, of: application) {
        case .success(let value):
            guard let focused = value.asElement else {
                return StrategyRead(finding: .unavailable, fault: carried ?? .unsupported)
            }
            element = focused
        case .failure(let fault):
            // No focused element is not "there is no selection": it is this strategy having nothing to
            // read from, which is what lets the chain go on to the next one.
            return StrategyRead(finding: .unavailable, fault: carried ?? fault)
        }
        world.setMessagingTimeout(seconds, on: element)

        var fault = carried
        let range: AXTextRange?
        switch world.attribute(.selectedTextRange, of: element) {
        case .success(let value):
            range = value.asRange
            if range == nil, fault == nil { fault = .unsupported }
        case .failure(let failure):
            // An app that will not say where its selection is can still be asked what it is, and several
            // do exactly that. The length of what comes back is then the only evidence there is.
            range = nil
            if fault == nil { fault = failure }
        }

        // ACT-3: an empty range is a caret and nothing else, and a caret has no text to ask for.
        if let range, range.isEmpty {
            return StrategyRead(finding: .caret, range: range, fault: fault)
        }

        let text: String?
        switch world.attribute(.selectedText, of: element) {
        case .success(let value):
            text = value.asString
            if text == nil, fault == nil { fault = .unsupported }
        case .failure(let failure):
            text = nil
            if fault == nil { fault = failure }
        }

        guard let text, !text.isEmpty else {
            // The range comes back on an empty finding on purpose: an app that says forty characters are
            // selected and will not hand them over has told strategy 5 what to expect (ACT-10e).
            return StrategyRead(finding: .nothing, range: range, fault: fault)
        }
        return StrategyRead(finding: .text, text: text, range: range, bounds: bounds(of: range, in: element), fault: fault)
    }

    /// BAR-3's rectangle, or nil and then the bar goes to the pointer.
    ///
    /// Asked for directly rather than through `supports` first, because two round trips to a slow app
    /// cost twice one and an app that does not offer the attribute answers `.unsupported` to the value
    /// call just as clearly as to the names call. A degenerate rectangle — a zero size, or the null or
    /// infinite rectangle some apps answer with for a selection that is scrolled out of view — is no
    /// answer, and the pointer is a better one than a bar in the corner of the screen.
    private func bounds(of range: AXTextRange?, in element: AXElement) -> CGRect? {
        guard let range, !range.isEmpty else { return nil }
        guard let rect = (try? world.value(.boundsForRange, for: range, of: element).get())?.asRect else {
            return nil
        }
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private func application(for pid: pid_t, timeout: Duration?) -> AXElement {
        let application = world.application(pid: pid)
        world.setMessagingTimeout(budgets.messagingTimeout(timeout), on: application)
        return application
    }
}
