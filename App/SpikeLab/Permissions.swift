import AppKit
import ApplicationServices

/// The three TCC states an event tap can depend on. Reading them never shows a prompt.
struct PermissionSnapshot: Equatable, Sendable {
    var accessibility: Bool
    /// "Input Monitoring" in System Settings.
    var listenEvent: Bool
    /// Covered by the Accessibility grant on the systems we have seen; spike 2 records both to check.
    var postEvent: Bool

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: AXIsProcessTrusted(),
            listenEvent: CGPreflightListenEventAccess(),
            postEvent: CGPreflightPostEventAccess()
        )
    }

    var summary: String {
        "accessibility=\(accessibility) inputMonitoring=\(listenEvent) postEvent=\(postEvent)"
    }
}

@MainActor
enum PermissionActions {
    static func promptForAccessibility() {
        // The string value of kAXTrustedCheckOptionPrompt, which Swift 6 sees as unsafe shared state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
