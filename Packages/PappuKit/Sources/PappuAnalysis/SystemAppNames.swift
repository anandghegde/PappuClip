import AppKit
import Foundation

/// `NSRunningApplication`, which is where architecture §6.2 says the name comes from.
///
/// A local lookup against the workspace's own table: it sends the app nothing and cannot block on it,
/// which is why it is not on `AXActor`'s queue with everything else the probe does.
public struct SystemAppNames: AppNaming {
    public init() {}

    public func name(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
