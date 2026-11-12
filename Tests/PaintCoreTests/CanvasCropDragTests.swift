import AppKit
import XCTest
@testable import PaintCore

final class CanvasCropDragTests: XCTestCase {
    func testInwardDragPausesAtArtworkEdgeThenCropsPastIt() {
        let content = CanvasContentInsets(right: 40)
        func drag(_ dx: CGFloat, zoom: CGFloat = 2) -> CanvasExpansionPadding {
            .dragging(.right, translation: CGPoint(x: dx, y: 0), zoom: zoom, width: 200, height: 100, content: content)
        }
        // 40 blank pixels at 2× zoom = 80 points of free trimming.
        XCTAssertEqual(drag(-60).right, -30)
        XCTAssertFalse(drag(-60).holdingAtContent)
        XCTAssertEqual(drag(-80).right, -40)
        XCTAssertTrue(drag(-80).holdingAtContent)
        XCTAssertEqual(drag(-80 - CanvasExpansionPadding.detent + 1).right, -40, "Small overshoot stays at the artwork edge")
        XCTAssertTrue(drag(-80 - CanvasExpansionPadding.detent + 1).holdingAtContent)
        XCTAssertEqual(drag(-80 - CanvasExpansionPadding.detent - 20).right, -50, "A deliberate push crops the artwork")
        XCTAssertFalse(drag(-80 - CanvasExpansionPadding.detent - 20).holdingAtContent)
        XCTAssertEqual(drag(30).right, 15, "Outward drags are unaffected")
    }

    func testContentBoundsIgnoreWhiteTransparentAndUniformBorders() {
        var white = Bitmap(width: 10, height: 8)
        XCTAssertNil(white.contentBounds())
        white.pixels[(3 * 10 + 4) * 4] = 0
        XCTAssertEqual(white.contentBounds(), CGRect(x: 4, y: 3, width: 1, height: 1))

        var clear = Bitmap(width: 10, height: 8, white: false)
        for i in stride(from: (2 * 10 + 6) * 4, to: (2 * 10 + 8) * 4, by: 4) { clear.pixels[i + 3] = 255 }
        XCTAssertEqual(clear.contentBounds(), CGRect(x: 6, y: 2, width: 2, height: 1))

        var dark = Bitmap(width: 10, height: 8, white: false)
        for i in stride(from: 0, to: dark.pixels.count, by: 4) { dark.pixels[i] = 30; dark.pixels[i+1] = 30; dark.pixels[i+2] = 34; dark.pixels[i+3] = 255 }
        let mark = (5 * 10 + 1) * 4
        dark.pixels[mark] = 200
        XCTAssertEqual(dark.contentBounds(), CGRect(x: 1, y: 5, width: 1, height: 1))
    }

