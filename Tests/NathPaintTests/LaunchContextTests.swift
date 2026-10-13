import AppKit
import Carbon
import XCTest
@testable import NathPaint

final class LaunchContextTests: XCTestCase {
    func testLoginLaunchDoesNotCreateEditorEvenWithDockOnlyPreference() async {
        await MainActor.run {
            _ = NSApplication.shared
            let previousVisibility = AppPreferences.shared.visibility
            let previousPolicy = NSApp.activationPolicy()
            AppPreferences.shared.visibility = .dockOnly
            let delegate = AppDelegate()
            defer {
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                AppPreferences.shared.visibility = previousVisibility
                NSApp.setActivationPolicy(previousPolicy)
            }
            let login = event(kAEOpenApplication)
            login.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
            XCTAssertNil(AppController.shared.window)
            // Exercise the same buffered Apple-event path used by Launch Services.
            delegate.handleOpenApplication(login, withReplyEvent: NSAppleEventDescriptor.null())
            // AppKit may dispose of or reuse the event once its handler returns.
            login.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
            delegate.finishLaunching()
            XCTAssertNil(AppController.shared.window, "Login startup must not construct an editor window")
            XCTAssertEqual(NSApp.activationPolicy(), .accessory, "Login startup must keep the Dock hidden")
            XCTAssertEqual(AppPreferences.shared.visibility, .dockOnly, "The saved preference must not be overwritten")
            // Receiving a login event after setup is ready must remain windowless too.
            let laterLogin = event(kAEOpenApplication)
            laterLogin.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
            delegate.handleOpenApplication(laterLogin, withReplyEvent: NSAppleEventDescriptor.null())
            XCTAssertNil(AppController.shared.window)
        }
    }

    func testOnlyLoginOpenEventsStartInBackground() {
        XCTAssertFalse(LaunchContext.isLoginLaunch(nil))
        let normalOpen = event(kAEOpenApplication)
        XCTAssertFalse(LaunchContext.isLoginLaunch(normalOpen))
        normalOpen.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(LaunchContext.isLoginLaunch(normalOpen))

        let service = event(kAEOpenApplication)
        service.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        XCTAssertFalse(LaunchContext.isLoginLaunch(service))

        let reopen = event(kAEReopenApplication)
        reopen.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertFalse(LaunchContext.isLoginLaunch(reopen), "Explicit reopens must still reveal the editor")
    }

    private func event(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id, targetDescriptor: nil,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
}
