/// What an element says it is.
///
/// Roles are open strings — an app may answer anything — so this keeps them as strings and answers only
/// the two questions PappuClip asks of them.
public struct AXRole: Sendable, Equatable, Hashable, Codable {
    /// `AXSecureTextField`. AppKit's secure field answers it as a *subrole* with the role `AXTextField`,
    /// and apps that roll their own put it in the role, so both are checked (ACT-12).
    public static let secureTextField = "AXSecureTextField"

    /// `AXWebArea`: the element a browser puts a page inside, and the one that answers `AXURL`
    /// (FLT-3).
    public static let webArea = "AXWebArea"

    /// The roles that hold text a selection could come from. `AXWebArea` is here because a web page's
    /// focused element is often the area itself, and `AXStaticText` because a paragraph one cannot edit
    /// is still a paragraph one can select.
    public static let textual: Set<String> = [
        "AXTextField", "AXTextArea", "AXStaticText", "AXComboBox", "AXWebArea",
    ]

    public var role: String?
    public var subrole: String?

    public init(role: String?, subrole: String?) {
        self.role = role
        self.subrole = subrole
    }

    /// ACT-12's second half. The first is `IsSecureEventInputEnabled` (`SecureInput`).
    public var isSecureText: Bool {
        role == Self.secureTextField || subrole == Self.secureTextField
    }

    /// The roles a caret can sit in, which is what ACT-3 asks about: a bar with no selection exists so
    /// that Paste is reachable, and a paragraph one can only read has nothing to paste into.
    ///
    /// Editability really belongs to the element rather than to its role — `AXValue` being settable is
    /// the true answer — but that is a second round trip per element, and the attribute it asks about is
    /// the one that holds the text. The role costs nothing and reads nothing, which is the trade ACT-14
    /// is built on: several cheap signals rather than one expensive one.
    public static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// AppKit puts a search field's identity in the subrole and a plain field's in the role, so both are
    /// asked, exactly as `isSecureText` does.
    public var isEditableText: Bool {
        (role.map(Self.editable.contains) ?? false) || (subrole.map(Self.editable.contains) ?? false)
    }

    /// One of the several signals ACT-14 requires, never the decision on its own.
    ///
    /// A secure field needs no case of its own: AppKit gives it the role `AXTextField`, which is textual,
    /// and what stops it being read is `isSecureText`.
    public var isTextual: Bool {
        guard let role else { return false }
        return Self.textual.contains(role)
    }
}
