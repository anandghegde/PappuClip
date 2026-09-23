import Foundation
import PappuCore
import PappuSelection

/// One Key Press run as the inspector will tell it (DIA-2, DIA-4). Codes and counts only.
public struct KeyPressReport: Sendable, Equatable {
    public let invocation: InvocationID
    /// How well the destination was known when the permit was minted. Never `.unverifiable`.
    public let tier: DestinationTier
    /// `posted` when every combo went out; otherwise why the sequence stopped where it did.
    public let outcome: EditOutcome
    /// How many combos went out before it ended, which for a stopped sequence is the part that
    /// happened (RUN-3e: no rollback is promised).
    public let pressed: Int

    public var posted: Bool { outcome == .posted }
}

/// Plays a Key Press action's sequence into the verified destination (§8.4, RUN-2a).
///
/// **One permit for the sequence.** A key press is synthetic input, so it needs a `MutationPermit`
/// like Cut and Paste do. The permit pays for the whole sequence rather than for each combo, because a
/// sequence is one action the user chose: `command a`, `wait 100`, `command c` is "select all and
/// copy", and verifying between the two would find the selection the first combo just made and refuse
/// the second. What *is* checked between every combo and after every wait is that the invocation is
/// still live, so Escape in the middle stops the rest of the sequence (RUN-3b) — the combos already
/// sent stay sent, and the report counts them.
///
/// **Where the events go** is the extension's `keyComboTarget`, and `app` means the process the permit
/// was minted for, never whatever happens to be in front.
public struct KeyPresser: Sendable {
    private let poster: any SyntheticKeyPressPosting
    private let manager: InvocationManager
    private let sleeper: any InvocationSleeping

    public init(
        poster: any SyntheticKeyPressPosting,
        manager: InvocationManager,
        sleep: any InvocationSleeping = SystemInvocationSleep()
    ) {
        self.poster = poster
        self.manager = manager
        self.sleeper = sleep
    }

    public func press(_ action: KeyPressAction, using permit: consuming MutationPermit) async -> KeyPressReport {
        let invocation = permit.invocation
        let tier = permit.tier
        let delivery = KeyPressDelivery(target: action.target ?? .session, processID: permit.target.pid)
        _ = consume permit

        var pressed = 0
        func report(_ outcome: EditOutcome) -> KeyPressReport {
            KeyPressReport(invocation: invocation, tier: tier, outcome: outcome, pressed: pressed)
        }

        for step in action.steps {
            guard await manager.accepts(invocation) else { return report(.notRunning) }
            if case .wait(let milliseconds) = step {
                await sleeper.sleep(for: .milliseconds(milliseconds))
                continue
            }
            // The builder already read every combo (§8.4), so a failure here is a manifest that did
            // not come through it; it is refused the same way an event that could not be made is.
            guard let combo = try? KeyCombo.parse(step),
                  poster.post(combo, to: delivery)
            else { return report(.notPosted) }
            if pressed == 0 { await manager.noteMutation(of: invocation) }
            pressed += 1
        }
        return report(.posted)
    }
}
