import CoreGraphics
import Foundation

/// A handle on one element of some app's Accessibility tree.
///
/// It is a box around an `AXUIElement` — or around whatever stands for one in a test's world — so that
/// nothing above the seam touches a Core Foundation type. `@unchecked Sendable` because the box is
/// immutable and everything that reads through it is isolated to `AXActor`.
///
/// It is deliberately not `Equatable`. Two handles fetched by two calls describe the same element
/// without being the same object, and answering "is this still the element I read from?" — the
/// Accessibility tier of RUN-2 — is a question for the world that issued them, not for `===`.
public final class AXElement: @unchecked Sendable {
    /// The `AXUIElement`, or a test world's stand-in for one.
    public let handle: AnyObject

    public init(_ handle: AnyObject) {
        self.handle = handle
    }
}

/// The attributes PappuClip asks an element for.
///
/// A closed list rather than free strings, so that every attribute the program reads is declared in one
/// place and can be judged. `carriesText` is what makes that worth doing: the mouse-down probes of
/// architecture §4.3 must read structure and never content, and a test asserts it over this list rather
/// than over a reviewer's memory.
public enum AXAttribute: String, Sendable, Equatable, CaseIterable {
    case focusedUIElement = "AXFocusedUIElement"
    case focusedWindow = "AXFocusedWindow"
    case role = "AXRole"
    case subrole = "AXSubrole"
    /// The extent of the selection, not the selection. Read at mouse-down as ACT-14's baseline.
    case selectedTextRange = "AXSelectedTextRange"
    /// The selection itself (ACT-9, strategy 1). Nothing before the bar's own read may ask for it.
    case selectedText = "AXSelectedText"
    /// The application's menu bar, the root of `EditMenuProbe`'s walk (FLT-3, architecture §6.2).
    case menuBar = "AXMenuBar"
    case children = "AXChildren"
    /// A menu item's key equivalent, as the one character it is typed with. `EditMenuProbe` matches on
    /// this and never on the title, which is localised (architecture §6.2).
    case menuItemCmdChar = "AXMenuItemCmdChar"
    /// The modifier mask on that key equivalent, where zero means Command alone.
    case menuItemCmdModifiers = "AXMenuItemCmdModifiers"
    /// Whether a control — for us, a menu item — is available right now. The whole of FLT-6 on the
    /// apps that answer it.
    case enabled = "AXEnabled"
    /// WebKit and Chromium answer with the nearest ancestor the user can type into, which is how a
    /// read-only web page is told from a text box inside one (FLT-6).
    case editableAncestor = "AXEditableAncestor"
    /// A window's or a web area's title (FLT-3). Content, so it needs a permit.
    case title = "AXTitle"
    /// The page address of an `AXWebArea` (FLT-3). Content, so it needs a permit — and a
    /// `metadataOnly` one is enough, which is what that scope exists for (ACT-17b).
    case url = "AXURL"

    /// Whether the value can hold content — the user's own text, or the page they are looking at.
    ///
    /// The mouse-down probes of architecture §4.3 read structure and never content, and a test asserts
    /// that over this list rather than over a reviewer's memory. A title and a URL are on the content
    /// side of the line even though neither is the selection: a URL is the thing website hard blocks
    /// are made of (ACT-17b), and a window title routinely carries a document name.
    public var carriesText: Bool {
        switch self {
        case .selectedText, .title, .url:
            true
        case .focusedUIElement, .focusedWindow, .role, .subrole, .selectedTextRange,
             .menuBar, .children, .menuItemCmdChar, .menuItemCmdModifiers, .enabled, .editableAncestor:
            false
        }
    }
}

