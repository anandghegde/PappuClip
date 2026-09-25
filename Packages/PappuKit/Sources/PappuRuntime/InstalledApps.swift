import AppKit
import Foundation

/// Whether an application is installed, by bundle identifier (EXM-10). A seam, so the runner's tests
/// do not depend on what the machine running them has installed.
public protocol InstalledAppChecking: Sendable {
    func isInstalled(_ bundleIdentifier: String) -> Bool
}

/// For a runner assembled without the check: every app is there, so nothing is stopped for one.
public struct EveryAppInstalled: InstalledAppChecking {
    public init() {}

    public func isInstalled(_ bundleIdentifier: String) -> Bool { true }
}

/// Launch Services: an app is installed when it knows where one with that identifier is.
public struct SystemInstalledApps: InstalledAppChecking {
    public init() {}

    public func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
