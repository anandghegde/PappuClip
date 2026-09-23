import CoreGraphics

/// The app's ⌘C (ACT-10d, architecture §4.5 strategy 5).
///
/// Three details, all of which matter:
///
/// - **The tag.** Both events carry the launch's `SyntheticEventTag` in `eventSourceUserData`, which is
///   what makes `TapInput.init(type:event:ownTag:)` drop them. That is why "the input epoch leaves out
///   our own ⌘C" is a property of the taps and not something the broker has to remember.
/// - **The flags are set, not added.** `flags = .maskCommand` clears whatever the user is holding, so a
///   ⌘C posted while Shift is down does not arrive as ⇧⌘C and do something else entirely.
/// - **`cghidEventTap`.** Posted at the bottom of the stack, as M0 spike 6 posted it, so that the event
///   goes through the same path a real key press does and every tap above sees it — including ours,
///   which is what the tag is for.
public struct SystemSyntheticCopy: SyntheticCopyPosting {
    /// `kVK_ANSI_C`, spelled out so this file needs no Carbon import.
    private static let keyC: CGKeyCode = 0x08

    private let tag: SyntheticEventTag

    public init(tag: SyntheticEventTag) {
        self.tag = tag
    }

    public func postCopy() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyC, keyDown: false)
        else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            tag.mark(event)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
