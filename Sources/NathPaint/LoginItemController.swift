import Combine
import Foundation
import ServiceManagement
import PaintCore

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

private struct SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemServicing

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    convenience init() {
        self.init(service: SystemLoginItemService())
    }

    init(service: any LoginItemServicing) {
        self.service = service
        status = service.status
        errorMessage = nil
    }

    func refresh() {
        status = service.status
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        refresh()

        if enabled == isEnabled {
            return
        }

        do {
            if enabled {
                try service.register()
            } else if status == .enabled || status == .requiresApproval {
                try service.unregister()
            }
            refresh()
        } catch {
            // Read the service again after a failed operation. Registration may
            // have succeeded while reporting an approval or other transient error.
            status = service.status
            errorMessage = L10n.tr("Could not change launch at login: %@", error.localizedDescription)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
