import AppKit
import Foundation
import PappuCore
import PappuSelection
import Synchronization

/// Which app the user is working in, kept current so that anything may ask at any moment (FLT-3).
///
/// Four things need it — the gate's target, the coordinator's attempt, the destination verifier and the
/// bar's messages — and none of them can ask AppKit for it. `NSWorkspace.frontmostApplication` is a
/// main-thread read of a live object, and those four run on the tap's thread, on an actor and inside an
/// invocation, where they must answer at once and cannot hop. So it is read once at launch and then
/// kept current from the same activation notice `AttemptWatcher` already listens to, and what they are
/// handed is a closure over two stored values.
///
/// **Our own windows are not the app in front.** Settings and onboarding are ordinary windows and
/// opening one makes PappuClip the active app. If that counted, a shortcut pressed straight afterwards
/// would aim at PappuClip: the gate would judge our own bundle identifier, the reader would ask our own
/// process for its selection, and the bar would appear over a window with nothing in it. What the
/// product means by "the app in front" is the app the text is in, so our own activations are ignored
/// and the last other app stands until a real one replaces it.
public final class FrontmostApp: Sendable {
    private let activations: any ApplicationActivationWatching
    private let ours: pid_t
    private let app: Mutex<TargetApp?>

    /// - Parameters:
    ///   - initial: The app in front at launch, since the first activation notice may be a long way
    ///     off — the user can select text in the app they were already in.
    ///   - ours: This process. Named rather than read here so the rule can be tested without one.
    public init(
        activations: any ApplicationActivationWatching = WorkspaceActivationWatcher(),
        initial: TargetApp? = nil,
        ours: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.activations = activations
        self.ours = ours
        app = Mutex(initial.flatMap { $0.pid == ours ? nil : $0 })
    }

    deinit {
        activations.stop()
    }

    public func start() {
        // Weak, so a subscription nobody stopped does not keep this alive past the app.
        activations.start { [weak self] app in self?.note(app) }
    }

    public func stop() {
        activations.stop()
    }

    public var current: TargetApp? { app.withLock { $0 } }

    /// What everything downstream is built with (architecture §4.4): a closure, so that the app which
    /// came forward a moment ago is the one the next attempt is judged against.
    public var reader: @Sendable () -> TargetApp? {
        // Strongly, and deliberately: what is handed the reader is machinery that outlives no part of
        // the app, and a closure that quietly started returning nil would look like a system with
        // nothing in front of it rather than a mistake.
        { [self] in current }
    }

    private func note(_ next: TargetApp) {
        guard next.pid != ours else { return }
        app.withLock { $0 = next }
    }

    /// The app in front as `NSWorkspace` has it, for the one read at launch.
    @MainActor
    public static var system: TargetApp? {
        NSWorkspace.shared.frontmostApplication.map {
            TargetApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier)
        }
    }
}
