import Foundation
import PappuCore

/// PRD §7.5's three Software Update choices, as one value (PRD §11.4).
///
/// Sparkle keeps two switches — check automatically, and download and install automatically — and the
/// second means nothing without the first. Three states are what those two can honestly say, so the
/// window offers three and the mapping lives here rather than in a view.
public enum UpdatePolicy: String, Sendable, CaseIterable, Codable {
    case off
    case notifyOnly
    case installAutomatically

    public init(automaticallyChecks: Bool, automaticallyDownloads: Bool) {
        self = !automaticallyChecks ? .off : automaticallyDownloads ? .installAutomatically : .notifyOnly
    }

    public var automaticallyChecks: Bool { self != .off }
    public var automaticallyDownloads: Bool { self == .installAutomatically }
}

/// Which releases the app is offered: the stable ones, or those and the betas ("include betas").
///
/// Sparkle's channels: an appcast item with no `sparkle:channel` is on the default channel, which
/// every copy of the app sees; a beta is published with `<sparkle:channel>beta</sparkle:channel>`
/// (Scripts/appcast.sh `--channel beta`) and is seen only by a copy that allows that channel.
public enum UpdateChannel: String, Sendable, CaseIterable, Codable {
    case stable
    case beta

    /// The appcast channel name a beta is published under.
    public static let betaChannelName = "beta"

    /// What `SPUUpdaterDelegate.allowedChannels(for:)` answers. The default channel is always allowed.
    public var allowedChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: [Self.betaChannelName]
        }
    }
}

/// The update channel, remembered. The policy is not here: Sparkle keeps its own two switches in the
/// app's defaults, and a second copy of them would be a second answer to get out of step.
public final class UpdatePreferences: Sendable {
    public static let channelKey = "update.channel"

    private let value: SettingsValue<UpdateChannel>

    public init(storage: any SettingsStorage) {
        value = SettingsValue(key: Self.channelKey, default: .stable, storage: storage)
    }

    public var channel: UpdateChannel { value.value }

    public func setChannel(_ channel: UpdateChannel) { value.set(channel) }

    public func onChange(_ body: @escaping @Sendable (UpdateChannel) -> Void) { value.onChange(body) }
}

/// The app's updater, as the App tab and the assembly see it (PRD §11.4).
///
/// A protocol so that nothing in PappuKit links Sparkle: the one conformance that does is
/// `SparkleUpdater`, in the app target, and a build without an update feed or an EdDSA key (every
/// development build) has no updater at all. Tests use a fake.
@MainActor
public protocol SoftwareUpdating: AnyObject {
    /// Starts the scheduler. Called once, after `channel` has been set from the stored preference, so
    /// the first check already asks for the right channel.
    func start()
    var policy: UpdatePolicy { get set }
    var channel: UpdateChannel { get set }
    /// False while a check or an install is already under way.
    var canCheckForUpdates: Bool { get }
    /// The user's "Check for Updates Now": Sparkle's own window says what it found.
    func checkForUpdates()
    var lastCheck: Date? { get }
}

/// "Start at login" (PRD §7.5), over `SMAppService.mainApp` in the app.
public enum LoginItemState: Sendable, Equatable {
    case on
    case off
    /// Registered, but the user has to allow it in System Settings → General → Login Items.
    case needsApproval
    /// This copy cannot register itself — typically a build run from somewhere other than Applications
    /// with an identity System Settings will not show.
    case unavailable
}

@MainActor
public protocol LoginItemControlling: AnyObject {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}
