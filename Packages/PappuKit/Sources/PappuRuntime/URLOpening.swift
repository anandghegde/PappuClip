import AppKit
import Foundation

/// One address to open, and how (PRD §7.4).
public struct URLOpenRequest: Sendable, Equatable {
    public var url: URL
    /// Whether the browser comes to the front. `false` is PRD §7.4's ⇧ modifier — "open in a background
    /// tab" — which is the same open with `NSWorkspace.OpenConfiguration.activates` turned off.
    public var activates: Bool
    /// The browser to open in, or nil for the user's default.
    ///
    /// PRD §7.4: "searches and links open in the current app if it is a known browser, otherwise in the
    /// default browser." The *current app* is the point — somebody reading in Safari with Chrome as
    /// their default wants the tab where they are reading, not the other browser.
    public var browserBundleID: String?

    public init(url: URL, activates: Bool = true, browserBundleID: String? = nil) {
        self.url = url
        self.activates = activates
        self.browserBundleID = browserBundleID
    }
}

/// Opens addresses. A seam, so that Search and Open Link are testable without a browser.
public protocol URLOpening: Sendable {
    /// Opens each request, **in order**, and answers how many were accepted.
    ///
    /// The order is part of the contract rather than an accident of the implementation: Open Link on a
    /// selection holding three links should leave three tabs in the order they were written, which is
    /// the only arrangement a user can predict.
    func open(_ requests: [URLOpenRequest]) async -> Int
}

/// `NSWorkspace`, behind the seam (architecture §8.7).
public struct SystemURLOpener: URLOpening {
    public init() {}

    public func open(_ requests: [URLOpenRequest]) async -> Int {
        var opened = 0
        // Sequentially, and awaited: `NSWorkspace.open` returns as soon as the launch is under way, and
        // a browser handed three addresses at once opens them in whatever order its own queue settles
        // on — which is the tab order the user then has to read.
        for request in requests {
            if await open(request) { opened += 1 }
        }
        return opened
    }

    /// One open. On the main actor because `NSWorkspace.OpenConfiguration` is a non-`Sendable` class,
    /// not because opening an address is a UI operation.
    @MainActor
    private func open(_ request: URLOpenRequest) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = request.activates

        let workspace = NSWorkspace.shared
        let application = request.browserBundleID
            .flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }

        return await withCheckedContinuation { continuation in
            let finish: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
                continuation.resume(returning: error == nil)
            }
            if let application {
                workspace.open(
                    [request.url],
                    withApplicationAt: application,
                    configuration: configuration,
                    completionHandler: finish
                )
            } else {
                // The default handler for the scheme. `omnifocus:` and `mailto:` arrive here too, and
                // that is exactly right for them: Open Link's job is to hand the address to whatever
                // the user has said should have it.
                workspace.open(request.url, configuration: configuration, completionHandler: finish)
            }
        }
    }
}
