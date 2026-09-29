import AppKit
import PappuSettings

/// The app's updater, or none (PRD §11.4). Only a build made by Scripts/release.sh compiles Sparkle in
/// (`PAPPU_SPARKLE`, project.yml says why); in every other build this is nil and Settings → App says the
/// build does not update itself.
enum Updates {
    @MainActor
    static func make() -> (any SoftwareUpdating)? {
        #if PAPPU_SPARKLE
        SparkleUpdater.make()
        #else
        nil
        #endif
    }
}

#if PAPPU_SPARKLE
@preconcurrency import Sparkle

/// Sparkle 2 behind `SoftwareUpdating` (PRD §11.4, architecture §15): the only file that imports it, so
/// PappuKit and its tests never link Sparkle.
///
/// **Not sandboxed, so no installer services.** The app is not sandboxed (architecture §13.1), so
/// Sparkle installs in-process through its `Autoupdate` tool and needs neither
/// `SUEnableInstallerLauncherService` nor `SUEnableDownloaderService`. The update replaces the whole
/// bundle, the two XPC helpers inside it included; launchd ends the old helpers with the app that
/// Sparkle terminates, and the relaunched app starts the new ones on first use. The JavaScript helper's
/// sandbox is its own and is untouched by any of this.
///
/// **EdDSA only.** Every archive is checked against `SUPublicEDKey` before it is installed, and
/// `SUVerifyUpdateBeforeExtraction` makes Sparkle check it before unpacking, not after.
@MainActor
final class SparkleUpdater: NSObject, SoftwareUpdating {
    private var controller: SPUStandardUpdaterController!
    var channel: UpdateChannel = .stable

    /// Nil unless this bundle names an update feed and carries an EdDSA public key, which only a
    /// release build made by Scripts/release.sh does. Every other build has no updater at all.
    static func make(bundle: Bundle = .main) -> SparkleUpdater? {
        let info = bundle.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !key.isEmpty, let url = URL(string: feed), url.scheme == "https" else { return nil }
        return SparkleUpdater()
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    private var updater: SPUUpdater { controller.updater }

    func start() {
        controller.startUpdater()
    }

    var policy: UpdatePolicy {
        get {
            UpdatePolicy(
                automaticallyChecks: updater.automaticallyChecksForUpdates,
                automaticallyDownloads: updater.automaticallyDownloadsUpdates
            )
        }
        set {
            updater.automaticallyChecksForUpdates = newValue.automaticallyChecks
            updater.automaticallyDownloadsUpdates = newValue.automaticallyDownloads
        }
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var lastCheck: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        // An agent app's windows only come forward once the app is active (as for Settings).
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    /// "Include beta versions": the default channel always, and "beta" as well when it is on.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { channel.allowedChannels }
    }
}

extension SparkleUpdater: SPUStandardUserDriverDelegate {
    /// A menu bar agent has no Dock icon to badge, so a scheduled update that finds something is shown
    /// gently: Sparkle brings its window up without stealing focus from the app being typed in.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, state.userInitiated else { return }
        MainActor.assumeIsolated { NSApp.activate() }
    }
}
#endif
