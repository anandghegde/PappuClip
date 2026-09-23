import Foundation

/// Runs `body` on the main thread and waits for it.
///
/// The system-side adapters in this module need it: Carbon registers hot keys on the application event
/// target and `NSWorkspace` hands out its notifications there, while the components above them are
/// plain `Sendable` objects that a background thread may hold the last reference to. Inline when we
/// are already on the main thread, so a caller that is cannot deadlock against itself.
func onMainThread<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
}
