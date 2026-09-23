import Foundation
import PappuAX
import PappuCore

/// Everything FLT-3 asks about where the selection came from, read in one pass on `AXActor`
/// (architecture §6.2).
///
/// It spends a `ReadPermit`, so a path that skipped §S1 does not compile. Either scope will do: the
/// probe never asks for `AXSelectedText`, and the most content-bearing thing it reads is the page
/// address, which is what `metadataOnly` exists for (ACT-17b).
///
/// It does not depend on `PappuSelection` and so does not share `AXFocusProbe`'s remembered element:
/// it reads `AXFocusedUIElement` itself. That is one extra Accessibility call per attempt, and it buys
/// a module boundary that architecture §3.1 asks for by name.
///
/// **FLT-6 lives here.** The Edit menu is asked, but it is not believed over the element: Chromium
/// leaves Cut and Paste enabled on read-only web content, so read-only text never offers either,
/// whatever the menu says. The menu's own answer is kept in `SelectionContext.menu` for the inspector.
@AXActor
public final class ContextProbe {
    private let world: any AXWorld
    private let budgets: BudgetTable
    private let names: any AppNaming
    private let menus: EditMenuProbe
    private let browsers: BrowserMetadata

    public init(
        world: any AXWorld = SystemAXWorld(),
        budgets: BudgetTable = .initial,
        names: any AppNaming = SystemAppNames(),
        menus: EditMenuProbe? = nil
    ) {
        self.world = world
        self.budgets = budgets
        self.names = names
        self.menus = menus ?? EditMenuProbe(world: world)
        browsers = BrowserMetadata(world: world)
    }

    /// - Parameter timeout: Defaults to the read stage's budget on the Accessibility path (PRD §11.1),
    ///   the same bound `AXFocusProbe` uses, because this runs inside the same stage.
    public func probe(_ permit: consuming ReadPermit, timeout: Duration? = nil) -> SelectionContext {
        let target = permit.target
        let app = AppIdentity(pid: target.pid, bundleID: target.bundleID, name: names.name(of: target.pid))
        let application = world.application(pid: target.pid)
        world.setMessagingTimeout(seconds(timeout), on: application)

        var context = SelectionContext(app: app)

        let focused: AXElement?
        switch world.attribute(.focusedUIElement, of: application) {
        case .success(let value):
            focused = value.asElement
            if let focused {
                world.setMessagingTimeout(seconds(timeout), on: focused)
            } else {
                context.fault = .unsupported
            }
        case .failure(let fault):
            focused = nil
            context.fault = fault
        }

        var hasEditableAncestor = false
        if let focused {
            context.role = role(of: focused)
            hasEditableAncestor = editableAncestor(of: focused)
            context.editability = editability(of: focused, role: context.role, hasEditableAncestor: hasEditableAncestor)
            context.hasFormatting = hasFormatting(focused)
        }

        context.menu = menus.availability(for: target.pid, in: application)
        context.browser = browsers.page(
            from: focused,
            role: context.role,
            hasEditableAncestor: hasEditableAncestor,
            in: application
        )

        // FLT-6. The menu narrows what editability allows; it never widens it.
        let editable = context.editability.isEditable
        context.canCut = editable && (context.menu.cut ?? true)
        context.canPaste = editable && (context.menu.paste ?? true)
        // Copy asks nothing of the control: a paragraph one cannot edit is still one that can be
        // copied, which is most of what the bar is for.
        context.canCopy = context.menu.copy ?? true

        if context.fault == nil { context.fault = context.menu.fault }
        return context
    }

    /// Drops what is remembered about a process, for one that has quit (RUN-2).
    public func forget(_ pid: pid_t) {
        menus.forget(pid)
    }

    // MARK: The four questions

    private func role(of element: AXElement) -> AXRole? {
        func string(_ attribute: AXAttribute) -> String? {
            guard case .success(let value) = world.attribute(attribute, of: element) else { return nil }
            return value.asString
        }
        let role = AXRole(role: string(.role), subrole: string(.subrole))
        return role.role == nil && role.subrole == nil ? nil : role
    }

    /// WebKit and Chromium answer `AXEditableAncestor` with the nearest element the user can type
    /// into; every other app answers nothing. A page with no text box therefore answers nothing too,
    /// which is exactly the FLT-6 case.
    private func editableAncestor(of element: AXElement) -> Bool {
        guard case .success(let value) = world.attribute(.editableAncestor, of: element) else { return false }
        return value.asElement != nil
    }

    /// Settable first, because it is the app's own answer rather than an inference; the ancestor
    /// second, because it is the web's answer to the same question; the role last, and only when
    /// neither of the other two would speak.
    private func editability(of element: AXElement, role: AXRole?, hasEditableAncestor: Bool) -> Editability {
        switch world.isSettable(.selectedText, of: element) {
        case .success(true):
            return Editability(isEditable: true, source: .settableSelectedText)
        case .success(false):
            // A definite no from the app, except in a browser, where the app is answering for the page
            // and the page may hold a text box.
            if hasEditableAncestor { return Editability(isEditable: true, source: .editableAncestor) }
            return Editability(isEditable: false, source: .settableSelectedText)
        case .failure:
            if hasEditableAncestor { return Editability(isEditable: true, source: .editableAncestor) }
            guard let role else { return .unknown }
            return Editability(isEditable: role.isEditableText, source: .role)
        }
    }

    /// The names of the parameterized attributes, not the value: asking whether the control offers
    /// `AXAttributedStringForRange` costs one call and returns no text. Reading it would return the
    /// selection with its attributes, which needs a full-text permit and an action that asked (FLT-4).
    private func hasFormatting(_ element: AXElement) -> Bool {
        guard case .success(let supported) = world.supports(.attributedStringForRange, of: element) else {
            return false
        }
        return supported
    }

    // MARK: Plumbing

    /// The same clamp `AXFocusProbe` applies, for the same reason: zero means the global default, which
    /// is long enough to hand a wedged app this queue for seconds.
    private func seconds(_ timeout: Duration?) -> Float {
        let timeout = timeout ?? budgets.budget(for: .read, on: .accessibility)
        let clamped = min(max(timeout, .milliseconds(1)), budgets.hardCutoff)
        return Float(Double(clamped.components.seconds) + Double(clamped.components.attoseconds) / 1e18)
    }
}
