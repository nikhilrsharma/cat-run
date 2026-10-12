import ServiceManagement
import XCTest
@testable import KeepAwake

final class LoginStatusTextTests: XCTestCase {
    func testNeverRegisteredAndDisabledServicesDoNotShowAnUnsolicitedError() {
        for status in [SMAppService.Status.notFound, .notRegistered, .enabled] {
            XCTAssertEqual(LoginStatusText.note(for: status), "")
        }
    }

    func testFailedEnableShowsErrorOnlyWhileRegistrationRemainsUnconfirmed() {
        for status in [SMAppService.Status.notFound, .notRegistered] {
            XCTAssertEqual(LoginStatusText.note(for: status, failedRequest: true),
                           "Could not turn on launch at login. Try again.")
            XCTAssertFalse(LoginStatusText.isSatisfied(true, by: status))
        }
        XCTAssertEqual(LoginStatusText.note(for: .enabled, failedRequest: true), "")
        XCTAssertTrue(LoginStatusText.isSatisfied(true, by: .enabled))
    }

    func testFailedDisableDoesNotDisappearWhileServiceRemainsRegistered() {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            XCTAssertEqual(LoginStatusText.note(for: status, failedRequest: false),
                           "Could not turn off launch at login. Try again.")
            XCTAssertFalse(LoginStatusText.isSatisfied(false, by: status))
        }
        for status in [SMAppService.Status.notFound, .notRegistered] {
            XCTAssertEqual(LoginStatusText.note(for: status, failedRequest: false), "")
            XCTAssertTrue(LoginStatusText.isSatisfied(false, by: status))
        }
    }

    func testPendingApprovalUsesActionableGuidanceInsteadOfFailure() {
        let expected = "Allow Cat Run in Login Items to finish enabling this setting."
        XCTAssertEqual(LoginStatusText.note(for: .requiresApproval), expected)
        XCTAssertEqual(LoginStatusText.note(for: .requiresApproval, failedRequest: true), expected)
        XCTAssertTrue(LoginStatusText.isSatisfied(true, by: .requiresApproval))
    }
}
