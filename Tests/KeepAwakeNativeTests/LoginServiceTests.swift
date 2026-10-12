import ServiceManagement
import XCTest
@testable import KeepAwake

final class LoginServiceTests: XCTestCase {
    func testConstructionAndStatusReadsNeverChangeRegistration() {
        let backend = Backend(status: .notFound)
        let service = LoginService(backend: backend)
        XCTAssertEqual(service.status, .notFound)
        backend.status = .enabled
        XCTAssertEqual(service.status, .enabled)
        backend.status = .requiresApproval
        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertEqual(backend.mutations, [])
    }

    func testEnablingConfirmedRegistrationDoesNothing() throws {
        let backend = Backend(status: .enabled)
        try LoginService(backend: backend).setEnabled(true)
        XCTAssertEqual(backend.mutations, [])
    }

    func testConfirmedEnableWorksFromBothUnregisteredStates() throws {
        for initial in [SMAppService.Status.notFound, .notRegistered] {
            let backend = Backend(status: initial)
            backend.afterRegister = .enabled
            let service = LoginService(backend: backend)
            try service.setEnabled(true)
            XCTAssertEqual(service.status, .enabled)
            XCTAssertEqual(backend.mutations, [.register])
        }
    }

    func testNewPendingRegistrationOpensApprovalSettingsWithoutClaimingEnabled() throws {
        let backend = Backend(status: .notRegistered)
        backend.afterRegister = .requiresApproval
        let service = LoginService(backend: backend)
        try service.setEnabled(true)
        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertEqual(backend.mutations, [.register, .openSettings])
    }

    func testExistingPendingRegistrationOnlyOpensSettings() throws {
        let backend = Backend(status: .requiresApproval)
        try LoginService(backend: backend).setEnabled(true)
        XCTAssertEqual(backend.status, .requiresApproval)
        XCTAssertEqual(backend.mutations, [.openSettings])
    }

    func testRegistrationErrorPropagatesWithoutFabricatingEnabledState() {
        let backend = Backend(status: .notFound)
        backend.registerError = Failure.denied
        let service = LoginService(backend: backend)
        XCTAssertThrowsError(try service.setEnabled(true)) { XCTAssertEqual($0 as? Failure, .denied) }
        XCTAssertEqual(service.status, .notFound)
        XCTAssertEqual(backend.mutations, [.register])
    }

    func testNonthrowingRegistrationMustStillBeConfirmedByStatus() {
        for initial in [SMAppService.Status.notFound, .notRegistered] {
            let backend = Backend(status: initial)
            let service = LoginService(backend: backend)
            XCTAssertThrowsError(try service.setEnabled(true)) { XCTAssertEqual($0 as? LoginServiceError, .registrationNotConfirmed) }
            XCTAssertEqual(service.status, initial)
            XCTAssertEqual(backend.mutations, [.register])
        }
    }

    func testDisablingMissingOrUnregisteredServiceIsIdempotent() throws {
        for initial in [SMAppService.Status.notFound, .notRegistered] {
            let backend = Backend(status: initial)
            let service = LoginService(backend: backend)
            try service.setEnabled(false)
            try service.setEnabled(false)
            XCTAssertEqual(service.status, initial)
            XCTAssertEqual(backend.mutations, [])
        }
    }

    func testConfirmedRemovalWorksForEnabledAndPendingRegistration() throws {
        for initial in [SMAppService.Status.enabled, .requiresApproval] {
            for removed in [SMAppService.Status.notRegistered, .notFound] {
                let backend = Backend(status: initial)
                backend.afterUnregister = removed
                let service = LoginService(backend: backend)
                try service.setEnabled(false)
                XCTAssertEqual(service.status, removed)
                XCTAssertEqual(backend.mutations, [.unregister])
            }
        }
    }

    func testRemovalErrorPreservesReportedSystemState() {
        let backend = Backend(status: .enabled)
        backend.unregisterError = Failure.denied
        let service = LoginService(backend: backend)
        XCTAssertThrowsError(try service.setEnabled(false)) { XCTAssertEqual($0 as? Failure, .denied) }
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(backend.mutations, [.unregister])
    }

    func testNonthrowingRemovalMustStillBeConfirmedByStatus() {
        for initial in [SMAppService.Status.enabled, .requiresApproval] {
            let backend = Backend(status: initial)
            let service = LoginService(backend: backend)
            XCTAssertThrowsError(try service.setEnabled(false)) { XCTAssertEqual($0 as? LoginServiceError, .removalNotConfirmed) }
            XCTAssertEqual(service.status, initial)
            XCTAssertEqual(backend.mutations, [.unregister])
        }
    }

    private enum Failure: Error, Equatable { case denied }
    private final class Backend: LoginServiceBackend {
        enum Mutation: Equatable { case register, unregister, openSettings }
        var status: SMAppService.Status
        var afterRegister: SMAppService.Status?
        var afterUnregister: SMAppService.Status?
        var registerError: Error?
        var unregisterError: Error?
        var mutations: [Mutation] = []

        init(status: SMAppService.Status) { self.status = status }
        func register() throws {
            mutations.append(.register)
            if let registerError { throw registerError }
            if let afterRegister { status = afterRegister }
        }
        func unregister() throws {
            mutations.append(.unregister)
            if let unregisterError { throw unregisterError }
            if let afterUnregister { status = afterUnregister }
        }
        func openSystemSettings() { mutations.append(.openSettings) }
    }
}
