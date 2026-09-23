import Carbon.HIToolbox
import PappuCore

/// The system-wide half of ACT-12.
///
/// `IsSecureEventInputEnabled` is a cheap call against the window server, which is why architecture
/// §4.3 reads it again at mouse-up instead of trusting what mouse-down saw: a password sheet can open
/// during a drag. The other half — whether the focused element is an `AXSecureTextField` — comes from
/// the AX actor, and both go into one `SecureInputState` for the gate.
public enum SecureInput {
    public static var isActiveSystemWide: Bool { IsSecureEventInputEnabled() }

    public static func state(focusedFieldIsSecure: Bool) -> SecureInputState {
        SecureInputState(systemWide: isActiveSystemWide, focusedFieldIsSecure: focusedFieldIsSecure)
    }
}
