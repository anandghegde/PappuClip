import CoreGraphics
import PappuAX
import PappuCore

/// The mouse-down pre-work of architecture §4.3, and the Accessibility half of ACT-12 and ACT-14.
///
/// Two calls, in this order, because the gate goes between them:
///
/// 1. `focus(in:at:)` reads structure — the focused element's role, and the role under the pointer. It
///    needs no `ReadPermit`, because a role is not the user's text and because `PrivacyGate` cannot
///    judge ACT-12 until somebody has looked.
/// 2. `baselineRange(_:)` reads where the selection is, once the gate has passed. It spends a permit, and
///    it reads the range of the element step 1 found — the element the gate was told about — which is why
///    the permit alone says which app to look at.
///
/// Both are bounded by `AXUIElementSetMessagingTimeout`, so a wedged app costs one timeout on this actor's
/// queue and nothing on any other.
@AXActor
public final class AXFocusProbe {
    private let world: any AXWorld
    private let budgets: BudgetTable

    /// The element the last probe found, and the process it belongs to. It stays here rather than going
    /// out in `AXFocus`, so an `AXUIElement` never leaves this actor, and so the only element a baseline
    /// read can reach is the one the gate judged.
    private var focused: (pid: pid_t, element: AXElement)?

    public init(world: any AXWorld = SystemAXWorld(), budgets: BudgetTable = .initial) {
        self.world = world
        self.budgets = budgets
    }

    /// - Parameters:
    ///   - point: The mouse-down location in global coordinates with a top-left origin, as
    ///     `PointerEvent.location` gives it. Nil for the routes that have no pointer (ACT-5, SCR-1, SCR-2).
    ///   - timeout: Defaults to the read stage's budget on the Accessibility path (PRD §11.1).
    public func focus(in target: TargetApp, at point: CGPoint? = nil, timeout: Duration? = nil) -> AXFocus {
        let application = application(for: target.pid, timeout: timeout)
        var result = AXFocus()

        switch world.attribute(.focusedUIElement, of: application) {
        case .success(let value):
            if let element = value.asElement {
                world.setMessagingTimeout(budgets.messagingTimeout(timeout), on: element)
                focused = (target.pid, element)
                result.hasFocusedElement = true
                let probed = role(of: element)
                result.focused = probed.role
                result.fault = probed.fault
            } else {
                forget(target.pid)
                result.fault = .unsupported
            }
        case .failure(let fault):
            forget(target.pid)
            result.fault = fault
        }

        if let point {
            switch world.element(at: point, in: application) {
            case .success(let element):
                world.setMessagingTimeout(budgets.messagingTimeout(timeout), on: element)
                let probed = role(of: element)
                result.underPointer = probed.role
                if result.fault == nil { result.fault = probed.fault }
            case .failure(let fault):
                if result.fault == nil { result.fault = fault }
            }
        }

        return result
    }

    /// ACT-14's baseline: where the selection was before the gesture, as a range and never as text.
    ///
    /// Spends the permit that proves §S1 passed. Either scope will do — a location and a length cannot
    /// carry what is on the page, and the point of the baseline is to *withhold* a bar that no selection
    /// justifies.
    ///
    /// - Returns: `.failure(.unsupported)` when no probe has found a focused element in that process,
    ///   which is also the answer for an app that has no Accessibility tree to ask.
    public func baselineRange(
        _ permit: consuming ReadPermit,
        timeout: Duration? = nil
    ) -> Result<AXTextRange, AXFault> {
        let pid = permit.target.pid
        guard let focused, focused.pid == pid else { return .failure(.unsupported) }
        return world.attribute(.selectedTextRange, of: focused.element).flatMap { value in
            guard let range = value.asRange else { return .failure(.unsupported) }
            return .success(range)
        }
    }

    /// Drops the remembered element, so a later permit cannot spend a baseline read on a process whose
    /// focus we have since failed to find.
    public func forget(_ pid: pid_t) {
        if focused?.pid == pid { focused = nil }
    }

    // MARK: Plumbing

    private func application(for pid: pid_t, timeout: Duration?) -> AXElement {
        let application = world.application(pid: pid)
        world.setMessagingTimeout(budgets.messagingTimeout(timeout), on: application)
        return application
    }

    /// - Returns: The role, and why it is missing when it is. An absent subrole is the ordinary case and
    ///   never a fault worth reporting, so only a failure to read the role itself comes back.
    private func role(of element: AXElement) -> (role: AXRole?, fault: AXFault?) {
        var roleFault: AXFault?
        func string(_ attribute: AXAttribute) -> String? {
            switch world.attribute(attribute, of: element) {
            case .success(let value):
                return value.asString
            case .failure(let fault):
                if attribute == .role { roleFault = fault }
                return nil
            }
        }
        let role = AXRole(role: string(.role), subrole: string(.subrole))
        guard role.role != nil || role.subrole != nil else { return (nil, roleFault) }
        return (role, roleFault)
    }
}
