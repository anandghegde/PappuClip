import Foundation
import PappuAX

/// How the editability question was settled, and what it was settled to.
///
/// The answer alone is not enough for the inspector (DIA-2): "read-only" from the app's own refusal to
/// let us write `AXSelectedText` and "read-only" from a role we recognised are different confidences,
/// and a user asking why Paste is missing is asking which one it was.
public struct Editability: Sendable, Equatable, Hashable, Codable {
    /// In the order `ContextProbe` tries them.
    public enum Source: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// `AXUIElementIsAttributeSettable(AXSelectedText)`: the app's own answer to the question, and
        /// the only one that is not an inference.
        case settableSelectedText
        /// `AXEditableAncestor`: WebKit and Chromium name the nearest thing the user can type into,
        /// which is how a comment box is told from the page it sits on (FLT-6).
        case editableAncestor
        /// The role, which is a guess — a cheap and usually right one (`AXRole.editable`).
        case role
        /// Nothing answered. Treated as read-only, because FLT-6's promise is one-way: a bar that
        /// withholds Paste from an editable field is a missing action, and one that offers Cut on a
        /// web page is a broken one.
        case unanswered
    }

    public let isEditable: Bool
    public let source: Source

    public init(isEditable: Bool, source: Source) {
        self.isEditable = isEditable
        self.source = source
    }

    public static let unknown = Editability(isEditable: false, source: .unanswered)
}

/// What the app's Edit menu says about Cut, Copy and Paste right now (architecture §6.2).
///
/// Each is `nil` when the app does not answer: it has no such menu item, or the item does not report
/// `AXEnabled`. Nil is not "no" — `ContextProbe` reads it as "the menu has no opinion" and falls back
/// to editability, which is the only thing that keeps FLT-6 true in Chromium, where the items stay
/// enabled over read-only web content.
public struct EditMenuAvailability: Sendable, Equatable, Hashable, Codable {
    public var cut: Bool?
    public var copy: Bool?
    public var paste: Bool?
    /// Whether the three items were found in the menu bar at all. False means the walk came up empty,
    /// which is ordinary: an app may have no menu bar, or none we are allowed to see.
    public var located: Bool
    /// Why the walk or the reads stopped, when something went wrong.
    public var fault: AXFault?

    public init(cut: Bool? = nil, copy: Bool? = nil, paste: Bool? = nil, located: Bool = false, fault: AXFault? = nil) {
        self.cut = cut
        self.copy = copy
        self.paste = paste
        self.located = located
        self.fault = fault
    }

    public static let none = EditMenuAvailability()
}

/// The page a browser is showing (FLT-3), where the browser says.
///
/// The URL is also what website hard blocks are judged on (ACT-17b), which is why a `metadataOnly`
/// permit is enough to read it and why it is read before the selection rather than with it.
public struct BrowserPage: Sendable, Equatable, Hashable, Codable {
    public enum Source: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// `AXWebArea` → `AXURL`, plus a title. Free, and the only tier M1 has.
        case accessibility
        /// The per-browser scripting dictionaries, which need Automation consent (ONB-5). M4.
        case appleScript
    }

    public var url: URL?
    public var title: String?
    public var source: Source

    public init(url: URL?, title: String?, source: Source) {
        self.url = url
        self.title = title
        self.source = source
    }

    /// A page with neither a URL nor a title tells nobody anything, and `ContextProbe` reports no page
    /// rather than an empty one.
    public var isEmpty: Bool {
        url == nil && (title?.isEmpty ?? true)
    }
}

/// Everything FLT-3 asks for about where the selection came from, and the `Context` of architecture
/// §6.3: one of the five values `ActionResolver` is a pure function of.
///
/// Read once per attempt, on `AXActor`, against a `ReadPermit`. It holds no element and no text: an
/// `AXUIElement` never leaves the actor that made it, and the selection itself is `AnalyzedSelection`'s
/// business, not this type's.
public struct SelectionContext: Sendable, Equatable, Hashable, Codable {
    public var app: AppIdentity
    /// What the focused element says it is. Nil when the app has no Accessibility tree to ask.
    public var role: AXRole?
    public var editability: Editability
    /// FLT-6: false for read-only text, whatever the menu says.
    public var canCut: Bool
    public var canCopy: Bool
    /// FLT-6: false for read-only text, whatever the menu says.
    public var canPaste: Bool
    /// Whether the control can describe its text with attributes — `AXAttributedStringForRange` — which
    /// is what FLT-4's HTML and RTF capture reads, and what a formatting action is offered on.
    public var hasFormatting: Bool
    public var browser: BrowserPage?
    /// What the Edit menu said, before FLT-6 was applied to it. Kept for the inspector.
    public var menu: EditMenuAvailability
    /// Why the probe learned less than it wanted to. Not an error: a context with a fault is still a
    /// context, and the bar still appears.
    public var fault: AXFault?

    public init(
        app: AppIdentity,
        role: AXRole? = nil,
        editability: Editability = .unknown,
        canCut: Bool = false,
        canCopy: Bool = false,
        canPaste: Bool = false,
        hasFormatting: Bool = false,
        browser: BrowserPage? = nil,
        menu: EditMenuAvailability = .none,
        fault: AXFault? = nil
    ) {
        self.app = app
        self.role = role
        self.editability = editability
        self.canCut = canCut
        self.canCopy = canCopy
        self.canPaste = canPaste
        self.hasFormatting = hasFormatting
        self.browser = browser
        self.menu = menu
        self.fault = fault
    }

    public var isEditable: Bool { editability.isEditable }

    /// Whether the selection is inside a web page, which is what `BrowserMetadata` was able to answer
    /// for and what the website rules of ACT-17b apply to.
    public var isWebContent: Bool { browser != nil }
}
