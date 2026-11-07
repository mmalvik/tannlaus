import os
import ServiceManagement
import TannlausCore

/// Launch at login through `SMAppService.mainApp`. Needing approval opens Login Items.
@MainActor
struct LoginItem {
    private let service = SMAppService.mainApp
    private let logger = Logger(category: "login")

    var status: SMAppService.Status {
        service.status
    }

    func toggle() {
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                logger.info("Launch at login turned off")
            case .requiresApproval:
                break // Opened below.
            default:
                try service.register()
                logger.info("Launch at login turned on")
            }
        } catch {
            logger.error("Changing launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        if service.status == .requiresApproval {
            logger.info("Launch at login needs approval; opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
