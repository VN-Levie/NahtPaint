import AppKit
import XCTest
@testable import PaintCore

final class SelectionFlipTests: XCTestCase {
    func testNonIntegerRasterResizeReflectsDisplayedPixelsOnBothAxes() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 8, height: 8)
            engine.bitmap = Self.pattern(width: 8, height: 8, alpha: false)
            engine.select(rect: CGRect(x: 1, y: 1, width: 3, height: 3))
            engine.resizeSelection(to: CGSize(width: 4, height: 4))
            let resized = try Self.bitmap(XCTUnwrap(engine.selectionPNG()))
            engine.flipSelectionHorizontally()
            XCTAssertEqual(try Self.bitmap(XCTUnwrap(engine.selectionPNG())).pixels, Self.reflected(resized, horizontal: true).pixels)
            engine.flipSelectionVertically()
            let expected = Self.reflected(resized, horizontal: true, vertical: true)
            XCTAssertEqual(try Self.bitmap(XCTUnwrap(engine.selectionPNG())).pixels, expected.pixels)
            XCTAssertEqual(engine.displayBitmap().crop(try XCTUnwrap(engine.selectionRect)).pixels, expected.pixels)
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            XCTAssertEqual(try Self.bitmap(XCTUnwrap(engine.selectionPNG())).pixels, resized.pixels)

            engine.resizeSelection(to: CGSize(width: 3, height: 3))
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            engine.resizeSelection(to: CGSize(width: 4, height: 4))
            XCTAssertEqual(try Self.bitmap(XCTUnwrap(engine.selectionPNG())).pixels, expected.pixels,
                           "Mirroring before resizing must produce the same result as mirroring afterward")
        }
    }

    func testFractionallyScaledAndCroppedTextReflectsDisplayedPixels() throws {
        let raster = Self.pattern(width: 7, height: 5, alpha: false)
        let style = PaintTextStyle(fontSize: 18, color: .black, border: false, backgroundEnabled: false, backgroundColor: .white)
        let object = PaintTextObject(id: UUID(), text: "ABC", position: CGPoint(x: 1.5, y: 2.25), layoutWidth: 7,
                                     style: style, scaleX: 4.0 / 3.0, scaleY: 1.6, raster: raster,
                                     clipRect: CGRect(x: 0.5, y: 0.25, width: 5.5, height: 3.75))
        let region = CGRect(x: 0, y: 0, width: 16, height: 14)
        var before = Bitmap(width: 16, height: 14, white: false)
        object.draw(on: &before)
        let flipped = object.flipped(in: region, horizontally: true, vertically: true)
        var after = Bitmap(width: 16, height: 14, white: false)
        flipped.draw(on: &after)
        XCTAssertEqual(after.pixels, Self.reflected(before, horizontal: true, vertical: true).pixels)

        let crop = CGRect(x: 6, y: 5, width: 5, height: 4)
        let cropped = try XCTUnwrap(flipped.clipped(to: crop))
        var croppedPixels = Bitmap(width: 5, height: 4, white: false)
        cropped.draw(on: &croppedPixels)
        XCTAssertEqual(croppedPixels.pixels, after.crop(crop).pixels)

        let target = CGRect(x: 0, y: 0, width: 24, height: 21)
        let mirrorThenResize = flipped.transformed(from: region, to: target)
        let resizeThenMirror = object.transformed(from: region, to: target).flipped(in: target, horizontally: true, vertically: true)
        var first = Bitmap(width: 24, height: 21, white: false)
        var second = first
        mirrorThenResize.draw(on: &first)
        resizeThenMirror.draw(on: &second)
        XCTAssertEqual(first.pixels, second.pixels)
    }

    func testRectangleFlipPreservesBoundsAlphaAndPixelsOutsideSelection() async throws {
        await MainActor.run {
            let engine = PaintEngine(width: 7, height: 5)
            engine.bitmap = Self.pattern(width: 7, height: 5)
            let original = engine.bitmap
            let rect = CGRect(x: 1, y: 1, width: 4, height: 3)
            engine.select(rect: rect)
            XCTAssertTrue(engine.canFlipSelection)
            engine.flipSelectionHorizontally()
            XCTAssertEqual(engine.selectionRect, rect)
            XCTAssertTrue(engine.isDirty)
            let horizontal = Self.reflected(original.crop(rect), horizontal: true)
            XCTAssertEqual(engine.displayBitmap().crop(rect).pixels, horizontal.pixels)
            XCTAssertEqual(Array(engine.displayBitmap().pixels.prefix(7 * 4)), Array(original.pixels.prefix(7 * 4)))
            engine.flipSelectionVertically()
            let both = Self.reflected(horizontal, vertical: true)
            XCTAssertEqual(engine.displayBitmap().crop(rect).pixels, both.pixels)
            engine.commitSelection()
            XCTAssertEqual(engine.bitmap.crop(rect).pixels, both.pixels)
            XCTAssertFalse(engine.hasSelection)
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, original.pixels)
            XCTAssertFalse(engine.isDirty)
            engine.redo()
            XCTAssertEqual(engine.bitmap.crop(rect).pixels, both.pixels)
        }
    }

    func testPendingFlipSupportsUndoAndRedoWithoutConfirmingSelection() async throws {
        await MainActor.run {
            let engine = PaintEngine(width: 5, height: 3)
            engine.bitmap = Self.pattern(width: 5, height: 3)
            let original = engine.bitmap
            engine.selectAll()
            engine.flipSelectionHorizontally()
            let flipped = engine.displayBitmap()
            XCTAssertNotEqual(flipped.pixels, original.pixels)
            engine.undo()
            XCTAssertEqual(engine.displayBitmap().pixels, original.pixels)
            XCTAssertTrue(engine.canRedo)
            XCTAssertFalse(engine.isDirty)
            engine.redo()
            XCTAssertEqual(engine.displayBitmap().pixels, flipped.pixels)
            XCTAssertTrue(engine.isDirty)
        }
    }

    func testTwoMatchingFlipsRestoreExactPixelsAndDoNotCreateHistory() async throws {
        await MainActor.run {
            let engine = PaintEngine(width: 5, height: 3)
            engine.bitmap = Self.pattern(width: 5, height: 3)
            let original = engine.bitmap.pixels
            engine.selectAll()
            engine.flipSelectionHorizontally()
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            engine.flipSelectionVertically()
            XCTAssertEqual(engine.displayBitmap().pixels, original)
            XCTAssertFalse(engine.isDirty)
            engine.commitSelection()
            XCTAssertEqual(engine.bitmap.pixels, original)
            XCTAssertFalse(engine.canUndo)
        }
    }

    func testNoSelectionAndCropMarqueeCannotFlip() async throws {
        await MainActor.run {
            let engine = PaintEngine(width: 5, height: 3)
            engine.bitmap = Self.pattern(width: 5, height: 3)
            let original = engine.bitmap.pixels
            XCTAssertFalse(engine.canFlipSelection)
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            XCTAssertFalse(engine.isDirty)
            XCTAssertFalse(engine.canUndo)
            engine.tool = .crop
            let crop = CGRect(x: 1, y: 0, width: 3, height: 2)
            engine.select(rect: crop)
            XCTAssertFalse(engine.canFlipSelection)
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            XCTAssertEqual(engine.selectionRect, crop)
            XCTAssertEqual(engine.displayBitmap().pixels, original)
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testFlipMoveResizeCopyAndEscapeKeepFloatingSelectionSemantics() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 16, height: 12)
            engine.bitmap = Self.pattern(width: 16, height: 12, alpha: false)
            let original = engine.bitmap
            let region = CGRect(x: 2, y: 1, width: 3, height: 2)
            engine.select(rect: region)
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            engine.moveSelection(to: CGPoint(x: 7, y: 5))
            engine.resizeSelection(to: CGSize(width: 6, height: 4))
            XCTAssertEqual(engine.selectionRect, CGRect(x: 7, y: 5, width: 6, height: 4))
            let expected = Self.reflected(original.crop(region), horizontal: true, vertical: true).resized(width: 6, height: 4)
            let copied = try Self.bitmap(XCTUnwrap(engine.selectionPNG()))
            XCTAssertEqual(copied.pixels, expected.pixels)
            XCTAssertEqual(engine.displayBitmap().crop(try XCTUnwrap(engine.selectionRect)).pixels, expected.pixels)
            engine.cancelSelection()
            XCTAssertEqual(engine.bitmap.pixels, original.pixels)
            XCTAssertFalse(engine.isDirty)
            XCTAssertFalse(engine.canUndo)
        }
    }

    func testPastedRasterCanFlipBeforePlacementAndUndoCanvasAdoption() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 20, height: 10)
            try engine.pasteImage(Self.pattern(width: 5, height: 3, alpha: false).nsImage())
            let pasted = try XCTUnwrap(engine.selection?.image)
            engine.flipSelectionVertically()
            let expected = Self.reflected(pasted, vertical: true)
            XCTAssertEqual(engine.displayBitmap().pixels, expected.pixels)
            engine.undo()
            XCTAssertEqual(engine.width, 20)
            XCTAssertEqual(engine.height, 10)
            XCTAssertTrue(engine.canRedo)
            engine.redo()
            XCTAssertEqual(engine.width, 5)
            XCTAssertEqual(engine.height, 3)
            XCTAssertEqual(engine.bitmap.pixels, expected.pixels)
        }
    }

    func testSelectedTextFlipPreservesEditabilityAndUndoRedo() async throws {
        try await MainActor.run {
            let engine = Self.textEngine()
            engine.insertText("Flip ABC", at: CGPoint(x: 15, y: 10), width: 140)
            let original = try XCTUnwrap(engine.selectedTextObject)
            engine.markSaved()
            engine.selectText(id: original.id)
            let before = try Self.bitmap(XCTUnwrap(engine.selectionPNG()))
            engine.flipSelectionHorizontally()
            let changed = try XCTUnwrap(engine.selectedTextObject)
            XCTAssertEqual(changed.id, original.id)
            XCTAssertEqual(changed.text, original.text)
            XCTAssertEqual(changed.raster.pixels, original.raster.pixels)
            XCTAssertEqual(changed.bounds, original.bounds)
            XCTAssertTrue(changed.flippedHorizontally)
            XCTAssertTrue(engine.isDirty)
            XCTAssertEqual(try Self.bitmap(XCTUnwrap(engine.selectionPNG())).pixels, Self.reflected(before, horizontal: true).pixels)
            let flipped = try engine.exportPNG()
            engine.undo()
            XCTAssertFalse(try XCTUnwrap(engine.textObjects.first).flippedHorizontally)
            XCTAssertFalse(engine.isDirty)
            engine.redo()
            XCTAssertEqual(try engine.exportPNG(), flipped)
            let editing = try XCTUnwrap(engine.beginTextEditing(id: original.id))
            engine.updateText(id: editing.id, text: "Still editable", layoutWidth: editing.layoutWidth)
            XCTAssertEqual(engine.textObjects.first?.text, "Still editable")
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertTrue(try XCTUnwrap(engine.textObjects.first).flippedHorizontally)
        }
    }

    func testCroppedMirroredTextKeepsVisibleBoundsAndCannotRevealDiscardedPixels() async throws {
        let raster = Self.pattern(width: 7, height: 5, alpha: false)
        let style = PaintTextStyle(fontSize: 18, color: .black, border: false, backgroundEnabled: false, backgroundColor: .white)
        let object = PaintTextObject(id: UUID(), text: "ABC", position: CGPoint(x: 3, y: 2), layoutWidth: 7,
                                     style: style, raster: raster, clipRect: CGRect(x: 1, y: 1, width: 4, height: 3))
        var visible = Bitmap(width: 4, height: 3, white: false)
        object.draw(on: &visible, offset: object.bounds.origin)
        let flipped = object.flipped(in: object.bounds, horizontally: true, vertically: true)
        XCTAssertEqual(flipped.bounds, object.bounds)
        XCTAssertEqual(flipped.clipRect, object.clipRect)
        var output = Bitmap(width: 4, height: 3, white: false)
        flipped.draw(on: &output, offset: flipped.bounds.origin)
        XCTAssertEqual(output.pixels, Self.reflected(visible, horizontal: true, vertical: true).pixels)

        let crop = CGRect(x: flipped.bounds.minX + 1, y: flipped.bounds.minY, width: 2, height: 2)
        let cropped = try XCTUnwrap(flipped.clipped(to: crop))
        var expanded = Bitmap(width: 10, height: 8, white: false)
        cropped.draw(on: &expanded)
        XCTAssertEqual(expanded.crop(CGRect(x: 0, y: 0, width: 2, height: 2)).pixels,
                       output.crop(CGRect(x: 1, y: 0, width: 2, height: 2)).pixels)
        for y in 0..<expanded.height {
            for x in 0..<expanded.width where x >= 2 || y >= 2 {
                XCTAssertEqual(expanded.pixels[(y * expanded.width + x) * 4 + 3], 0)
            }
        }
        let restored = flipped.flipped(in: flipped.bounds, horizontally: true, vertically: true)
        XCTAssertEqual(restored.position, object.position)
        XCTAssertEqual(restored.bounds, object.bounds)
        XCTAssertFalse(restored.flippedHorizontally)
        XCTAssertFalse(restored.flippedVertically)
    }

    func testMixedRasterAndTextFlipUsesSelectionCenterAndEscapeRestoresBoth() async throws {
        await MainActor.run {
            let engine = Self.textEngine()
            engine.bitmap = Self.pattern(width: engine.width, height: engine.height, alpha: false)
            engine.insertText("Left", at: CGPoint(x: 7, y: 8), width: 80)
            engine.insertText("Right", at: CGPoint(x: 100, y: 50), width: 90)
            engine.markSaved()
            let original = engine.displayBitmap()
            let objects = engine.textObjects
            engine.selectAll()
            engine.flipSelectionHorizontally()
            engine.flipSelectionVertically()
            XCTAssertEqual(engine.displayBitmap().pixels, Self.reflected(original, horizontal: true, vertical: true).pixels)
            engine.cancelSelection()
            XCTAssertEqual(engine.displayBitmap().pixels, original.pixels)
            XCTAssertEqual(engine.textObjects.map(\.id), objects.map(\.id))
            XCTAssertEqual(engine.textObjects.map(\.position), objects.map(\.position))
            XCTAssertFalse(engine.isDirty)
            engine.selectAll()
            engine.flipSelectionHorizontally()
            engine.commitSelection()
            XCTAssertEqual(engine.displayBitmap().pixels, Self.reflected(original, horizontal: true).pixels)
            XCTAssertEqual(engine.textObjects.map(\.id), objects.map(\.id))
            XCTAssertEqual(engine.textObjects.map(\.text), objects.map(\.text))
            XCTAssertTrue(engine.textObjects.allSatisfy(\.flippedHorizontally))
        }
    }

    func testMirroredEditableClipboardRoundTripAndLegacyPayloadDecode() async throws {
        try await MainActor.run {
            let source = Self.textEngine()
            source.insertText("Mirror copy", at: CGPoint(x: 12, y: 10), width: 170)
            source.flipSelectionHorizontally()
            source.flipSelectionVertically()
            let original = try XCTUnwrap(source.selectedTextObject)
            let expected = try XCTUnwrap(source.selectionPNG())
            let board = NSPasteboard(name: .init("NahtPaint.SelectionFlipTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            try source.copy(to: board)
            XCTAssertNotNil(board.data(forType: .init("com.nathpaint.editable-text.v1")))
            let target = Self.textEngine()
            target.paste(from: board)
            XCTAssertEqual(try target.exportPNG(), expected)
            target.commitSelection()
            let pasted = try XCTUnwrap(target.textObjects.first)
            XCTAssertEqual(pasted.text, original.text)
            XCTAssertTrue(pasted.flippedHorizontally)
            XCTAssertTrue(pasted.flippedVertically)
            XCTAssertNotNil(target.beginTextEditing(id: pasted.id))
            target.cancelTextEditing()

            let transfer = PaintTextTransfer(original, offset: .zero)
            let encoded = try JSONEncoder().encode(transfer)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy.removeValue(forKey: "flippedHorizontally")
            legacy.removeValue(forKey: "flippedVertically")
            let decoded = try JSONDecoder().decode(PaintTextTransfer.self, from: JSONSerialization.data(withJSONObject: legacy))
            let legacyObject = try decoded.object()
            XCTAssertFalse(legacyObject.flippedHorizontally)
            XCTAssertFalse(legacyObject.flippedVertically)
            XCTAssertEqual(legacyObject.text, original.text)
        }
    }

    @MainActor private static func textEngine() -> PaintEngine {
        _ = NSApplication.shared
        let engine = PaintEngine(width: 200, height: 100)
        engine.fontSize = 18
        return engine
    }

    private static func pattern(width: Int, height: Int, alpha: Bool = true) -> Bitmap {
        var result = Bitmap(width: width, height: height, white: false)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let a = alpha ? (x + y * width) % 255 + 1 : 255
                result.pixels[i] = UInt8((x * 7 + y * 13) % (a + 1))
                result.pixels[i + 1] = UInt8((x * 19 + y * 3) % (a + 1))
                result.pixels[i + 2] = UInt8((x * 11 + y * 23) % (a + 1))
                result.pixels[i + 3] = UInt8(a)
            }
        }
        return result
    }

    private static func reflected(_ source: Bitmap, horizontal: Bool = false, vertical: Bool = false) -> Bitmap {
        var output = Bitmap(width: source.width, height: source.height, white: false)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let target = (y * source.width + x) * 4
                let sx = horizontal ? source.width - 1 - x : x
                let sy = vertical ? source.height - 1 - y : y
                let origin = (sy * source.width + sx) * 4
                output.pixels.replaceSubrange(target..<(target + 4), with: source.pixels[origin..<(origin + 4)])
            }
        }
        return output
    }

    private static func bitmap(_ data: Data) throws -> Bitmap {
        try Bitmap(image: XCTUnwrap(NSImage(data: data)))
    }
}
