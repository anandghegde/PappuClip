/// The two ways macOS says "not here" (ACT-12).
///
/// Both are system calls, so the caller gathers them and the gate only judges: `IsSecureEventInputEnabled`
/// from `SecureInput` in PappuSelection, and the role of the focused element from the AX actor. Secure
/// input is cheap to read and can change mid-gesture, which is why architecture §4.3 reads it again at
/// mouse-up rather than trusting the mouse-down value.
public struct SecureInputState: Sendable, Equatable, Codable {
    /// Some app has taken the secure event input stream — a password field anywhere, or a terminal
    /// that left it on.
    public var systemWide: Bool
    /// The focused element of the target app is an `AXSecureTextField`.
    public var focusedFieldIsSecure: Bool

    public init(systemWide: Bool, focusedFieldIsSecure: Bool) {
        self.systemWide = systemWide
        self.focusedFieldIsSecure = focusedFieldIsSecure
    }

    /// Neither flag set. Named rather than defaulted, so a caller that has not looked cannot pass it
    /// by leaving an argument out.
    public static let clear = SecureInputState(systemWide: false, focusedFieldIsSecure: false)
}