/// An attribute that takes an argument, which PappuClip asks about but — before FLT-4 in M3 — never
/// reads.
///
/// `ContextProbe` uses the *presence* of `AXAttributedStringForRange` as the answer to "does this
/// control support formatting?" (FLT-3). Asking whether an app offers the attribute costs one call and
/// returns no text; reading it would return the selection with its attributes, which needs a full-text
/// permit and a visible action that asked for it.
public enum AXParameterizedAttribute: String, Sendable, Equatable, CaseIterable {
    case attributedStringForRange = "AXAttributedStringForRange"
    case boundsForRange = "AXBoundsForRange"

    /// The same line `AXAttribute.carriesText` draws, for the same reason. A rectangle on screen says
    /// where the selection is and not a character of what it says, which is why strategy 1 may ask for
    /// one with no more than the permit it already spent on the text (BAR-3).
    public var carriesText: Bool {
        switch self {
        case .attributedStringForRange: true
        case .boundsForRange: false
        }
    }
}

/// The two attributes that switch an app's Accessibility tree on (ACT-9 strategy 3, architecture §4.5).
///
/// Writable, unlike everything else here, and a closed list for the same reason the read attributes are
/// one: setting an attribute on a process that did not ask for it is a side effect, and the two that
/// PappuClip is willing to cause are named here and nowhere else. Which one an app wants is
/// `DetectionPolicy.axEnable`, because setting the wrong one is a side effect that buys nothing.
public enum AXTreeSwitch: String, Sendable, Equatable, CaseIterable {
    /// Electron's spelling.
    case manualAccessibility = "AXManualAccessibility"
    /// Chromium's spelling.
    case enhancedUserInterface = "AXEnhancedUserInterface"
}

/// A value an attribute came back with, decoded at the seam.
public enum AXAttributeValue: Sendable {
    case element(AXElement)
    case elements([AXElement])
    case string(String)
    case range(AXTextRange)
    case flag(Bool)
    case number(Int)
    case url(URL)
    /// Screen coordinates with a top-left origin, which is the space the Accessibility API answers
    /// `AXBoundsForRange` in and the one `PappuSurfaces` places the bar in (`BarScreen`).
    case rect(CGRect)

    public var asElement: AXElement? {
        if case .element(let element) = self { element } else { nil }
    }

    /// The first element of the answer, whether the app answered one or a list.
    ///
    /// `AXMenuBar` and `AXFocusedWindow` are single elements by the protocol and arrays in a few apps,
    /// and a caller that wants one element would rather have the first than nothing.
    public var asFirstElement: AXElement? {
        switch self {
        case .element(let element): element
        case .elements(let elements): elements.first
        default: nil
        }
    }

    /// A single element counts as a list of one: `AXChildren` on an app with one menu is an array, but
    /// an app is free to answer an element where the protocol says array, and a caller walking a tree
    /// would rather carry on than stop.
    public var asElements: [AXElement]? {
        switch self {
        case .elements(let elements): elements
        case .element(let element): [element]
        default: nil
        }
    }

    public var asString: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var asRange: AXTextRange? {
        if case .range(let range) = self { range } else { nil }
    }

    public var asFlag: Bool? {
        switch self {
        case .flag(let flag): flag
        // AppKit hands `AXEnabled` back as a `CFBoolean`, but a few apps answer 0 or 1 instead.
        case .number(let number): number != 0
        default: nil
        }
    }

    public var asNumber: Int? {
        if case .number(let number) = self { number } else { nil }
    }

    public var asRect: CGRect? {
        if case .rect(let rect) = self { rect } else { nil }
    }

    public var asURL: URL? {
        switch self {
        case .url(let url): url
        case .string(let string): URL(string: string)
        default: nil
        }
    }
}

/// Where a selection is, in characters, without saying what it is.
///
/// A length of zero is an answer and not a failure: it is a caret, which is most of what mouse-down
/// sees.
public struct AXTextRange: Sendable, Equatable, Hashable, Codable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var isEmpty: Bool { length == 0 }
}

