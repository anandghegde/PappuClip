import ApplicationServices
import CoreGraphics
import Foundation
import PappuAX
import Synchronization

/// Stands in for the Accessibility API, which needs the grant, a window server and another app to talk
/// to. A test builds a tree of nodes, says which one is focused and what sits under the pointer, and can
/// make any call fail or hang the way a real app does.
///
/// It also keeps every attribute that was asked for, which is how the tests assert what the mouse-down
/// probes never read (architecture §4.3).
public final class FakeAXWorld: AXWorld, Sendable {
    /// One element of the tree. `NSObject` because the handle it goes into is a Core Foundation type in
    /// the real world, and `CFGetTypeID` must be safe to call on whatever is in there.
    public final class Node: NSObject, @unchecked Sendable {
        public let role: String?
        public let subrole: String?
        public let selectedText: String?
        /// Menus, menu items, groups and web areas are all `AXChildren` away from their parent, so one
        /// field carries both `EditMenuProbe`'s walk and `BrowserMetadata`'s.
        public let children: [Node]?
        /// `AXMenuBar` and `AXFocusedWindow`, which an application element answers and nothing else
        /// does. Kept apart from `children` because a browser has both and they are different trees.
        public let menuBar: Node?
        public let focusedWindow: Node?
        public let title: String?
        public let url: URL?
        /// `AXEnabled`. Nil for the elements that do not answer it, which is most of them.
        public let enabled: Bool?
        /// `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers`, the pair `EditMenuProbe` matches on.
        public let cmdChar: String?
        public let cmdModifiers: Int?
        /// What `AXEditableAncestor` answers: the nearest ancestor the user can type into, which is how
        /// WebKit and Chromium tell a text box inside a page from the page (FLT-6).
        private let ancestor = Mutex<Node?>(nil)
        /// The attributes the app would let us write. `AXSelectedText` here is what makes an element
        /// editable (FLT-3).
        private let settable = Mutex<Set<AXAttribute>>([])
        private let parameterized = Mutex<Set<AXParameterizedAttribute>>([])
        private let range = Mutex<AXTextRange?>(nil)
        /// What `AXBoundsForRange` answers, per range. An app that offers no bounds simply has none
        /// here, which is the ordinary case and not a fault.
        private let bounds = Mutex<[AXTextRange: CGRect]>([:])
        private let faults = Mutex<[AXAttribute: AXFault]>([:])
        private let parameterizedValueFault = Mutex<AXFault?>(nil)
        private let settableFault = Mutex<AXFault?>(nil)
        private let parameterizedFault = Mutex<AXFault?>(nil)

        public init(
            role: String? = nil,
            subrole: String? = nil,
            selectedRange: AXTextRange? = nil,
            selectedText: String? = nil,
            children: [Node]? = nil,
            menuBar: Node? = nil,
            focusedWindow: Node? = nil,
            title: String? = nil,
            url: URL? = nil,
            enabled: Bool? = nil,
            cmdChar: String? = nil,
            cmdModifiers: Int? = nil
        ) {
            self.role = role
            self.subrole = subrole
            self.selectedText = selectedText
            self.children = children
            self.menuBar = menuBar
            self.focusedWindow = focusedWindow
            self.title = title
            self.url = url
            self.enabled = enabled
            self.cmdChar = cmdChar
            self.cmdModifiers = cmdModifiers
            super.init()
            range.withLock { $0 = selectedRange }
        }

        public var selectedRange: AXTextRange? {
            get { range.withLock { $0 } }
            set { range.withLock { $0 = newValue } }
        }

        public var editableAncestor: Node? {
            get { ancestor.withLock { $0 } }
            set { ancestor.withLock { $0 = newValue } }
        }

        /// Marks the element writable, as an editable control is for `AXSelectedText`.
        @discardableResult
        public func allowWriting(_ attribute: AXAttribute) -> Node {
            settable.withLock { _ = $0.insert(attribute) }
            return self
        }

        /// What `AXBoundsForRange` answers for that range, in screen coordinates with a top-left origin.
        @discardableResult
        public func setBounds(_ rect: CGRect, for range: AXTextRange) -> Node {
            bounds.withLock { $0[range] = rect }
            return self
        }

        /// What every parameterized *value* call answers instead. Kept apart from
        /// `failParameterizedChecks`, which is about the names list.
        public func failParameterizedValues(with fault: AXFault?) {
            parameterizedValueFault.withLock { $0 = fault }
        }

        fileprivate func value(
            _ attribute: AXParameterizedAttribute,
            for range: AXTextRange
        ) -> Result<AXAttributeValue, AXFault> {
            if let fault = parameterizedValueFault.withLock({ $0 }) { return .failure(fault) }
            guard attribute == .boundsForRange else { return .failure(.unsupported) }
            guard let rect = bounds.withLock({ $0[range] }) else { return .failure(.unsupported) }
            return .success(.rect(rect))
        }

