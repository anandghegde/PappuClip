import Foundation

/// The app the selection came from (FLT-3), and what `requiredApps` and `excludedApps` are matched
/// against (§8.5, ALM-8).
///
/// The bundle identifier is the part that matters to a rule; the name is the part that matters to a
/// person, in the bar's messages and in the inspector. Both may be missing: a process with no bundle —
/// a command-line tool that put up a window, a helper — still has a pid and still has a selection.
public struct AppIdentity: Sendable, Equatable, Hashable, Codable {
    public let pid: pid_t
    public let bundleID: String?
    /// Localised, because it is only ever shown and never matched on.
    public let name: String?

    public init(pid: pid_t, bundleID: String?, name: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }

    /// What to call the app in a sentence, when there is nothing better than its pid.
    public var displayName: String {
        name ?? bundleID ?? "process \(pid)"
    }
}

/// What an app calls itself.
///
/// A seam of one call, because it is the only thing `ContextProbe` needs from AppKit: the rest of the
/// context comes through `AXWorld`, which is already injectable. Keeping it separate means the probe's
/// tests need no running application, which is the only way they can run in CI at all.
public protocol AppNaming: Sendable {
    func name(of pid: pid_t) -> String?
}

/// Answers nothing, for the callers with no use for a name and for a world with no window server.
public struct NoAppNames: AppNaming {
    public init() {}

    public func name(of pid: pid_t) -> String? { nil }
}
