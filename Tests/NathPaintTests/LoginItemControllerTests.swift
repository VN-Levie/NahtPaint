import ServiceManagement
import XCTest
import PaintCore
@testable import NathPaint

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testInitializationOnlyReadsStatus() {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testEnableRegistersWhenNotRegistered() {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisableUnregistersEnabledService() {
        let service = MockLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
    }

    func testApprovalStatusCountsAsEnabledAndCanBeDisabled() {
        let service = MockLoginItemService(status: .requiresApproval)
        let controller = LoginItemController(service: service)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testRegistrationFailureKeepsActualEnabledStatusAndSurfacesError() {
        let service = MockLoginItemService(
            status: .notRegistered,
            registerError: MockError.failed,
            statusAfterRegisterError: .enabled
        )
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(
            controller.errorMessage,
            L10n.tr("Could not change launch at login: %@", "The operation failed.")
        )
    }

    func testRefreshReflectsExternalStateChanges() {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        service.status = .requiresApproval
        controller.refresh()

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testUnregisterFailureKeepsActualEnabledStatusAndSurfacesError() {
        let service = MockLoginItemService(status: .enabled, unregisterError: MockError.failed)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(
            controller.errorMessage,
            L10n.tr("Could not change launch at login: %@", "The operation failed.")
        )
    }

    func testRepeatedStateRequestsAreIdempotent() {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)
        controller.setEnabled(true)
        controller.setEnabled(true)
        controller.setEnabled(false)
        controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testNotFoundIsOffAndEnableAttemptsRegistration() {
        let service = MockLoginItemService(status: .notFound, registerError: MockError.failed)
        let controller = LoginItemController(service: service)

        XCTAssertFalse(controller.isEnabled)
        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.status, .notFound)
        XCTAssertEqual(
            controller.errorMessage,
            L10n.tr("Could not change launch at login: %@", "The operation failed.")
        )
    }
}

@MainActor
private final class MockLoginItemService: LoginItemServicing {
    var status: SMAppService.Status
    var registerError: Error?
    var statusAfterRegisterError: SMAppService.Status?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: SMAppService.Status,
        registerError: Error? = nil,
        unregisterError: Error? = nil,
        statusAfterRegisterError: SMAppService.Status? = nil
    ) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.statusAfterRegisterError = statusAfterRegisterError
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            if let statusAfterRegisterError { status = statusAfterRegisterError }
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private enum MockError: LocalizedError {
    case failed

    var errorDescription: String? { "The operation failed." }
}
