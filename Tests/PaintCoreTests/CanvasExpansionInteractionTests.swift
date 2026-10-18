import AppKit
import XCTest
@testable import PaintCore

final class CanvasExpansionInteractionTests: XCTestCase {
    func testEveryHandleConvertsScreenDistanceToOutwardPixelsAtEveryZoom() {
        for zoom: CGFloat in [0.05, 0.5, 1, 2, 16] {
            for handle in CanvasExpansionHandle.allCases {
                let x: CGFloat = handle.extendsLeft ? -20 : handle.extendsRight ? 20 : 0
                let y: CGFloat = handle.extendsTop ? -30 : handle.extendsBottom ? 30 : 0
                let result = CanvasExpansionPadding.dragging(handle, translation: CGPoint(x: x * zoom, y: y * zoom),
                                                              zoom: zoom, width: 100, height: 60)
                XCTAssertEqual(result.left, handle.extendsLeft ? 20 : 0)
                XCTAssertEqual(result.right, handle.extendsRight ? 20 : 0)
                XCTAssertEqual(result.top, handle.extendsTop ? 30 : 0)
                XCTAssertEqual(result.bottom, handle.extendsBottom ? 30 : 0)
                XCTAssertTrue(CanvasExpansionPadding.dragging(handle, translation: CGPoint(x: -x * zoom, y: -y * zoom),
                                                               zoom: zoom, width: 100, height: 60).isEmpty,
                              "Dragging inward must never crop the document")
            }
        }
    }

    func testPreviewClampsAtDimensionAndAreaLimits() throws {
        let edge = CanvasExpansionPadding.dragging(.right, translation: CGPoint(x: 100_000, y: 0),
                                                    zoom: 1, width: 8000, height: 1000)
        XCTAssertEqual(edge.right, 192)
        let corner = CanvasExpansionPadding.dragging(.bottomRight, translation: CGPoint(x: 5000, y: 5000),
                                                      zoom: 1, width: 4000, height: 4000)
        try Bitmap.validate(4000 + corner.right, 4000 + corner.bottom)
        XCTAssertEqual(corner.right, corner.bottom)
        XCTAssertGreaterThan(corner.right, 800)
        XCTAssertThrowsError(try Bitmap.validate(4001 + corner.right, 4001 + corner.bottom))
        XCTAssertTrue(CanvasExpansionPadding.dragging(.left, translation: CGPoint(x: -300, y: 0),
                                                      zoom: 1, width: 6000, height: 4000).isEmpty)
    }