        /// Marks the element as offering a parameterized attribute — `AXAttributedStringForRange` is
        /// the one FLT-3 reads `hasFormatting` from.
        @discardableResult
        public func offer(_ attribute: AXParameterizedAttribute) -> Node {
            parameterized.withLock { _ = $0.insert(attribute) }
            return self
        }

        /// What the app answers instead, for this attribute. Removing it makes the app answer again.
        public func fail(_ attribute: AXAttribute, with fault: AXFault?) {
            faults.withLock { $0[attribute] = fault }
        }

        /// What `AXUIElementIsAttributeSettable` answers instead, for every attribute.
        public func failSettableChecks(with fault: AXFault?) {
            settableFault.withLock { $0 = fault }
        }

        /// What the parameterized-attribute names call answers instead.
        public func failParameterizedChecks(with fault: AXFault?) {
            parameterizedFault.withLock { $0 = fault }
        }

        fileprivate func fault(for attribute: AXAttribute) -> AXFault? {
            faults.withLock { $0[attribute] }
        }

        fileprivate func isSettable(_ attribute: AXAttribute) -> Result<Bool, AXFault> {
            if let fault = settableFault.withLock({ $0 }) { return .failure(fault) }
            return .success(settable.withLock { $0.contains(attribute) })
        }

        fileprivate func supports(_ attribute: AXParameterizedAttribute) -> Result<Bool, AXFault> {
            if let fault = parameterizedFault.withLock({ $0 }) { return .failure(fault) }
            return .success(parameterized.withLock { $0.contains(attribute) })
        }
    }

    private struct State {
        var focused: [pid_t: Node] = [:]
        var underPointer: [CGPoint: Node] = [:]
        var applicationFaults: [pid_t: AXFault] = [:]
        var asked: [AXAttribute] = []
        var timeouts: [Float] = []
        var settableChecks: [AXAttribute] = []
        var parameterizedChecks: [AXParameterizedAttribute] = []
        var parameterizedValues: [(AXParameterizedAttribute, AXTextRange)] = []
        var treeSwitches: [(pid_t, AXTreeSwitch, Bool)] = []
        var treeSwitchFaults: [pid_t: AXFault] = [:]
    }

    private let state = Mutex(State())
    private let handles = Mutex<[pid_t: Node]>([:])

    public init() {}

    // MARK: Building the world

    /// The focused element of that process, or nil for a process that will not say.
    public func setFocused(_ node: Node?, in pid: pid_t) {
        state.withLock { $0.focused[pid] = node }
    }

    public func setUnderPointer(_ node: Node?, at point: CGPoint) {
        state.withLock { $0.underPointer[point] = node }
    }

    /// The node `AXUIElementCreateApplication` would hand back, for a test that needs the application
    /// element to carry something — a menu bar, or a focused window. Without this the world invents one,
    /// as it did before menus existed.
    public func setApplication(_ node: Node, in pid: pid_t) {
        handles.withLock { $0[pid] = node }
    }

    /// What every call against that process answers instead: a missing grant, a timeout, anything.
    public func failApplication(_ pid: pid_t, with fault: AXFault?) {
        state.withLock { $0.applicationFaults[pid] = fault }
    }

    /// What `setTree` answers for that process. An app with no Accessibility tree to switch on answers
    /// `.unsupported`, which is most of the Mac.
    public func failTreeSwitch(_ pid: pid_t, with fault: AXFault?) {
        state.withLock { $0.treeSwitchFaults[pid] = fault }
    }

    // MARK: What the test asks afterwards

    /// Every attribute asked of any element, in order.
    public var asked: [AXAttribute] { state.withLock { $0.asked } }

    /// Every messaging timeout set, in seconds, in order.
    public var timeouts: [Float] { state.withLock { $0.timeouts } }

    /// Every `AXUIElementIsAttributeSettable` call, in order. These read no value, so they are counted
    /// apart from `asked`.
    public var settableChecks: [AXAttribute] { state.withLock { $0.settableChecks } }

    /// Every parameterized-attribute names call, in order.
    public var parameterizedChecks: [AXParameterizedAttribute] { state.withLock { $0.parameterizedChecks } }

    /// Every parameterized-attribute *value* call, with the range it asked about, in order.
    public var parameterizedValues: [(AXParameterizedAttribute, AXTextRange)] {
        state.withLock { $0.parameterizedValues }
    }

    /// Every tree switch written, in order: which process, which attribute, and what it was set to.
    /// Strategy 3's whole side effect, so a test can assert both that it happened and that it happened
    /// once (architecture §4.5).
    public var treeSwitches: [(pid: pid_t, which: AXTreeSwitch, on: Bool)] {
        state.withLock { $0.treeSwitches }.map { (pid: $0.0, which: $0.1, on: $0.2) }
    }

    // MARK: AXWorld

