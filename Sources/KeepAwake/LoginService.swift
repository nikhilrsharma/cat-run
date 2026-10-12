import Foundation
import ServiceManagement

protocol LoginServiceBackend {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

enum LoginServiceError: LocalizedError, Equatable {
    case registrationNotConfirmed
    case removalNotConfirmed

    var errorDescription: String? {
        switch self {
        case .registrationNotConfirmed: return "macOS did not confirm launch at login."
        case .removalNotConfirmed: return "macOS did not confirm that launch at login was turned off."
        }
    }
}

/// Changes registration only on an explicit request; the operating system remains authoritative.
final class LoginService {
    private let backend: LoginServiceBackend

    init() { backend = SystemLoginServiceBackend() }
    init(backend: LoginServiceBackend) { self.backend = backend }

    var status: SMAppService.Status { backend.status }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            switch backend.status {
            case .enabled:
                return
            case .requiresApproval:
                openSystemSettings()
                return
            case .notRegistered, .notFound:
                try backend.register()
            @unknown default:
                try backend.register()
            }
            switch backend.status {
            case .enabled:
                return
            case .requiresApproval:
                openSystemSettings()
            default:
                throw LoginServiceError.registrationNotConfirmed
            }
        } else {
            switch backend.status {
            case .notRegistered, .notFound:
                return
            default:
                try backend.unregister()
            }
            switch backend.status {
            case .notRegistered, .notFound:
                return
            default:
                throw LoginServiceError.removalNotConfirmed
            }
        }
    }

    func openSystemSettings() { backend.openSystemSettings() }
}

private final class SystemLoginServiceBackend: LoginServiceBackend {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
