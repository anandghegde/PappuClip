import Foundation
import Observation
import PappuCore

/// Settings → App (PRD §7.5, §11.4), decided where a test can read it: the version, Software Update,
/// Start at login and the Debug Console.
///
/// The updater is optional because most builds have none. `SparkleUpdater` exists only in a release
/// build that carries an update feed and an EdDSA public key; a development build says so instead of
/// offering a button that could only fail.
@MainActor @Observable
public final class AppTabModel {
    /// The bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
    public struct Version: Sendable, Equatable {
        public var marketing: String
        public var build: String

        public init(marketing: String, build: String) {
            self.marketing = marketing
            self.build = build
        }

        public init(bundle: Bundle) {
            let info = bundle.infoDictionary ?? [:]
            self.init(
                marketing: info["CFBundleShortVersionString"] as? String ?? "0",
                build: info["CFBundleVersion"] as? String ?? "0"
            )
        }
    }

    /// A link in the About section: where the source is and where to report a problem.
    public struct Link: Sendable, Equatable, Identifiable {
        public var title: String
        public var url: URL

        public var id: URL { url }

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    public let version: Version
    public let links: [Link]
    private let updater: (any SoftwareUpdating)?
    private let preferences: UpdatePreferences
    private let loginItem: (any LoginItemControlling)?
    private let openURL: @MainActor (URL) -> Void
    private let openDebugConsole: @MainActor () -> Void

    // MARK: What the tab draws

    public private(set) var policy: UpdatePolicy
    public private(set) var channel: UpdateChannel
    public private(set) var canCheckForUpdates = false
    public private(set) var lastCheck: Date?
    public private(set) var loginItemState: LoginItemState = .unavailable
    /// Set when turning Start at login on or off failed, until the next attempt.
    public private(set) var loginItemFailure: String?

    public init(
        version: Version,
        links: [Link] = [],
        updater: (any SoftwareUpdating)?,
        preferences: UpdatePreferences,
        loginItem: (any LoginItemControlling)?,
        open: @escaping @MainActor (URL) -> Void = { _ in },
        openDebugConsole: @escaping @MainActor () -> Void = {}
    ) {
        self.version = version
        self.links = links
        self.updater = updater
        self.preferences = preferences
        self.loginItem = loginItem
        self.openURL = open
        self.openDebugConsole = openDebugConsole
        policy = updater?.policy ?? .off
        channel = preferences.channel
        refresh()
    }

    /// Reads the updater and the login item again. The window calls it when the tab appears, because
    /// both can change behind its back: Sparkle's own "Automatically download" checkbox writes the same
    /// switch, and the user can remove the login item in System Settings.
    public func refresh() {
        if let updater {
            policy = updater.policy
            canCheckForUpdates = updater.canCheckForUpdates
            lastCheck = updater.lastCheck
        }
        channel = preferences.channel
        loginItemState = loginItem?.state ?? .unavailable
    }

    // MARK: Version

    /// "Version 0.1.0 (12)".
    public var versionText: String { AppTabStrings.version(version.marketing, version.build) }

    // MARK: Software Update

    /// False in a build without an updater: the controls are drawn disabled and `updatesUnavailable` is
    /// said under them.
    public var updatesAvailable: Bool { updater != nil }

    public func setPolicy(_ policy: UpdatePolicy) {
        guard let updater else { return }
        updater.policy = policy
        refresh()
    }

    /// Stored first and handed to the updater second, so a relaunch finds the same channel even if the
    /// updater is not running.
    public func setChannel(_ channel: UpdateChannel) {
        preferences.setChannel(channel)
        updater?.channel = channel
        refresh()
    }

    public func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
        refresh()
    }

    public func lastCheckText(locale: Locale = .current) -> String {
        guard let lastCheck else { return AppTabStrings.neverChecked }
        let when = lastCheck.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return AppTabStrings.lastChecked(when)
    }

    // MARK: Start at login

    public var loginItemIsOn: Bool { loginItemState == .on || loginItemState == .needsApproval }
    public var loginItemIsAvailable: Bool { loginItem != nil && loginItemState != .unavailable }

    public func setStartAtLogin(_ on: Bool) {
        guard let loginItem else { return }
        do {
            try loginItem.setEnabled(on)
            loginItemFailure = nil
        } catch {
            loginItemFailure = AppTabStrings.loginItemFailed
        }
        refresh()
    }

    public func openLoginItemSettings() {
        loginItem?.openSystemSettings()
    }

    // MARK: Links and the console

    public func open(_ link: Link) {
        openURL(link.url)
    }

    public func showDebugConsole() {
        openDebugConsole()
    }
}
