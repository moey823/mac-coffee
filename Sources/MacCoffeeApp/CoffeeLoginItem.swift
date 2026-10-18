import Combine
import ServiceManagement

@MainActor
final class CoffeeLoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool {
        if case .enabled = status { return true }
        return false
    }

    var needsApproval: Bool {
        if case .requiresApproval = status { return true }
        return false
    }

    var statusDescription: String {
        switch status {
        case .notRegistered:
            "Mac Coffee will not open automatically at login."
        case .enabled:
            "Mac Coffee opens automatically when you log in."
        case .requiresApproval:
            "Approve Mac Coffee in System Settings > General > Login Items."
        case .notFound:
            "Mac Coffee's login item is unavailable."
        @unknown default:
            "Mac Coffee's login item status is unavailable."
        }
    }

    init() {
        status = SMAppService.mainApp.status
    }

    func refreshStatus() {
        status = SMAppService.mainApp.status
        if case .requiresApproval = status {
            errorMessage = "Approve Mac Coffee in System Settings > General > Login Items."
        } else {
            errorMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refreshStatus()
        var operationError: String?

        if enabled {
            if case .enabled = status { return }
            if case .requiresApproval = status {
                errorMessage = "Approve Mac Coffee in System Settings > General > Login Items."
                return
            }
            do {
                try SMAppService.mainApp.register()
            } catch {
                operationError = "Could not enable opening at login: \(error.localizedDescription)"
            }
        } else {
            if case .notRegistered = status { return }
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                operationError = "Could not disable opening at login: \(error.localizedDescription)"
            }
        }
        refreshStatus()
        if let operationError {
            errorMessage = operationError
        }
    }
}
