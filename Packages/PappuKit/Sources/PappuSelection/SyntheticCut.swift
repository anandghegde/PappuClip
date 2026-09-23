import CoreGraphics

/// Posts the ⌘X that Cut is (PRD §7.4, RUN-2a).
///
/// A seam of one call, like `SyntheticCopyPosting` and `SyntheticPastePosting`, and for the same
/// reason: posting a key event needs the Accessibility grant and another app to receive it, so nothing
/// above it could be tested without one.
public protocol SyntheticCutPosting: Sendable {
    /// - Returns: False when the events could not be created or posted at all. Nothing was asked for,
    ///   so nothing can have been cut.
    func postCut() -> Bool
}

/// The app's ⌘X (architecture §8.3).
///
/// The same three details as `SystemSyntheticCopy` and `SystemSyntheticPaste`, for the same three
/// reasons: the launch's tag, so our own taps drop it and the input epoch does not move on our own
/// keystroke; flags *set* rather than added, so a ⌘X posted while Shift is down does not arrive as
/// ⇧⌘X; and `cghidEventTap`, so the event takes the path a real press takes.
///
/// **Why the app's own Cut and not a read followed by a replacement.** Cut is two effects — the
/// selection on the clipboard and the selection gone — and the app already has one command that does
/// both, registers both with its undo manager as a single edit (RUN-4), and puts its own rich flavours
/// on the clipboard on the way. Doing it ourselves would mean a clipboard transaction to capture the
/// text, a second one to paste an empty string over the selection, two undo steps, and plain text where
/// the user had formatting.
public struct SystemSyntheticCut: SyntheticCutPosting {
    /// `kVK_ANSI_X`, spelled out so this file needs no Carbon import.
    private static let keyX: CGKeyCode = 0x07

    private let tag: SyntheticEventTag

    public init(tag: SyntheticEventTag) {
        self.tag = tag
    }

    public func postCut() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyX, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyX, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            tag.mark(event)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
