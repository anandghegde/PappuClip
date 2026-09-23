import Foundation
import Synchronization

/// What the onboarding screens read: one stored flag, and the Accessibility grant as last observed
/// (ONB-1, architecture §13).
///
/// The grant is not a setting and is deliberately not stored. It lives in the trust database, which the
/// user can change while the app is running and which a macOS upgrade can invalidate behind its back, so
/// a remembered copy would be a copy that is wrong exactly when it matters. What is stored is the one
/// thing the system cannot tell us: whether this user has already had the app explained to them.
///
/// The live observation arrives through `noteGrant(_:)`, from whatever is watching — the distributed
/// notification that the trust database has changed, and the tap the app tries to create. Everything
/// that cares is told (`onChange`), because ONB-1 asks for the grant to be detected *live*: the window
/// asking for it has to close itself.
public final class OnboardingStore: Sendable {
    public static let storageKey = "onboarding.welcomed"

    private let hasBeenWelcomed: SettingsValue<Bool>
    private let observed: Mutex<AccessibilityGrant>
    private let observers = Mutex<[@Sendable (OnboardingState) -> Void]>([])

    public init(storage: any SettingsStorage, grant: AccessibilityGrant = .notTrusted) {
        hasBeenWelcomed = SettingsValue(key: Self.storageKey, default: false, storage: storage)
        observed = Mutex(grant)
    }

    public var state: OnboardingState {
        OnboardingState(hasBeenWelcomed: hasBeenWelcomed.value, grant: observed.withLock { $0 })
    }

    public var grant: AccessibilityGrant { observed.withLock { $0 } }

    /// The user has read the explanation and pressed on. Nothing about the grant is claimed by this.
    public func finishWelcome() {
        guard !hasBeenWelcomed.value else { return }
        hasBeenWelcomed.set(true)
        announce()
    }

    /// What the watcher saw. A grant that has not changed announces nothing, so that a monitor which
    /// re-reads on every notification does not redraw the world each time.
    public func noteGrant(_ grant: AccessibilityGrant) {
        let changed = observed.withLock { observed -> Bool in
            guard observed != grant else { return false }
            observed = grant
            return true
        }
        guard changed else { return }
        announce()
    }

    public func onChange(_ body: @escaping @Sendable (OnboardingState) -> Void) {
        observers.withLock { $0.append(body) }
    }

    private func announce() {
        let state = state
        for observer in observers.withLock({ $0 }) { observer(state) }
    }
}
