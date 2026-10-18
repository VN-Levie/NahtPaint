import AppKit
import Carbon
import XCTest
@testable import NahtPaint

final class InstanceLifecycleTests: XCTestCase {
    func testSecondaryLaunchForwardsFilesWithoutCreatingAnIconOrDocument() async {
        await MainActor.run {
            _ = NSApplication.shared
            let coordinator = FakeInstanceCoordinator(isPrimary: false)
            let delegate = AppDelegate(instanceCoordinator: coordinator)
            let documentCount = EditorWorkspace.shared.documents.count
            let menu = NSApp.mainMenu
            var exits = 0
            delegate.finishSecondaryLaunch = { exits += 1 }
            let urls = [URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")]
            delegate.application(NSApp, open: urls)
            delegate.finishLaunching()
            delegate.forwardSecondaryLaunch()
            XCTAssertEqual(coordinator.requests, [.openURLs(urls)])
            XCTAssertNil(delegate.statusItem)
            XCTAssertTrue(NSApp.mainMenu === menu)
            XCTAssertEqual(EditorWorkspace.shared.documents.count, documentCount)
            XCTAssertEqual(exits, 0, "Wait for the existing process to accept the request")
            coordinator.complete(true)
            XCTAssertEqual(exits, 1)
            delegate.forwardSecondaryLaunch()
            XCTAssertEqual(coordinator.requests.count, 1)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        }
    }

    func testSecondaryLoginLaunchExitsQuietlyWithoutOpeningAnyWindow() async {
        await MainActor.run {
            _ = NSApplication.shared
            let coordinator = FakeInstanceCoordinator(isPrimary: false)
            let delegate = AppDelegate(instanceCoordinator: coordinator)
            let documentCount = EditorWorkspace.shared.documents.count
            var exits = 0
            delegate.finishSecondaryLaunch = { exits += 1 }
            let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
            delegate.handleOpenApplication(event, withReplyEvent: .null())
            delegate.finishLaunching()
            delegate.forwardSecondaryLaunch()
            XCTAssertTrue(coordinator.requests.isEmpty)
            XCTAssertEqual(exits, 1)
            XCTAssertNil(delegate.statusItem)
            XCTAssertEqual(EditorWorkspace.shared.documents.count, documentCount)
        }
    }

    func testFilesArrivingDuringHandoffAreForwardedBeforeExiting() async {
        await MainActor.run {
            _ = NSApplication.shared
            let coordinator = FakeInstanceCoordinator(isPrimary: false)
            let delegate = AppDelegate(instanceCoordinator: coordinator)
            var exits = 0
            delegate.finishSecondaryLaunch = { exits += 1 }
            delegate.forwardSecondaryLaunch()
            XCTAssertEqual(coordinator.requests, [.showWindow])
            let url = URL(fileURLWithPath: "/tmp/later.png")
            delegate.application(NSApp, open: [url])
            coordinator.complete(true)
            XCTAssertEqual(coordinator.requests, [.showWindow, .openURLs([url])])
            XCTAssertEqual(exits, 0)
            coordinator.complete(true)
            XCTAssertEqual(exits, 1)
            XCTAssertNil(delegate.statusItem)
        }
    }

    func testPrimarySetupIsIdempotentAndOwnsOneStatusItem() async {
        await MainActor.run {
            _ = NSApplication.shared
            let coordinator = FakeInstanceCoordinator(isPrimary: true)
            let delegate = AppDelegate(instanceCoordinator: coordinator)
            let policy = NSApp.activationPolicy()
            let menu = NSApp.mainMenu, windowsMenu = NSApp.windowsMenu
            defer {
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                NSApp.setActivationPolicy(policy)
                NSApp.mainMenu = menu; NSApp.windowsMenu = windowsMenu
            }
            delegate.finishLaunching()
            let item = delegate.statusItem
            XCTAssertNotNil(item)
            delegate.finishLaunching()
            XCTAssertTrue(delegate.statusItem === item)
            XCTAssertNotNil(coordinator.onRequest)
        }
    }
}

@MainActor private final class FakeInstanceCoordinator: SingleInstanceCoordinating {
    var isPrimary: Bool
    var onRequest: ((SingleInstanceCoordinator.Request) -> Void)?
    private(set) var requests: [SingleInstanceCoordinator.Request] = []
    private var completion: ((Bool) -> Void)?
    init(isPrimary: Bool) { self.isPrimary = isPrimary }
    func start() throws -> Bool { isPrimary }
    func forward(_ request: SingleInstanceCoordinator.Request, completion: @escaping (Bool) -> Void) {
        requests.append(request); self.completion = completion
    }
    func complete(_ accepted: Bool) {
        let callback = completion; completion = nil; callback?(accepted)
    }
    func invalidate() { completion = nil }
}
