import AppKit
import SwiftUI

/// The window the Settings view lives in, and the only file in this module that makes one (PRD §7.5).
///
/// It is an ordinary titled window, not a panel: unlike the bar, this is a place the user goes to work,
/// and it should behave like every other settings window on the machine — key, resizable within reason,
/// closable, and remembered where they left it.
///
/// PappuClip is an agent app (`LSUIElement`), which has two consequences this file has to deal with.
/// The app has to be activated by hand before its window can take focus, because nothing else will do
/// it; and there is no visible menu bar, so ⌘W is handled here rather than relying on a File menu the
/// user cannot see.
@MainActor
public final class SettingsWindow {
    private let model: SettingsModel
    private var window: NSWindow?

    public init(model: SettingsModel) {
        self.model = model
    }

    /// Opens the window, or brings the one that already exists back to the front. Called from the menu
    /// bar's Settings item (ACT-18) and from the onboarding window when it hands the user on.
    public func show(tab: SettingsView.Tab = .general) {
        // The settings the window draws are read when it is made, and again on every store change; a
        // window that has been sitting closed for an hour is no more stale than one left open, so
        // reusing it is safe as well as cheaper than rebuilding the view.
        let window = window ?? make(tab: tab)
        self.window = window
        // An agent app is never the active app until it says so, and an inactive app's window cannot
        // become key: without this the window appears behind whatever the user was working in.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.performClose(nil)
    }

    public var isOpen: Bool { window?.isVisible == true }

    private func make(tab: SettingsView.Tab) -> NSWindow {
        let window = SettingsPanelWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, tab: tab))
        window.title = SettingsStrings.windowTitle
        // Closing a settings window is not quitting the app, and an agent app has nothing else holding
        // it: releasing it on close would take the window's contents down with it while the app lives on.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("app.pappuclip.settings")
        if window.frameAutosaveName.isEmpty || window.frame.origin == .zero {
            window.center()
        }
        return window
    }
}

/// ⌘W, for a window in an app with no menu bar to put it in.
private final class SettingsPanelWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandW = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "w"
        guard isCommandW else { return super.performKeyEquivalent(with: event) }
        performClose(nil)
        return true
    }
}
