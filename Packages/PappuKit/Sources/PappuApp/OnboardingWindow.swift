import AppKit
import SwiftUI

/// The window the onboarding screens live in (ONB-1).
///
/// Built at launch whether or not it is shown, because what decides is the model — a launch of a
/// welcomed install with a grant that works is owed nothing and opens nothing. `show()` is called at first run and again from
/// the menu's "Accessibility Permission Needed…", which is the way back for a user who closed this and
/// wants it again, or whose grant was revoked while the app was running.
///
/// It closes itself. ONB-1 asks for the permission request to end when the permission arrives, and the
/// model's `onFinish` is what says so; there is no Done button, because there is nothing left to do by
/// the time one could be pressed.
@MainActor
public final class OnboardingWindow {
    private let model: OnboardingModel
    private var window: NSWindow?

    public init(model: OnboardingModel) {
        self.model = model
        model.onFinish = { [weak self] in self?.close() }
    }

    /// Whether there is anything to show. The caller at launch asks this first, so that an ordinary
    /// second launch opens no window at all.
    public var hasSomethingToShow: Bool { model.hasSomethingToShow }

    public func show() {
        let window = window ?? make()
        self.window = window
        // An agent app is not the active app until it says so, and an inactive app's window cannot take
        // focus — without this the first thing a new user sees is hidden behind their other windows.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.performClose(nil)
    }

    public var isOpen: Bool { window?.isVisible == true }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        window.title = AppStrings.onboardingWindowTitle
        // Closing onboarding is not quitting; an agent app holds nothing else, and releasing the window
        // here would take the view down while the model it was watching lives on.
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
