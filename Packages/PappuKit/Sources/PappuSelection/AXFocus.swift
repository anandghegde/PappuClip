import PappuAX
import PappuCore

/// What the mouse-down probe of architecture §4.3 learned about the target app: structure, never content.
///
/// A probe that learns nothing is ordinary — most Mac apps answer `AXFocusedUIElement` and little else,
/// and a Chromium app with its tree switched off answers nothing at all — so an empty `AXFocus` is a
/// result and not an error. `fault` says why for the inspector (DIA-2).
public struct AXFocus: Sendable, Equatable {
    /// The focused element's role, or nil when the app has no focused element or would not say.
    public var focused: AXRole?
    /// The role of the element under the mouse-down point, when the probe was asked for one (ACT-14).
    public var underPointer: AXRole?
    /// Whether a read at mouse-up has an element to read from.
    public var hasFocusedElement: Bool
    /// The first thing that went wrong, for the trace. Never a reason to refuse on its own.
    public var fault: AXFault?

    public init(
        focused: AXRole? = nil,
        underPointer: AXRole? = nil,
        hasFocusedElement: Bool = false,
        fault: AXFault? = nil
    ) {
        self.focused = focused
        self.underPointer = underPointer
        self.hasFocusedElement = hasFocusedElement
        self.fault = fault
    }

    /// What `PrivacyGate` needs from the AX side (ACT-12).
    ///
    /// An unreadable role reports "not secure", and the reason is a choice worth stating: the system-wide
    /// flag is what actually catches a password field, because AppKit's secure field and the browsers'
    /// password fields turn secure input on, and this role check adds the apps that implement their own.
    /// Treating "the app would not answer" as secure instead would refuse every app with no AX tree —
    /// which is the Chromium and Electron half of the Mac — and buy nothing that the system-wide flag
    /// does not already cover.
    public var isFocusedFieldSecure: Bool { focused?.isSecureText ?? false }

    /// The whole of ACT-12's input, once the cheap system call is made alongside it.
    public func secureInputState(systemWide: Bool) -> SecureInputState {
        SecureInputState(systemWide: systemWide, focusedFieldIsSecure: isFocusedFieldSecure)
    }
}