    func testCropKeepsExactPixelsClipsTextAndUndoesInOneStep() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 6, height: 4)
            var source = Bitmap(width: 6, height: 4, white: false)
            for i in 0..<source.pixels.count { source.pixels[i] = UInt8(i % 251) }
            for i in stride(from: 3, to: source.pixels.count, by: 4) { source.pixels[i] = 255 }
            try engine.loadImage(source.nsImage())
            let original = engine.bitmap.pixels
            try engine.adjustCanvasEdges(left: -2, top: -1, right: 3, bottom: 0)
            XCTAssertEqual(engine.width, 7)
            XCTAssertEqual(engine.height, 3)
            for y in 0..<3 {
                let kept = Array(engine.bitmap.pixels[(y * 7 * 4)..<(y * 7 * 4 + 16)])
                let from = ((y + 1) * 6 + 2) * 4
                XCTAssertEqual(kept, Array(original[from..<(from + 16)]))
                XCTAssertEqual(Array(engine.bitmap.pixels[((y * 7 + 4) * 4)..<((y * 7 + 5) * 4)]), [255, 255, 255, 255])
            }
            engine.undo()
            XCTAssertEqual(engine.width, 6)
            XCTAssertEqual(engine.bitmap.pixels, original)
            XCTAssertFalse(engine.canUndo)
            XCTAssertThrowsError(try engine.adjustCanvasEdges(right: -6))
        }
    }

    func testCropMovesAndClipsEditableTextWithoutScaling() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 300, height: 120)
            engine.insertText("Keep", at: CGPoint(x: 100, y: 40), width: 120)
            engine.commitSelection()
            let text = try XCTUnwrap(engine.textObjects.first)
            try engine.adjustCanvasEdges(left: -60, top: -10)
            let moved = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(moved.id, text.id)
            XCTAssertEqual(moved.position.x, text.position.x - 60, accuracy: 0.001)
            XCTAssertEqual(moved.position.y, text.position.y - 10, accuracy: 0.001)
            XCTAssertEqual(moved.scaleX, text.scaleX)
            try engine.adjustCanvasEdges(right: -(engine.width - 1))
            XCTAssertTrue(engine.textObjects.allSatisfy { $0.bounds.minX < 1 }, "Text beyond the new edge is clipped or removed")
        }
    }

    func testNativeInwardDragSnapsToArtworkAndCommitsOneUndo() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 240, height: 160)
            // Artwork occupies x 0..<180; 60 blank pixels on the right.
            var art = Bitmap(width: 180, height: 160, white: false)
            for i in stride(from: 0, to: art.pixels.count, by: 4) { art.pixels[i+2] = 200; art.pixels[i+3] = 255 }
            engine.bitmap.composite(art, in: CGRect(x: 0, y: 0, width: 180, height: 160))
            let scroll = CanvasScrollView(engine: engine)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.contentView = nil }
            scroll.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            scroll.layoutSubtreeIfNeeded(); scroll.updateCanvas()
            let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == .right })
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            // 60 px blank + a little overshoot, still inside the detent.
            let end = CGPoint(x: start.x - 70, y: start.y)
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            handle.mouseDown(with: try mouse(.leftMouseDown, start))
            handle.mouseDragged(with: try mouse(.leftMouseDragged, end))
            XCTAssertEqual(engine.width, 240, "Preview does not change the document")
            handle.mouseUp(with: try mouse(.leftMouseUp, end))
            XCTAssertEqual(engine.width, 180)
            XCTAssertEqual(engine.height, 160)
            engine.undo()
            XCTAssertEqual(engine.width, 240)
            XCTAssertFalse(engine.canUndo)
        }
    }

    func testReleasedEdgeDragKeepsRetainedArtworkStillAndIgnoresScrolling() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 600, height: 400)
            let scroll = CanvasScrollView(engine: engine)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.contentView = nil }
            scroll.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
            scroll.layoutSubtreeIfNeeded(); scroll.updateCanvas()
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                clickCount: 1, pressure: 1))
            }
            func pan() throws -> NSEvent {
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                  wheel1: 40, wheel2: 0, wheel3: 0))
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
                return try XCTUnwrap(NSEvent(cgEvent: event))
            }
            // Bottom edge up by 100 pt, then top edge down by 50 pt.
            for (side, dy) in [(CanvasExpansionHandle.bottom, CGFloat(100)), (.top, CGFloat(-50))] {
                let topLeftBefore = scroll.canvas.convert(CGPoint(x: 0, y: side == .top ? 50 : 0), to: nil)
                let handle = try XCTUnwrap(scroll.board.handles.first { $0.handle == side })
                let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
                handle.mouseDown(with: try mouse(.leftMouseDown, start))
                let during = scroll.canvas.convert(CGPoint.zero, to: nil)
                scroll.scrollWheel(with: try pan())
                XCTAssertEqual(scroll.canvas.convert(CGPoint.zero, to: nil), during, "Momentum must not move the canvas mid-drag")
                let end = CGPoint(x: start.x, y: start.y + dy)
                handle.mouseDragged(with: try mouse(.leftMouseDragged, end))
                handle.mouseUp(with: try mouse(.leftMouseUp, end))
                let topLeftAfter = scroll.canvas.convert(CGPoint.zero, to: nil)
                XCTAssertEqual(topLeftAfter.x, topLeftBefore.x, accuracy: 0.5)
                XCTAssertEqual(topLeftAfter.y, topLeftBefore.y, accuracy: 0.5, "Kept artwork must not jump back to the centre")
            }
            XCTAssertEqual(engine.height, 250)
            engine.zoom = 0.5
            scroll.updateCanvas()
            XCTAssertNil(scroll.pinnedPlacement, "A zoom change recentres as before")
        }
    }
}
