import Foundation
import PappuSettings
import ServiceManagement

/// "Start at login" (PRD §7.5, architecture §2): the app itself as a login item, through
/// `SMAppService.mainApp`. Nothing is copied into a LaunchAgents folder; System Settings → General →
/// Login Items lists the app under its own name, and removing it there is the same as switching it off.
@MainActor
public final class SystemLoginItem: LoginItemControlling {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public var state: LoginItemState {
        switch service.status {
        case .enabled: .on
        case .notRegistered: .off
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