    public func application(pid: pid_t) -> AXElement {
        // One node per process, so that a handle taken twice is the same object, as
        // `AXUIElementCreateApplication` is equal twice.
        let node = handles.withLock { handles -> Node in
            if let existing = handles[pid] { return existing }
            let node = Node(role: "AXApplication")
            handles[pid] = node
            return node
        }
        return AXElement(node)
    }

    /// Node identity, which is what `CFEqual` amounts to in the real world: one node is one element,
    /// and a test that wants "a different element" makes a different node.
    public func isSame(_ one: AXElement, as other: AXElement) -> Bool {
        guard let one = one.handle as? Node, let other = other.handle as? Node else { return false }
        return one === other
    }

    public func setMessagingTimeout(_ seconds: Float, on element: AXElement) {
        state.withLock { $0.timeouts.append(seconds) }
    }

    public func element(at point: CGPoint, in application: AXElement) -> Result<AXElement, AXFault> {
        guard let pid = pid(of: application) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        if let fault = state.withLock({ $0.applicationFaults[pid] }) { return .failure(fault) }
        guard let node = state.withLock({ $0.underPointer[point] }) else { return .failure(.unsupported) }
        return .success(AXElement(node))
    }

    public func attribute(_ attribute: AXAttribute, of element: AXElement) -> Result<AXAttributeValue, AXFault> {
        state.withLock { $0.asked.append(attribute) }
        guard let node = element.handle as? Node else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        if let fault = node.fault(for: attribute) { return .failure(fault) }
        if let pid = pid(of: element), let fault = state.withLock({ $0.applicationFaults[pid] }) {
            return .failure(fault)
        }

        switch attribute {
        case .focusedUIElement:
            guard let pid = pid(of: element) else { return .failure(.unsupported) }
            guard let focused = state.withLock({ $0.focused[pid] }) else { return .failure(.unsupported) }
            return .success(.element(AXElement(focused)))
        case .role:
            return node.role.map { .success(.string($0)) } ?? .failure(.unsupported)
        case .subrole:
            return node.subrole.map { .success(.string($0)) } ?? .failure(.unsupported)
        case .selectedTextRange:
            return node.selectedRange.map { .success(.range($0)) } ?? .failure(.unsupported)
        case .selectedText:
            return node.selectedText.map { .success(.string($0)) } ?? .failure(.unsupported)
        case .menuBar:
            return node.menuBar.map { .success(.element(AXElement($0))) } ?? .failure(.unsupported)
        case .focusedWindow:
            return node.focusedWindow.map { .success(.element(AXElement($0))) } ?? .failure(.unsupported)
        case .children:
            return node.children.map { .success(.elements($0.map(AXElement.init))) } ?? .failure(.unsupported)
        case .title:
            return node.title.map { .success(.string($0)) } ?? .failure(.unsupported)
        case .url:
            return node.url.map { .success(.url($0)) } ?? .failure(.unsupported)
        case .enabled:
            return node.enabled.map { .success(.flag($0)) } ?? .failure(.unsupported)
        case .menuItemCmdChar:
            return node.cmdChar.map { .success(.string($0)) } ?? .failure(.unsupported)
        case .menuItemCmdModifiers:
            return node.cmdModifiers.map { .success(.number($0)) } ?? .failure(.unsupported)
        case .editableAncestor:
            return node.editableAncestor.map { .success(.element(AXElement($0))) } ?? .failure(.unsupported)
        }
    }

    public func isSettable(_ attribute: AXAttribute, of element: AXElement) -> Result<Bool, AXFault> {
        state.withLock { $0.settableChecks.append(attribute) }
        guard let node = element.handle as? Node else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        return node.isSettable(attribute)
    }

    public func supports(_ attribute: AXParameterizedAttribute, of element: AXElement) -> Result<Bool, AXFault> {
        state.withLock { $0.parameterizedChecks.append(attribute) }
        guard let node = element.handle as? Node else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        return node.supports(attribute)
    }

    public func value(
        _ attribute: AXParameterizedAttribute,
        for range: AXTextRange,
        of element: AXElement
    ) -> Result<AXAttributeValue, AXFault> {
        state.withLock { $0.parameterizedValues.append((attribute, range)) }
        guard let node = element.handle as? Node else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        return node.value(attribute, for: range)
    }

    public func setTree(_ which: AXTreeSwitch, to on: Bool, of application: AXElement) -> Result<Void, AXFault> {
        guard let pid = pid(of: application) else { return .failure(.failed(AXError.illegalArgument.rawValue)) }
        if let fault = state.withLock({ $0.treeSwitchFaults[pid] }) { return .failure(fault) }
        state.withLock { $0.treeSwitches.append((pid, which, on)) }
        return .success(())
    }

    private func pid(of element: AXElement) -> pid_t? {
        guard let node = element.handle as? Node else { return nil }
        return handles.withLock { $0.first { $0.value === node }?.key }
    }
}
