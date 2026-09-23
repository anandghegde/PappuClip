import Foundation
import PappuAX
import PappuCore

/// `DestinationProbing` against a live Accessibility tree (architecture §8.2).
///
/// It is `@AXActor` for the reason everything that touches AX is: every call blocks until the app on
/// the other end answers or the messaging timeout expires, so they all share one queue of their own
/// (architecture §14). It is also where the invocation's elements live, for the reason
/// `AXFocusProbe`'s do: an `AXUIElement` never leaves this actor, so the only element a verification
/// can reach is the one the invocation captured.
///
/// Unlike `AXFocusProbe`, which remembers one element per process and forgets it at the next probe,
/// this holds one pair per invocation and holds it for as long as the invocation lives. Two
/// invocations can be in flight at once — a slow translation in Notes and a quick Copy somewhere else
/// — and each has to compare against its own destination.
@AXActor
public final class AXDestinationProbe: DestinationProbing {
    private let world: any AXWorld
    private let budgets: BudgetTable

    private struct Captured {
        var pid: pid_t
        var element: AXElement?
        var window: AXElement?
    }

    private var captured: [DestinationHandle: Captured] = [:]
    private var lastHandle: UInt64 = 0

    public init(world: any AXWorld = SystemAXWorld(), budgets: BudgetTable = .initial) {
        self.world = world
        self.budgets = budgets
    }

    /// Takes hold of the focused window and element of `target`.
    ///
    /// - Returns: Nil when neither could be read. There is then nothing for the Accessibility tier to
    ///   compare against, and the invocation's ceiling is the quiescence tier — which is the whole
    ///   reason that tier exists (safety spec §S3).
    public func capture(_ target: TargetApp) -> DestinationHandle? {
        let application = application(for: target.pid)
        let element = world.attribute(.focusedUIElement, of: application).value?.asElement
        let window = world.attribute(.focusedWindow, of: application).value?.asFirstElement
        guard element != nil || window != nil else { return nil }
        for held in [element, window] where held != nil {
            world.setMessagingTimeout(seconds(budgets.budget(for: .read, on: .accessibility)), on: held!)
        }
        lastHandle += 1
        let handle = DestinationHandle(rawValue: lastHandle)
        captured[handle] = Captured(pid: target.pid, element: element, window: window)
        return handle
    }

    /// Looks at the destination now and reports what it finds, field by field (RUN-2).
    ///
    /// It judges nothing: which tier this adds up to is `DestinationVerifier`'s to decide, and the
    /// only thing decided here is what can be seen.
    public func look(
        for handle: DestinationHandle?,
        in target: TargetApp,
        frontmost: TargetApp?,
        permit: consuming ReadPermit
    ) -> DestinationEvidence {
        var evidence = DestinationEvidence()
        evidence.isFrontmost = frontmost.map { $0.pid == target.pid }

        // The permit is spent on the selection read below. Taking the target from it rather than from
        // the parameter is what makes "this permit is for this app" structural rather than remembered.
        let pid = permit.target.pid
        guard let handle, let held = captured[handle], held.pid == pid, pid == target.pid else {
            return evidence
        }

        let application = application(for: pid)
        if let window = held.window {
            switch world.attribute(.focusedWindow, of: application) {
            case .success(let value):
                evidence.sameWindow = value.asFirstElement.map { world.isSame(window, as: $0) } ?? false
            case .failure(let fault):
                // The app answered a focused window when the invocation began and will not now. That
                // is a change, but not one we can describe, so it stays `nil` and the fault says why.
                evidence.fault = fault
            }
        }

        guard let element = held.element else { return evidence }

        switch world.attribute(.focusedUIElement, of: application) {
        case .success(let value):
            evidence.sameElement = value.asElement.map { world.isSame(element, as: $0) } ?? false
        case .failure(let fault):
            if evidence.fault == nil { evidence.fault = fault }
            return evidence
        }

        evidence.isEditable = editability(of: element, fault: &evidence.fault)
        if case .success(let value) = world.attribute(.selectedTextRange, of: element) {
            evidence.range = value.asRange
        }
        if case .success(let value) = world.attribute(.selectedText, of: element), let text = value.asString {
            evidence.text = TextDigest(text)
        }
        return evidence
    }

    public func release(_ handle: DestinationHandle) {
        captured[handle] = nil
    }

    /// How many destinations are being held. For the leak test: an invocation that ends releases
    /// its elements, and a manager that forgets to would show up here.
    public var heldCount: Int { captured.count }

    // MARK: Plumbing

    /// Whether the user can type here, strictly.
    ///
    /// `ContextProbe` decides editability for the bar and is allowed to guess from the role when
    /// nothing else answers, because the cost of being wrong there is a Paste button that does
    /// nothing. Here the cost of being wrong is text pasted into something that is not a text field,
    /// so the guess is not taken: the app's own answer, then WebKit's and Chromium's editable
    /// ancestor, then nothing.
    private func editability(of element: AXElement, fault: inout AXFault?) -> Bool? {
        switch world.isSettable(.selectedText, of: element) {
        case .success(true):
            return true
        case .success(false):
            if case .success(let value) = world.attribute(.editableAncestor, of: element),
               value.asElement != nil {
                return true
            }
            return false
        case .failure(let error):
            if fault == nil { fault = error }
            return nil
        }
    }

    private func application(for pid: pid_t) -> AXElement {
        let application = world.application(pid: pid)
        world.setMessagingTimeout(seconds(budgets.budget(for: .read, on: .accessibility)), on: application)
        return application
    }

    /// The same clamp `AXFocusProbe` makes, and for the same reason: a timeout of zero means "use the
    /// global default" to AX, which is long enough to hand a wedged app this queue for seconds.
    private func seconds(_ timeout: Duration) -> Float {
        let clamped = min(max(timeout, .milliseconds(1)), budgets.hardCutoff)
        return Float(Double(clamped.components.seconds) + Double(clamped.components.attoseconds) / 1e18)
    }
}

extension Result {
    /// The success, or nil. Reads better than a `try?` dance in the places that treat a fault as an
    /// absent answer and record it elsewhere.
    fileprivate var value: Success? {
        if case .success(let value) = self { value } else { nil }
    }
}
