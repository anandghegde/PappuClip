import Foundation
import PappuCore

/// What the onboarding window shows and what its buttons do (ONB-1).
///
/// The rule about *which* screen is owed is `OnboardingState`'s and is tested without any of this. What
/// is here is the part that has a window attached: the screen as a thing a view can watch, the two
/// buttons, and the one behaviour ONB-1 names that a value type cannot express — the window asking for
/// the permission closes itself the moment the permission arrives, rather than leaving a Done button
/// for something already done.
///
/// The grant arrives from `AccessibilityMonitor` on whatever thread the trust database's notification
/// came in on, so every path back into here goes through the main actor before a view reads it.
@MainActor
@Observable
public final class OnboardingModel {
    private let store: OnboardingStore
    private let requestGrant: @MainActor () -> Void
    private let openAccessibilitySettings: @MainActor () -> Void

    public private(set) var screen: OnboardingState.Screen = .welcome

    /// Set by the window once it exists, because the model is built first and neither can be second
    /// twice. Called when there is nothing left to ask the user for.
    public var onFinish: (@MainActor () -> Void)?

    public init(
        store: OnboardingStore,
        requestGrant: @escaping @MainActor () -> Void = {},
        openAccessibilitySettings: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.requestGrant = requestGrant
        self.openAccessibilitySettings = openAccessibilitySettings
        refresh()
        let observe: @Sendable () -> Void = { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
        store.onChange { _ in observe() }
    }

    /// Whether there is anything to show at all. A launch that finds a working grant opens no window.
    public var hasSomethingToShow: Bool { screen != .none }

    public func refresh() {
        let state = store.state
        screen = state.screen
        if state.closesItself { onFinish?() }
    }

    /// The welcome screen's one button: the explanation has been read, so remember that and ask.
    ///
    /// The order is the point. `finishWelcome` first, because the system's prompt is the only way into
    /// the Accessibility list and it appears once per install for an untrusted process — a user who
    /// dismissed it still has to be told where the list is, which is the screen this moves on to.
    public func welcomeRead() {
        store.finishWelcome()
        guard screen == .permission else { return }
        requestGrant()
    }

    /// ONB-1's direct link. It opens the pane and claims nothing: the answer comes back through the
    /// trust database, not from this call.
    public func openAccessibilityPane() {
        openAccessibilitySettings()
    }
}
