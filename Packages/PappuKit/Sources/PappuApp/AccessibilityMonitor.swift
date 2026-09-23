import AppKit
import ApplicationServices
import Foundation
import PappuCore
import Synchronization

/// The seam between the monitor and the trust database: `TrustDatabaseWatcher` in the app, a fake in
/// tests, which have no trust database to change.
public protocol AccessibilityTrustWatching: Sendable {
    /// Calling `start` twice must not subscribe twice.
    func start(_ fire: @escaping @Sendable () -> Void)
    func stop()
}

/// ONB-1's "detect the grant live", as macOS offers it: a distributed notification posted when the
/// Accessibility trust database changes.
///
/// It is undocumented and it is the only notice there is — the alternative is polling `AXIsProcessTrusted`
/// on a timer, which would be a timer running for the life of the app to catch something that happens
/// once. It arrives a moment after the tick, from another process, so what the monitor does with it is
/// *re-read* rather than believe: the notification says "look again", never "you are trusted now".
public final class TrustDatabaseWatcher: AccessibilityTrustWatching {
    /// Posted by the system when any app's Accessibility trust changes, not only ours.
    static let notification = Notification.Name("com.apple.accessibility.api")

    private let token = Mutex<(any NSObjectProtocol)?>(nil)

    public init() {}

    deinit {
        stop()
    }

    public func start(_ fire: @escaping @Sendable () -> Void) {
        token.withLock { token in
            guard token == nil else { return }
            token = DistributedNotificationCenter.default().addObserver(
                forName: Self.notification,
                object: nil,
                queue: .main
            ) { _ in fire() }
        }
    }

    public func stop() {
        token.withLock { token in
            guard let current = token else { return }
            DistributedNotificationCenter.default().removeObserver(current)
            token = nil
        }
    }
}

/// Where the app stands with Accessibility, kept current for as long as it runs (ONB-1, ONB-4).
///
/// Two facts make the answer and they come from different places. Whether the user has ticked the box is
/// `AXIsProcessTrusted`, which is cheap, never prompts, and can change while the app runs. Whether the
/// tick means anything is only answered by trying: `EventTapService.start()` returns false for a trusted
/// process whose signature the trust database no longer recognises, which is ONB-4's stale grant. The
/// monitor holds both and hands `AccessibilityGrant` the pair; the rule about what they add up to is
/// that type's, and is tested without any of this.
///
/// **Why the tap answer is forgotten when trust goes away.** A user who removes the app from the list
/// and puts it back has a fresh grant, and the refusal that was recorded against the old signature says
/// nothing about the new one. Keeping it would leave the app claiming a stale grant — and showing the
/// repair screen — for a permission that was just granted and never tried.
public final class AccessibilityMonitor: Sendable {
    private let store: OnboardingStore
    private let watcher: any AccessibilityTrustWatching
    private let isTrusted: @Sendable () -> Bool
    /// Nil until something has tried to install a tap.
    private let tapWasCreated = Mutex<Bool?>(nil)

    public init(
        store: OnboardingStore,
        watcher: any AccessibilityTrustWatching = TrustDatabaseWatcher(),
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.store = store
        self.watcher = watcher
        self.isTrusted = isTrusted
    }

    deinit {
        watcher.stop()
    }

    /// Reads the grant as it stands and keeps reading it on every notice. Called once, at launch, before
    /// anything asks the store what to show.
    public func start() {
        // Weak, so that a subscription the app forgot to stop does not keep the monitor and the store
        // alive past them.
        watcher.start { [weak self] in self?.refresh() }
        refresh()
    }

    public func stop() {
        watcher.stop()
    }

    /// What `EventTapService.start()` answered. The one fact `AXIsProcessTrusted` cannot give.
    public func noteTap(created: Bool) {
        tapWasCreated.withLock { $0 = created }
        refresh()
    }

    /// Re-reads both facts and tells the store. Safe to call as often as anything likes: the store
    /// announces only a change, so a notice that was about another app's grant costs two reads and
    /// nothing else.
    public func refresh() {
        let trusted = isTrusted()
        let tap = tapWasCreated.withLock { answer -> Bool? in
            if !trusted { answer = nil }
            return answer
        }
        store.noteGrant(AccessibilityGrant(isTrusted: trusted, tapWasCreated: tap))
    }

    // MARK: What the onboarding screens do (ONB-1)

    /// The system's own prompt, which is the only way to get the app into the Accessibility list in the
    /// first place. It shows once per install for an untrusted process and does nothing afterwards, which
    /// is why `openSystemSettings()` exists beside it rather than instead of it.
    @MainActor
    public func requestGrant() {
        // The string value of kAXTrustedCheckOptionPrompt, which Swift 6 sees as unsafe shared state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// ONB-1's "direct link to the right System Settings pane".
    @MainActor
    public func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
