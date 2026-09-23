import Foundation
import PappuCore
import PappuSelection

/// One of the app's own edit commands (PRD §7.4).
///
/// Two, not three. Copy is not here, and the reason is RUN-2 rather than convenience: a synthetic ⌘C
/// is synthetic input and so needs a `MutationPermit`, and a permit is only ever minted for a
/// destination that is *editable* — which the selection Copy is offered for very often is not. See
/// `BuiltinRunner` for what Copy does instead.
public enum EditCommand: String, Sendable, Codable, CaseIterable {
    /// ⌘X. Puts the selection on the clipboard and removes it, as one edit the user's ⌘Z undoes (RUN-4).
    case cut
    /// ⌘V. Puts what is already on the clipboard where the selection is.
    case paste
}

/// How posting one edit command ended. Codes only.
public enum EditOutcome: Sendable, Equatable {
    /// The keystroke went out. As close to "the app did it" as anything can honestly get: a cut and a
    /// paste both leave the app's own trace and none of ours.
    case posted
    /// The invocation was cancelled, paused out or revoked between the verification and the keystroke
    /// (RUN-3b, RUN-3c). Nothing went out.
    case notRunning
    /// The events could not be created or posted at all. Nothing went out.
    case notPosted
}

/// One posted edit command as the inspector will tell it (DIA-2, DIA-4).
public struct EditReport: Sendable, Equatable {
    public let invocation: InvocationID
    public let pid: pid_t?
    public let bundleID: String?
    /// How well the destination was known when the permit was minted. Never `.unverifiable`.
    public let tier: DestinationTier
    public let command: EditCommand
    public let outcome: EditOutcome

    init(
        invocation: InvocationID,
        target: TargetApp,
        tier: DestinationTier,
        command: EditCommand,
        outcome: EditOutcome
    ) {
        self.invocation = invocation
        self.pid = target.pid
        self.bundleID = target.bundleID
        self.tier = tier
        self.command = command
        self.outcome = outcome
    }

    public var posted: Bool { outcome == .posted }
}

/// Asks the app in front to run its own Cut or Paste (RUN-2, RUN-4, architecture §8.3).
///
/// **The sibling of `TextMutator`, and the difference is who writes the text.** `TextMutator` holds an
/// action's *result* on the clipboard for a moment and asks the app to take it; this holds nothing, and
/// asks the app to do a thing it already knows how to do. Both put synthetic input into somebody else's
/// process, so **both take a `MutationPermit` and neither can be called without one** — RUN-2a names
/// "cut, insertion, replacement or synthetic input", and RUN-2b lists "key presses" among what a
/// verified destination permits.
///
/// Nothing here touches the clipboard, which is the point of using the app's own commands: ⌘X puts the
/// app's own rich flavours on the clipboard and removes the selection as one undoable edit, and ⌘V
/// takes whatever is there. A clipboard transaction around either would be a second chance to lose the
/// user's clipboard for no gain.
public struct SelectionEditor: Sendable {
    private let cut: any SyntheticCutPosting
    private let paste: any SyntheticPastePosting
    private let manager: InvocationManager

    public init(
        cut: any SyntheticCutPosting,
        paste: any SyntheticPastePosting,
        manager: InvocationManager
    ) {
        self.cut = cut
        self.paste = paste
        self.manager = manager
    }

    /// Posts `command` to the verified destination.
    ///
    /// The permit is consumed: one verification pays for one keystroke. The liveness check in front of
    /// the post is not the same one the verification already made — a permit is minted before this call
    /// and spent inside it, and Escape does not wait its turn (RUN-3a, RUN-3b).
    public func post(
        _ command: EditCommand,
        using permit: consuming MutationPermit
    ) async -> EditReport {
        let invocation = permit.invocation
        let tier = permit.tier
        let target = permit.target

        func report(_ outcome: EditOutcome) -> EditReport {
            EditReport(
                invocation: invocation,
                target: target,
                tier: tier,
                command: command,
                outcome: outcome
            )
        }

        guard await manager.accepts(invocation) else { return report(.notRunning) }

        let posted = switch command {
        case .cut: cut.postCut()
        case .paste: paste.postPaste()
        }
        guard posted else { return report(.notPosted) }

        // Both commands change the app's text, so both are mutations for the record's purposes. There
        // is no way to observe that the app actually did it — that is true of every synthetic keystroke
        // and is why `posted` is the honest word for it.
        await manager.noteMutation(of: invocation)
        return report(.posted)
    }
}
