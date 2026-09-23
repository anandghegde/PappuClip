import CoreGraphics

/// Posts the ⌘V that puts held text into the app (RUN-4, architecture §8.3).
///
/// A seam of one call, like `SyntheticCopyPosting`, and for the same reason: posting a key event needs
/// the grant and another app to receive it, so nothing above it could be tested without one.
public protocol SyntheticPastePosting: Sendable {
    /// - Returns: False when the events could not be created or posted at all. Nothing was asked for,
    ///   so nothing can have been pasted, and the held text can be taken back down at once.
    func postPaste() -> Bool
}

/// The app's ⌘V (architecture §8.3).
///
/// The same three details as `SystemSyntheticCopy`, for the same three reasons: the launch's tag, so
/// our own taps drop it and the input epoch does not move on our own paste; flags *set* rather than
/// added, so a ⌘V posted while Shift is down does not arrive as ⇧⌘V and paste-and-match-style
/// somewhere it should not; and `cghidEventTap`, so the event takes the path a real press takes.
///
/// **Why a key press rather than `AXSelectedText`.** Setting the attribute is one call and would need
/// no clipboard at all, and it is not what RUN-4 asks for: most apps do not register a programmatic
/// `AXSelectedText` write with their undo manager, so the user's ⌘Z afterwards either does nothing or
/// undoes the edit *before* ours. A paste is what every text system on the Mac already treats as one
/// undoable edit.
public struct SystemSyntheticPaste: SyntheticPastePosting {
    /// `kVK_ANSI_V`, spelled out so this file needs no Carbon import.
    private static let keyV: CGKeyCode = 0x09

    private let tag: SyntheticEventTag

    public init(tag: SyntheticEventTag) {
        self.tag = tag
    }

    public func postPaste() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyV, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            tag.mark(event)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