    func testNativeDragPreviewsWithoutMutationAndCommitsOneUndoAtHalfZoom() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture(zoom: 0.5)
            defer { window.contentView = nil }
            let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == .right })
            let originalPixels = engine.bitmap.pixels
            let originalWindowPoint = scroll.canvas.convert(CGPoint.zero, to: nil)
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let end = CGPoint(x: start.x + 30, y: start.y)
            handle.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, window: window))
            XCTAssertEqual(scroll.canvas.convert(CGPoint.zero, to: nil).x, originalWindowPoint.x, accuracy: 0.01)
            XCTAssertEqual(scroll.canvas.convert(CGPoint.zero, to: nil).y, originalWindowPoint.y, accuracy: 0.01)
            let trackingFrame = scroll.canvas.frame
            handle.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: end, window: window))
            XCTAssertEqual(engine.width, 240)
            XCTAssertEqual(engine.bitmap.pixels, originalPixels)
            XCTAssertFalse(engine.canUndo)
            XCTAssertEqual(scroll.canvas.frame, trackingFrame, "Preview must not recenter the original image")
            scroll.updateCanvas()
            XCTAssertEqual(scroll.canvas.frame, trackingFrame)
            handle.mouseUp(with: try Self.mouse(.leftMouseUp, at: end, window: window))
            XCTAssertEqual(engine.width, 300)
            XCTAssertEqual(engine.height, 160)
            XCTAssertFalse(scroll.board.isExpanding)
            XCTAssertTrue(window.firstResponder === scroll.canvas)
            engine.undo()
            XCTAssertEqual(engine.width, 240)
            XCTAssertEqual(engine.bitmap.pixels, originalPixels)
            XCTAssertFalse(engine.canUndo, "The entire drag creates only one undo operation")
        }
    }

    func testEscapeCancelsTopLeftPreviewAndKeepsOriginalViewport() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture(zoom: 0.5)
            defer { window.contentView = nil }
            let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == .topLeft })
            let originalWindowPoint = scroll.canvas.convert(CGPoint.zero, to: nil)
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let end = CGPoint(x: start.x - 20, y: start.y + 15)
            handle.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, window: window))
            handle.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: end, window: window))
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            handle.keyDown(with: escape)
            handle.mouseUp(with: try Self.mouse(.leftMouseUp, at: end, window: window))
            XCTAssertEqual(engine.width, 240)
            XCTAssertEqual(engine.height, 160)
            XCTAssertFalse(engine.canUndo)
            XCTAssertFalse(scroll.board.isExpanding)
            XCTAssertEqual(scroll.canvas.convert(CGPoint.zero, to: nil).x, originalWindowPoint.x, accuracy: 0.01)
            XCTAssertEqual(scroll.canvas.convert(CGPoint.zero, to: nil).y, originalWindowPoint.y, accuracy: 0.01)
        }
    }

    func testUndoDuringDragDiscardsStalePreviewEvenWhenDimensionsStayUnchanged() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture(zoom: 1)
            defer { window.contentView = nil }
            engine.insertText("Undo during drag", at: CGPoint(x: 10, y: 10), width: 160)
            engine.commitSelection()
            let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == .right })
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let end = CGPoint(x: start.x + 20, y: start.y)
            handle.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, window: window))
            handle.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: end, window: window))
            engine.undo()
            handle.mouseUp(with: try Self.mouse(.leftMouseUp, at: end, window: window))
            XCTAssertEqual(engine.width, 240)
            XCTAssertTrue(engine.textObjects.isEmpty)
            XCTAssertFalse(engine.canUndo)
            XCTAssertTrue(engine.canRedo)
            XCTAssertFalse(scroll.board.isExpanding)
        }
    }

    func testHandlesStayOutsideArtworkAndAccessibleExpansionSurvivesNextPaste() async throws {
        try await MainActor.run {
            let (engine, scroll, window) = Self.fixture(zoom: 0.05)
            defer { window.contentView = nil }
            for handle in scroll.board.handles {
                XCTAssertFalse(handle.frame.intersects(scroll.canvas.frame))
                XCTAssertFalse((handle.accessibilityLabel() ?? "").isEmpty)
                for other in scroll.board.handles where other !== handle {
                    XCTAssertFalse(handle.frame.intersects(other.frame), "Hit areas must remain distinct at minimum zoom")
                }
            }
            let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == .right })
            XCTAssertTrue(handle.accessibilityPerformPress())
            XCTAssertEqual(engine.width, 272)
            let image = NSImage(size: CGSize(width: 24, height: 16), flipped: false) { rect in
                NSColor.red.setFill(); rect.fill(); return true
            }
            try engine.pasteImage(image)
            XCTAssertEqual(engine.width, 272, "Adding blank space expresses intent and must prevent pristine-canvas replacement")
            XCTAssertEqual(engine.height, 160)
        }
    }

    @MainActor private static func fixture(zoom: CGFloat) -> (PaintEngine, CanvasScrollView, NSWindow) {
        _ = NSApplication.shared
        let engine = PaintEngine(width: 240, height: 160)
        engine.zoom = zoom
        let scroll = CanvasScrollView(engine: engine)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        scroll.layoutSubtreeIfNeeded()
        scroll.updateCanvas()
        return (engine, scroll, window)
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
}
