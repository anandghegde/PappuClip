import AppKit
import PappuSelection
import SwiftUI

/// The shortcut recorder of PRD §7.5: what the shortcut is now, and a way to change it (ACT-5).
///
/// Pressing the field starts listening; the next key press is the shortcut. Escape stops listening and
/// changes nothing, which is the one key a recorder must not record, because it is the only way out of
/// one.
///
/// The keys are read from `NSEvent` rather than SwiftUI's `onKeyPress`, and the reason is the key *code*.
/// `RegisterEventHotKey` takes a virtual key code — a position on the keyboard — while `KeyPress` reports
/// the character the layout produced. Recording through the character would mean translating it back to
/// a code through a table of one layout, and a French user's shortcut would land on the wrong key. The
/// code is what the system wants and what `NSEvent` already has.
struct ShortcutField: View {
    let shortcut: HotkeyShortcut?
    /// False when ACT-5 refused it, in which case recording stops anyway: the reason appears under the
    /// field and the user can try again.
    let record: (HotkeyShortcut) -> Bool
    let clear: () -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            Button(label) { isRecording.toggle() }
                .help(SettingsStrings.shortcutRecord)
                .background {
                    // Zero-sized and first responder: a control that is only an event sink, so that the
                    // button above keeps every pixel of AppKit's own drawing.
                    KeySink(isRecording: isRecording, heard: heard)
                        .frame(width: 0, height: 0)
                }
            Button(SettingsStrings.shortcutClear) {
                isRecording = false
                clear()
            }
            .disabled(shortcut == nil)
        }
    }

    private var label: String {
        if isRecording { return SettingsStrings.shortcutRecording }
        return shortcut.map(ShortcutText.describe) ?? SettingsStrings.shortcutNone
    }

    private func heard(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        // Escape on its own is how the user gets out. Escape *with* a modifier is a shortcut like any
        // other, and refusing it would be refusing something ACT-5 allows.
        let flags = PointerEvent.Modifiers(modifiers)
        if keyCode == KeySinkView.escapeKeyCode, flags.isDisjoint(with: [.control, .option, .command]) {
            isRecording = false
            return
        }
        isRecording = false
        // The answer is already on screen either way: a shortcut that took is in the field, and one that
        // did not is the sentence under it (`SettingsModel.shortcutRefusal`).
        _ = record(HotkeyShortcut(keyCode: keyCode, modifiers: flags))
    }
}

/// An `NSView` whose whole job is to be the first responder while a shortcut is being recorded.
private struct KeySink: NSViewRepresentable {
    let isRecording: Bool
    let heard: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> KeySinkView {
        let view = KeySinkView()
        view.heard = heard
        return view
    }

    func updateNSView(_ view: KeySinkView, context: Context) {
        view.heard = heard
        view.isListening = isRecording
    }
}

final class KeySinkView: NSView {
    static let escapeKeyCode: UInt16 = 53

    var heard: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    var isListening = false {
        didSet {
            guard isListening != oldValue else { return }
            takeOrGiveUpFocus()
        }
    }

    override var acceptsFirstResponder: Bool { isListening }

    /// The window may not exist yet when the flag is set — a sheet's contents are made before they are
    /// on screen — so the focus is taken again on arrival.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeOrGiveUpFocus()
    }

    override func keyDown(with event: NSEvent) {
        guard isListening else {
            super.keyDown(with: event)
            return
        }
        heard?(event.keyCode, event.modifierFlags)
    }

    /// ACT-5 needs ⌃, ⌥ or ⌘, and every one of those is a key equivalent: without this the menu bar
    /// answers first and the recorder never hears ⌘-anything.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isListening, window?.firstResponder === self else { return false }
        heard?(event.keyCode, event.modifierFlags)
        return true
    }

    private func takeOrGiveUpFocus() {
        guard let window else { return }
        if isListening {
            window.makeFirstResponder(self)
        } else if window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
    }
}