/// Why an Accessibility call did not answer.
///
/// The five `AXError` values that mean something different to us, and everything else. Kept apart from
/// "the answer was empty", which is not a fault.
public enum AXFault: Error, Sendable, Equatable, Hashable, Codable {
    /// `kAXErrorAPIDisabled`: the Accessibility grant is missing or was taken away.
    case notPermitted
    /// The element has no such attribute, or there is no focused element. Ordinary: most of the Mac's
    /// apps answer this for most of these attributes.
    case unsupported
    /// `kAXErrorCannotComplete`: the app did not answer inside the messaging timeout. The stage budget
    /// sets that timeout, so this is what a read running out of time looks like.
    case timedOut
    /// `kAXErrorInvalidUIElement`: the element is gone — its window closed, or the app quit.
    case staleElement
    /// Anything else, with the raw `AXError` for the trace.
    case failed(Int32)
}

/// The seam between everything above and `AXUIElement` (architecture §4.5): `SystemAXWorld` in the app,
/// `FakeAXWorld` in tests.
///
/// Its calls are synchronous and blocking, which is what an AX call is. They are only ever made from
/// `AXActor`, so the blocking is confined to one queue of its own.
public protocol AXWorld: Sendable {
    /// The element that stands for a whole process. A local call: it makes no contact with the app.
    func application(pid: pid_t) -> AXElement

    /// Whether two handles describe the same element.
    ///
    /// `AXElement` is not `Equatable` on purpose: two handles fetched by two calls describe the same
    /// element without being the same object, so only the world that issued them can answer. This is
    /// that answer, and the Accessibility tier of RUN-2 is built on it. A local call, like
    /// `application(pid:)`: it compares two references and makes no contact with the app.
    func isSame(_ one: AXElement, as other: AXElement) -> Bool

    /// Bounds how long a call on `element` waits for the app. Set from the read stage's budget.
    func setMessagingTimeout(_ seconds: Float, on element: AXElement)

    /// The deepest element at a screen point, in global coordinates with a top-left origin — the same
    /// coordinates `PointerEvent.location` arrives in.
    func element(at point: CGPoint, in application: AXElement) -> Result<AXElement, AXFault>

    func attribute(_ attribute: AXAttribute, of element: AXElement) -> Result<AXAttributeValue, AXFault>

    /// Whether the app would let us write that attribute, which is how editability is decided without
    /// reading anything (FLT-3): `AXSelectedText` being settable is the true answer to "can the user
    /// type here?", and asking costs no content.
    func isSettable(_ attribute: AXAttribute, of element: AXElement) -> Result<Bool, AXFault>

    /// Whether the element offers that parameterized attribute. The names list only; the value is never
    /// fetched here.
    func supports(_ attribute: AXParameterizedAttribute, of element: AXElement) -> Result<Bool, AXFault>

    /// One parameterized attribute, over a range of the element's text.
    ///
    /// Only `AXBoundsForRange` is asked for through here, and the reason it is not asked through
    /// `supports` first is arithmetic: two round trips to a wedged app cost twice one, and an app that
    /// does not offer the attribute answers `.unsupported` to the value call just as usefully as to the
    /// names call. `AXAttributedStringForRange` is `carriesText` and would need a full-text permit
    /// standing behind this call before anything may ask for it (FLT-4, M3).
    func value(
        _ attribute: AXParameterizedAttribute,
        for range: AXTextRange,
        of element: AXElement
    ) -> Result<AXAttributeValue, AXFault>

    /// Switches an app's Accessibility tree on or off (strategy 3).
    ///
    /// The only write in the whole seam, and it goes to the *application* element rather than to any
    /// element inside it: this is a message to the process about itself. Whether the switch is left on
    /// or turned back off after the read is `AXSelectionReader`'s to decide from the policy, not this
    /// call's — M0 spike 4 is what says which is safe per app.
    func setTree(_ which: AXTreeSwitch, to on: Bool, of application: AXElement) -> Result<Void, AXFault>
}
