import AppKit
import XCTest
@testable import PaintCore

final class CanvasExpansionTests: XCTestCase {
    func testExpansionPreservesExactPixelsIncludingAlphaAndUndoRedo() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            var source = Bitmap(width: 2, height: 2, white: false)
            source.pixels = [128, 0, 0, 128, 0, 255, 0, 255,
                             0, 0, 255, 255, 0, 0, 0, 0]
            try engine.loadImage(source.nsImage())
            let original = engine.bitmap.pixels
            try engine.expandCanvas(left: 3, top: 4, right: 5, bottom: 6)
            XCTAssertEqual(engine.width, 10)
            XCTAssertEqual(engine.height, 12)
            for y in 0..<2 {
                let offset = ((y + 4) * 10 + 3) * 4
                XCTAssertEqual(Array(engine.bitmap.pixels[offset..<(offset + 8)]),
                               Array(original[(y * 8)..<(y * 8 + 8)]))
            }
            XCTAssertEqual(Array(engine.bitmap.pixels.prefix(4)), [255, 255, 255, 255])
            let expanded = engine.bitmap.pixels
            engine.undo()
            XCTAssertEqual(engine.width, 2)
            XCTAssertEqual(engine.height, 2)
            XCTAssertEqual(engine.bitmap.pixels, original)
            XCTAssertFalse(engine.isDirty)
            engine.redo()
            XCTAssertEqual(engine.bitmap.pixels, expanded)
        }
    }

    func testExpansionMovesEditableTextWithoutScalingOrFlattening() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 200, height: 100)
            engine.insertText("Editable", at: CGPoint(x: 10, y: 12), width: 150)
            engine.commitSelection(); engine.markSaved()
            let text = try XCTUnwrap(engine.textObjects.first)
            try engine.expandCanvas(left: 25, top: 15)
            let moved = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(moved.id, text.id)
            XCTAssertEqual(moved.position, CGPoint(x: 35, y: 27))
            XCTAssertEqual(moved.raster.pixels, text.raster.pixels)
            XCTAssertEqual(moved.scaleX, text.scaleX)
            XCTAssertEqual(moved.scaleY, text.scaleY)
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.position, text.position)
            XCTAssertFalse(engine.isDirty)
            engine.redo()
            XCTAssertEqual(engine.textObjects.first?.position, moved.position)
        }
    }

    func testNoOpAndInvalidExpansionDoNotCommitPendingSelection() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 20, height: 10)
            try engine.pasteImage(Bitmap(width: 8, height: 6).nsImage())
            let rect = engine.selectionRect
            let version = engine.renderVersion
            try engine.expandCanvas()
            XCTAssertEqual(engine.renderVersion, version)
            XCTAssertThrowsError(try engine.expandCanvas(left: -1))
            XCTAssertThrowsError(try engine.expandCanvas(right: Int.max))
            XCTAssertThrowsError(try engine.expandCanvas(right: 8192))
            XCTAssertThrowsError(try engine.expandCanvas(right: 6000, bottom: 6000))
            XCTAssertEqual(engine.selectionRect, rect)
            XCTAssertEqual(engine.renderVersion, version)
            engine.cancelSelection()
            XCTAssertEqual(engine.width, 20)
            XCTAssertEqual(engine.height, 10)
        }
    }

    func testExpandedEmptyCanvasKeepsItsBoundsWhenPastingNextImage() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 20, height: 10)
            try engine.expandCanvas(right: 20)
            try engine.pasteImage(Bitmap(width: 20, height: 10).nsImage())
            XCTAssertEqual(engine.width, 40)
            XCTAssertEqual(engine.height, 10)
            engine.moveSelection(to: CGPoint(x: 20, y: 0))
            engine.commitSelection()
            engine.undo()
            XCTAssertEqual(engine.width, 40)
            engine.undo()
            XCTAssertEqual(engine.width, 20)
        }
    }

    func testExpansionRevealsPendingPixelsOutsideOldCanvasWithoutDoubleBlending() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Bitmap(width: 4, height: 4).nsImage())
            var overlay = Bitmap(width: 2, height: 2, white: false)
            overlay.pixels = Array(repeating: [128, 0, 0, 128], count: 4).flatMap { $0 }
            try engine.pasteImage(overlay.nsImage())
            engine.moveSelection(to: CGPoint(x: 3, y: 3))
            let visibleBefore = engine.displayBitmap()
            try engine.expandCanvas(right: 2, bottom: 2)
            XCTAssertEqual(engine.bitmap.color(at: CGPoint(x: 3, y: 3)), visibleBefore.color(at: CGPoint(x: 3, y: 3)))
            XCTAssertEqual(engine.bitmap.color(at: CGPoint(x: 4, y: 4)), engine.bitmap.color(at: CGPoint(x: 3, y: 3)))
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, visibleBefore.pixels)
            engine.undo()
            XCTAssertFalse(engine.isDirty)

            try engine.pasteImage(overlay.nsImage())
            engine.moveSelection(to: CGPoint(x: -1, y: -1))
            try engine.expandCanvas(left: 2, top: 2)
            XCTAssertEqual(engine.bitmap.color(at: CGPoint(x: 1, y: 1)), engine.bitmap.color(at: CGPoint(x: 2, y: 2)))
        }
    }

    func testPNGMeasurementMatchesExportWithoutEndingPendingEdits() async throws {
        let engine = await MainActor.run { PaintEngine(width: 20, height: 10) }
        let expected = try await MainActor.run {
            try engine.pasteImage(Bitmap(width: 8, height: 6).nsImage())
            return try engine.exportPNG().count
        }
        let measured = await engine.pngByteCount()
        XCTAssertEqual(measured, expected)
        await MainActor.run {
            XCTAssertNotNil(engine.selection)
            engine.cancelSelection()
            XCTAssertEqual(engine.width, 20)
            XCTAssertEqual(engine.height, 10)
            XCTAssertFalse(engine.isDirty)
        }
    }
}
