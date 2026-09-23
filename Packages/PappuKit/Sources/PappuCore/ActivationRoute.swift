/// How a selection attempt was asked for (safety spec §S1).
///
/// One gate serves all four routes (architecture §4.4). The three deliberate ones clear step 3 —
/// the user asked for the bar in this app, so an appearance exclusion has nothing left to say — but
/// no route clears steps 1 and 2 (ACT-5, ACT-17a, ACT-18).
public enum ActivationRoute: String, Sendable, Codable, CaseIterable {
    /// A pointer gesture while "Appear automatically" is on (ACT-1).
    case automatic
    /// The global shortcut (ACT-5).
    case hotkey
    /// AppleScript (SCR-1).
    case script
    /// `pappuclip://` (SCR-2).
    case urlScheme

    /// The user asked for this one by name, so appearance settings do not apply to it.
    public var isDeliberate: Bool { self != .automatic }
}
