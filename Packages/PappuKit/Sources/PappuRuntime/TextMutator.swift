import Foundation
import PappuCore
import PappuSelection

/// The seam between the mutator and the one thing in PappuClip that writes to the user's clipboard
/// (architecture §3.5, §5).
///
/// `ClipboardBroker` conforms to it and is its only real implementation. It exists as a protocol so
/// that the rules above it — RUN-2d's "nothing is written when the destination is unverifiable", most
/// of all — can be tested by watching a clipboard that never gets called at all.
public protocol TextPasting: Sendable {
    func paste(_ text: String, for invocation: InvocationID, into target: TargetApp) async -> ClipboardPasteResult
    /// The same paste, holding several representations of one value: a script's `pasteContent` (JS-4).
    func paste(content: [PasteboardRepresentation], for invocation: InvocationID, into target: TargetApp) async -> ClipboardPasteResult
}

extension TextPasting {
    /// A paster that knows only text pastes the plain text among `content`.
    public func paste(content: [PasteboardRepresentation], for invocation: InvocationID, into target: TargetApp) async -> ClipboardPasteResult {
        let plain = content.first { $0.type == PasteboardRepresentation.plainText }.flatMap { String(data: $0.data, encoding: .utf8) }
        return await paste(plain ?? "", for: invocation, into: target)
    }
}

extension ClipboardBroker: TextPasting {}

/// How a mutation ended. Codes only; the text is never in here in either direction.
public enum MutationOutcome: Sendable, Equatable {
    /// The text was held on the clipboard and the ⌘V went out. As close to "it was pasted" as anything
    /// can honestly get: a paste leaves no trace to observe (RUN-4).
    case mutated
    /// The invocation was cancelled, paused out or revoked between the verification and the paste
    /// (RUN-3b, RUN-3c). Nothing was written.
    case notRunning
    /// The clipboard transaction never opened. Nothing was written, and the user's clipboard was not
    /// touched.
    case clipboardRefused(ClipboardRefusal)
    /// The transaction opened and somebody else wrote while our text was up. The paste may have landed;
    /// the user's clipboard was not put back, and the record says so.
    case clipboardContested(ClipboardAmbiguity)
}

/// One mutation as the inspector will tell it (DIA-2, DIA-4).
public struct MutationReport: Sendable, Equatable {
    public let invocation: InvocationID
    public let pid: pid_t?
    public let bundleID: String?
    /// How well the destination was known when the permit was minted. Never `.unverifiable`.
    public let tier: DestinationTier
    /// How long the text was. Never what it said.
    public let characters: Int
    public let outcome: MutationOutcome
    /// The clipboard's own account, when a transaction ran at all.
    public let clipboard: ClipboardPasteRecord?

    init(
        invocation: InvocationID,
        target: TargetApp,
        tier: DestinationTier,
        characters: Int,
        outcome: MutationOutcome,
        clipboard: ClipboardPasteRecord? = nil
    ) {
        self.invocation = invocation
        self.pid = target.pid
        self.bundleID = target.bundleID
        self.tier = tier
        self.characters = characters
        self.outcome = outcome
        self.clipboard = clipboard
    }

    public var mutated: Bool { outcome == .mutated }
}

/// Puts an action's result where the user's selection was (RUN-2, RUN-4, architecture §8.3).
///
/// **It cannot be called without a `MutationPermit`**, and only `DestinationVerifier` can mint one, so
/// RUN-2a is a fact about what compiles rather than a step somebody has to remember. RUN-2c and RUN-2d
/// follow from the same fact and need no code of their own: an unverifiable destination produces no
/// permit, a missing permit produces no call, and a call is the only thing in the program that puts an
/// action's result on the user's clipboard. There is no "paste failed, so copy it instead" path here,
/// and its absence is the requirement.
///
/// **Why a paste and not `AXSelectedText`.** RUN-4 asks for one native undo step. Setting the attribute
/// would be one Accessibility call with no clipboard involved at all, and most apps do not register
/// such a write with their undo manager: the user's ⌘Z afterwards then does nothing, or undoes the edit
/// *before* ours, which is worse than nothing. A ⌘V is what every text system on the Mac already treats
/// as one undoable edit. The cost is the clipboard round trip `ClipboardBroker.paste` exists to make
/// safe, and that is the trade this whole file is.
///
/// **Not built here.** Two of architecture §8.3's paths are missing on purpose, and each waits on
/// something real. Pressing the app's cached Paste menu item, where a detection policy says that is
/// more reliable than ⌘V, waits on a policy field and on a measurement that says which apps need it.
/// Insert — collapsing the selection to its end before pasting — waits on an Accessibility *write*,
/// which `AXWorld` deliberately does not have; it belongs with BAR-17's Replace and Insert controls in
/// M4 (DIF-1a).
public struct TextMutator: Sendable {
    private let clipboard: any TextPasting
    private let manager: InvocationManager

    public init(clipboard: any TextPasting, manager: InvocationManager) {
        self.clipboard = clipboard
        self.manager = manager
    }

    /// Replaces the verified selection with `text`.
    ///
    /// The permit is consumed: one verification pays for one paste, and a caller that wants to paste
    /// again has to ask the destination again. The liveness check in front of the transaction is not
    /// the same as the one the verification already made — a permit is minted before the clipboard
    /// work and spent after it, and Escape does not wait its turn (RUN-3a, RUN-3b).
    ///
    /// An empty `text` is the caller's decision and is passed through: replacing a selection with
    /// nothing is a real edit, and this is not the layer that has an opinion about it.
    public func replaceSelection(
        with text: String,
        using permit: consuming MutationPermit
    ) async -> MutationReport {
        await replaceSelection(content: [.text(text)], characters: text.count, using: permit)
    }

    /// The same, with several representations of one value — plain text, HTML, RTF — so the app pasted
    /// into takes the richest it reads: a script's `pasteContent` (JS-4).
    public func replaceSelection(
        content: [PasteboardRepresentation],
        using permit: consuming MutationPermit
    ) async -> MutationReport {
        let plain = content.first { $0.type == PasteboardRepresentation.plainText }.flatMap { String(data: $0.data, encoding: .utf8) }
        return await replaceSelection(content: content, characters: plain?.count ?? 0, using: permit)
    }

    private func replaceSelection(
        content: [PasteboardRepresentation],
        characters: Int,
        using permit: consuming MutationPermit
    ) async -> MutationReport {
        let invocation = permit.invocation
        let tier = permit.tier
        let target = permit.target

        func report(_ outcome: MutationOutcome, _ record: ClipboardPasteRecord? = nil) -> MutationReport {
            MutationReport(
                invocation: invocation,
                target: target,
                tier: tier,
                characters: characters,
                outcome: outcome,
                clipboard: record
            )
        }

        guard await manager.accepts(invocation) else { return report(.notRunning) }

        let result = await clipboard.paste(content: content, for: invocation, into: target)
        switch result.outcome {
        case .pasted:
            await manager.noteMutation(of: invocation)
            return report(.mutated, result.record)
        case .skipped(let refusal):
            return report(.clipboardRefused(refusal), result.record)
        case .abandoned(let ambiguity):
            // The ⌘V may well have landed, so this is not a failure to mutate — it is a mutation whose
            // clipboard could not be put back, and the difference matters to what the bar says.
            if result.posted { await manager.noteMutation(of: invocation) }
            return report(.clipboardContested(ambiguity), result.record)
        }
    }
}
