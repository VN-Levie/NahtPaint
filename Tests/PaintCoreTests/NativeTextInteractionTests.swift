import AppKit
import XCTest
@testable import PaintCore

/// Exercise the real AppKit handlers in an isolated, never-shown window.
/// Events are passed directly to the view; none are posted to the application or system.
final class NativeTextInteractionTests: XCTestCase {
    func testMouseDragMovesSelectedTextAndCreatesOneUndoStep() async throws {
        try await MainActor.run {
            let (engine, view, window) = Self.fixture()
            defer { window.contentView = nil }
            engine.insertText("Drag this text", at: CGPoint(x: 30, y: 25), width: 180)
            engine.tool = .select
            engine.markSaved()
            let original = try XCTUnwrap(engine.textObjects.first)
            let start = CGPoint(x: original.bounds.minX + 5, y: original.bounds.minY + 5)
            let middle = CGPoint(x: start.x + 12, y: start.y + 7)
            let end = CGPoint(x: start.x + 25, y: start.y + 15)

            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, view: view, window: window))
            XCTAssertEqual(engine.selectedTextID, original.id)
            view.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: middle, view: view, window: window))
            view.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: end, view: view, window: window))
            view.mouseUp(with: try Self.mouse(.leftMouseUp, at: end, view: view, window: window))

            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, CGPoint(x: original.position.x + 25, y: original.position.y + 15))
            XCTAssertTrue(engine.isDirty)
            XCTAssertFalse(window.isVisible)
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.position, original.position, "A single undo must reverse every drag event")
            XCTAssertFalse(engine.isDirty)
            engine.redo()
            XCTAssertEqual(engine.textObjects.first?.position, CGPoint(x: original.position.x + 25, y: original.position.y + 15))
        }
    }

    func testDoubleClickNativeEditorKeepsIdentityThroughEditExportAndReedit() async throws {
        try await MainActor.run {
            let (engine, view, window) = Self.fixture()
            defer { window.contentView = nil }
            engine.fontSize = 22
            engine.textColor = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1)
            engine.textBorder = true
            engine.textBackgroundEnabled = true
            engine.textBackgroundColor = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.2, alpha: 1)
            engine.insertText("Original\nTiếng Việt", at: CGPoint(x: 24, y: 18), width: 200)
            engine.tool = .select
            let original = try XCTUnwrap(engine.textObjects.first)
            let point = CGPoint(x: original.bounds.minX + 5, y: original.bounds.minY + 5)

            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: point, clicks: 2, view: view, window: window))
            view.mouseUp(with: try Self.mouse(.leftMouseUp, at: point, clicks: 2, view: view, window: window))
            let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, original.text)
            XCTAssertEqual(editor.font?.pointSize, original.style.fontSize)
            XCTAssertEqual(editor.textColor, original.style.color)
            XCTAssertEqual(engine.editingTextID, original.id)
            XCTAssertEqual(engine.textBorder, original.style.border)
            XCTAssertEqual(engine.textBackgroundColor, original.style.backgroundColor)

            editor.insertText("Edited B/P/C\nSecond line", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertEqual(engine.tool, .text, "Native text insertion must not invoke tool shortcuts")
            engine.finishEditing()
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.text, "Edited B/P/C\nSecond line")
            XCTAssertEqual(engine.textObjects.first?.style, original.style)
            XCTAssertNil(engine.editingTextID)
            XCTAssertTrue(view.subviews.compactMap { $0 as? NSTextView }.isEmpty)

            let exported = try engine.exportPNG()
            XCTAssertFalse(exported.isEmpty)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: point, clicks: 2, view: view, window: window))
            let reopened = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(window.firstResponder === reopened)
            XCTAssertEqual(reopened.string, "Edited B/P/C\nSecond line")
            XCTAssertEqual(engine.editingTextID, original.id)
            XCTAssertFalse(window.isVisible)
            engine.finishEditing()
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
        }
    }

    func testEscapeInNativeEditorRestoresOriginalObjectAndTextKeysStayText() async throws {
        try await MainActor.run {
            let (engine, view, window) = Self.fixture()
            defer { window.contentView = nil }
            engine.insertText("Keep", at: CGPoint(x: 30, y: 25), width: 180)
            engine.tool = .select
            engine.markSaved()
            let original = try XCTUnwrap(engine.textObjects.first)
            let point = CGPoint(x: original.bounds.minX + 4, y: original.bounds.minY + 4)
            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: point, clicks: 2, view: view, window: window))
            let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(window.firstResponder === editor)
            // Native insertText is the deterministic text-input route; it avoids invoking the user's IME.
            for text in ["B", "P", "C", "T"] { editor.insertText(text, replacementRange: editor.selectedRange()) }
            XCTAssertEqual(editor.string, "KeepBPCT")
            XCTAssertEqual(engine.tool, .text)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            editor.keyDown(with: escape)
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.text, original.text)
            XCTAssertNil(engine.editingTextID)
            XCTAssertFalse(engine.isDirty)
            XCTAssertTrue(view.subviews.compactMap { $0 as? NSTextView }.isEmpty)
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor private static func fixture() -> (PaintEngine, NativePaintView, NSWindow) {
        _ = NSApplication.shared
        let engine = PaintEngine(width: 360, height: 240)
        let view = NativePaintView(engine: engine)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
        window.makeFirstResponder(view)
        return (engine, view, window)
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1,
                                        view: NativePaintView, window: NSWindow) throws -> NSEvent {
        let windowPoint = view.convert(CGPoint(x: point.x * view.engine.zoom, y: point.y * view.engine.zoom), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                               clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
    }
}
