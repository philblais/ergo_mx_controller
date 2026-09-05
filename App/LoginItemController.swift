import Foundation
import MXErgoCore
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp`.
///
/// It reads and writes one system setting and holds no state of its own, so
/// the status shown is always what macOS currently believes rather than what
/// this app last asked for. Those differ: registration can succeed and still
/// need a person's approval before anything launches.
struct LoginItemController {
    var status: LoginItemRegistration {
        switch SMAppService.mainApp.status {
        case .enabled: .registered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    /// Throws rather than reporting success for a registration macOS refused.
    func setRegistered(_ isRegistered: Bool) throws {
        if isRegistered {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
