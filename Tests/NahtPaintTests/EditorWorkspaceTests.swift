import AppKit
import XCTest
import PaintCore
@testable import NahtPaint

final class EditorWorkspaceTests: XCTestCase {
    func testFirstClipboardDocumentReusesWindowlessLaunchPlaceholder() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let workspace = EditorWorkspace()
            let placeholder = workspace.activeController
            XCTAssertNil(placeholder.window)
            let document = try workspace.openImage(Self.image(width: 20, height: 10), unsaved: true, show: false)
            XCTAssertTrue(document === placeholder)
            XCTAssertEqual(workspace.documents.count, 1)
            XCTAssertTrue(document.engine.isDirty)
        }
    }
    func testDocumentsKeepIndependentCanvasHistoryAndActiveWindow() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let workspace = EditorWorkspace()
            let first = workspace.newDocument(show: false)
            let second = workspace.newDocument(show: false)
            first.engine.newCanvas(width: 100, height: 70)
            second.engine.newCanvas(width: 200, height: 90)
            try first.engine.expandCanvas(right: 30)
            XCTAssertEqual(first.engine.width, 130)
            XCTAssertEqual(second.engine.width, 200)
            XCTAssertFalse(second.engine.canUndo)
            XCTAssertTrue(workspace.activeController === second)
            workspace.activate(first)
            XCTAssertTrue(workspace.activeController === first)
            workspace.activeController.undo()
            XCTAssertEqual(first.engine.width, 100)
            XCTAssertEqual(second.engine.width, 200)
            XCTAssertEqual(first.displayName, L10n.tr("Untitled"))
            XCTAssertEqual(second.displayName, "\(L10n.tr("Untitled")) 2")
        }
    }

    func testOpeningImagesKeepsOtherUnsavedDocumentsAndFileTargets() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let workspace = EditorWorkspace()
            let first = workspace.newDocument(show: false)
            try first.engine.expandCanvas(right: 20)
            let originalWidth = first.engine.width
            let url = URL(fileURLWithPath: "/tmp/nathpaint-workspace-test.png")
            let second = try workspace.openImage(Self.image(width: 20, height: 10), url: url, show: false)
            let pasted = try workspace.openImage(Self.image(width: 8, height: 6), unsaved: true, show: false)
            XCTAssertEqual(workspace.documents.count, 3)
            XCTAssertEqual(first.engine.width, originalWidth)
            XCTAssertTrue(first.engine.isDirty)
            XCTAssertNil(first.fileURL)
            XCTAssertEqual(second.fileURL, url)
            XCTAssertFalse(second.engine.isDirty)
            XCTAssertEqual(pasted.engine.width, 8)
            XCTAssertTrue(pasted.engine.isDirty)
            XCTAssertNil(pasted.fileURL)
            XCTAssertTrue(workspace.activeController === pasted)
        }
    }

    func testInvalidImageDoesNotRegisterDocumentOrReplaceExistingImage() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let workspace = EditorWorkspace()
            let first = try workspace.openImage(Self.image(width: 20, height: 10), show: false)
            XCTAssertThrowsError(try workspace.openImage(NSImage(size: .zero), show: false))
            XCTAssertEqual(workspace.documents.count, 1)
            XCTAssertTrue(workspace.activeController === first)
            XCTAssertEqual(first.engine.width, 20)
        }
    }

    func testQuitChecksEveryDirtyDocumentAndCancellationPreservesAllWork() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let workspace = EditorWorkspace()
            let first = workspace.newDocument(show: false)
            let second = workspace.newDocument(show: false)
            let clean = workspace.newDocument(show: false)
            try first.engine.expandCanvas(right: 10)
            try second.engine.expandCanvas(bottom: 10)
            var confirmed: [AppController] = []
            XCTAssertFalse(workspace.confirmQuit(clearAutomatically: false) { document in
                confirmed.append(document)
                return document === first
            })
            XCTAssertEqual(confirmed.count, 2)
            XCTAssertTrue(confirmed[0] === first)
            XCTAssertTrue(confirmed[1] === second)
            XCTAssertTrue(first.engine.isDirty)
            XCTAssertTrue(second.engine.isDirty)
            XCTAssertFalse(clean.engine.isDirty)
            XCTAssertEqual(first.engine.width, 970)
            XCTAssertEqual(second.engine.height, 650)
            XCTAssertTrue(workspace.confirmQuit(clearAutomatically: true) { _ in
                XCTFail("Opt-in automatic discard must not prompt"); return false
            })
        }
    }

    func testClosingWindowKeepsItsDocumentAndDoesNotClearOtherWindows() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let previous = AppPreferences.shared.clearCanvasOnCloseOrQuit
            defer { AppPreferences.shared.clearCanvasOnCloseOrQuit = previous }
            let workspace = EditorWorkspace()
            let first = workspace.newDocument(show: false)
            let second = workspace.newDocument(show: false)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            first.attach(window)
            try first.engine.expandCanvas(right: 20)
            try second.engine.expandCanvas(right: 40)
            AppPreferences.shared.clearCanvasOnCloseOrQuit = false
            XCTAssertFalse(first.windowShouldClose(window))
            XCTAssertEqual(workspace.documents.count, 2)
            XCTAssertEqual(first.engine.width, 980)
            XCTAssertEqual(second.engine.width, 1000)
            XCTAssertTrue(workspace.controller(for: window) === first)
            first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            XCTAssertTrue(workspace.activeController === first)
            AppPreferences.shared.clearCanvasOnCloseOrQuit = true
            XCTAssertFalse(first.windowShouldClose(window))
            XCTAssertEqual(first.engine.width, 960)
            XCTAssertEqual(second.engine.width, 1000)
            XCTAssertTrue(second.engine.isDirty)
        }
    }

    func testMenuActionsResolveActiveDocumentWhenInvoked() async {
        await MainActor.run {
            _ = NSApplication.shared
            let oldMenu = NSApp.mainMenu, oldWindowsMenu = NSApp.windowsMenu
            defer { NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindowsMenu }
            let workspace = EditorWorkspace()
            let first = workspace.newDocument(show: false)
            let second = workspace.newDocument(show: false)
            let menu = AppMenu(workspace: workspace)
            withExtendedLifetime(menu) {
                let view = NSApp.mainMenu?.items.first { $0.title == L10n.tr("View") }?.submenu
                let zoom = view?.items.first { $0.title == L10n.tr("Zoom In") }
                XCTAssertNotNil(zoom)
                workspace.activate(first)
                if let action = zoom?.action { NSApp.sendAction(action, to: zoom?.target, from: zoom) }
                XCTAssertEqual(first.engine.zoom, 1.25)
                XCTAssertEqual(second.engine.zoom, 1)
                workspace.activate(second)
                if let action = zoom?.action { NSApp.sendAction(action, to: zoom?.target, from: zoom) }
                XCTAssertEqual(first.engine.zoom, 1.25)
                XCTAssertEqual(second.engine.zoom, 1.25)
            }
        }
    }

    @MainActor private static func image(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        memset(rep.bitmapData!, 255, rep.bytesPerRow * height)
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
