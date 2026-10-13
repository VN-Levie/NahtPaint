import AppKit
import XCTest
@testable import PaintCore

final class EditableTextTests: XCTestCase {
    func testInsertAndExportKeepTextEditableWithoutChangingRaster() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            let rasterBefore = engine.bitmap.pixels
            let exportBefore = try engine.exportPNG()
            engine.insertText("Editable", at: CGPoint(x: 8, y: 6), width: 140)

            let object = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(object.text, "Editable")
            XCTAssertEqual(object.position, CGPoint(x: 8, y: 6))
            XCTAssertEqual(engine.bitmap.pixels, rasterBefore)
            let rendered = try engine.exportPNG()
            XCTAssertNotEqual(rendered, exportBefore, "Export should render foreground text")
            XCTAssertEqual(try engine.exportPNG(), rendered)
            engine.confirmSelection()
            XCTAssertEqual(engine.textObjects.map(\.id), [object.id])
            XCTAssertEqual(engine.bitmap.pixels, rasterBefore, "Confirming or exporting must not flatten text")
            engine.undo()
            XCTAssertTrue(engine.textObjects.isEmpty)
            XCTAssertEqual(try engine.exportPNG(), exportBefore)
        }
    }

    func testEditingUpdatesSameObjectAndStyleInOneUndoStep() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Before", at: CGPoint(x: 9, y: 7), width: 140)
            let original = try XCTUnwrap(engine.textObjects.first)
            let rasterBefore = engine.bitmap.pixels
            let editing = try XCTUnwrap(engine.beginTextEditing(id: original.id))
            XCTAssertEqual(editing.id, original.id)
            XCTAssertEqual(engine.editingTextID, original.id)
            let newColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            let newBackground = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            engine.fontSize = 24
            engine.textColor = newColor
            engine.textBorder = true
            engine.textBackgroundEnabled = true
            engine.textBackgroundColor = newBackground
            engine.updateText(id: original.id, text: "After\nTiếng Việt", layoutWidth: 110)

            let changed = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(changed.id, original.id)
            XCTAssertEqual(changed.text, "After\nTiếng Việt")
            XCTAssertEqual(changed.layoutWidth, 110)
            XCTAssertEqual(changed.position, original.position)
            XCTAssertEqual(changed.style.fontSize, 24)
            XCTAssertEqual(changed.style.color, newColor)
            XCTAssertTrue(changed.style.border)
            XCTAssertTrue(changed.style.backgroundEnabled)
            XCTAssertEqual(changed.style.backgroundColor, newBackground)
            XCTAssertNil(engine.editingTextID)
            XCTAssertEqual(engine.bitmap.pixels, rasterBefore)
            engine.undo()
            let restored = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(restored.id, original.id)
            XCTAssertEqual(restored.text, original.text)
            XCTAssertEqual(restored.layoutWidth, original.layoutWidth)
            XCTAssertEqual(restored.style.fontSize, original.style.fontSize)
            XCTAssertEqual(restored.style.color, original.style.color)
            XCTAssertEqual(restored.style.border, original.style.border)
            XCTAssertEqual(restored.style.backgroundEnabled, original.style.backgroundEnabled)
            engine.redo()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.text, "After\nTiếng Việt")
        }
    }

    func testCancelEditingLeavesObjectAndSavedDocumentUnchanged() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Keep this", at: CGPoint(x: 8, y: 6), width: 140)
            engine.commitSelection()
            engine.markSaved()
            let original = try XCTUnwrap(engine.textObjects.first)
            let before = try engine.exportPNG()
            XCTAssertNotNil(engine.beginTextEditing(id: original.id))
            engine.fontSize = 32
            engine.textColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            engine.textBorder = true
            engine.cancelTextEditing()

            let restored = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(restored.id, original.id)
            XCTAssertEqual(restored.text, original.text)
            XCTAssertEqual(restored.style.fontSize, original.style.fontSize)
            XCTAssertEqual(restored.style.color, original.style.color)
            XCTAssertEqual(restored.style.border, original.style.border)
            XCTAssertEqual(restored.position, original.position)
            XCTAssertNil(engine.editingTextID)
            XCTAssertFalse(engine.isDirty)
            XCTAssertEqual(try engine.exportPNG(), before)
        }
    }

    func testDraggingTextCoalescesMovesAndSupportsRedoAndNudge() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Move", at: CGPoint(x: 8, y: 6), width: 100)
            let original = try XCTUnwrap(engine.textObjects.first)
            engine.selectText(id: original.id)
            XCTAssertEqual(engine.selectedTextID, original.id)
            engine.beginTextMove()
            engine.moveSelectedText(to: CGPoint(x: 20, y: 12))
            engine.moveSelectedText(to: CGPoint(x: 30, y: 18))
            engine.moveSelectedText(to: CGPoint(x: 40, y: 24))
            engine.endTextMove()

            XCTAssertEqual(engine.textObjects.first?.position, CGPoint(x: 40, y: 24))
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position, "One undo should revert the entire drag")
            engine.redo()
            XCTAssertEqual(engine.textObjects.first?.position, CGPoint(x: 40, y: 24))
            engine.selectText(id: original.id)
            engine.nudgeSelectedText(dx: 1, dy: -1)
            XCTAssertEqual(engine.textObjects.first?.position, CGPoint(x: 41, y: 23))
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.position, CGPoint(x: 40, y: 24))
        }
    }

    func testDeleteSelectedTextAndUndoRestoreObjectIdentity() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            let blank = try engine.exportPNG()
            engine.insertText("Delete me", at: CGPoint(x: 8, y: 6), width: 140)
            let original = try XCTUnwrap(engine.textObjects.first)
            let rendered = try engine.exportPNG()
            engine.selectText(id: original.id)
            engine.deleteSelection()

            XCTAssertTrue(engine.textObjects.isEmpty)
            XCTAssertNil(engine.selectedTextID)
            XCTAssertEqual(try engine.exportPNG(), blank)
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.text, original.text)
            XCTAssertEqual(try engine.exportPNG(), rendered)
        }
    }

    func testMarqueeIncludesWholeTextAndMovesAndScalesSameObject() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine(width: 320, height: 200)
            engine.insertText("Group", at: CGPoint(x: 20, y: 15), width: 130)
            let original = try XCTUnwrap(engine.textObjects.first)
            engine.select(rect: CGRect(x: original.bounds.minX + 2, y: original.bounds.minY + 2, width: 1, height: 1))
            let selected = try XCTUnwrap(engine.selectionRect)
            XCTAssertTrue(selected.contains(original.bounds), "Intersecting a text object should select all of its bounds")
            let destination = CGPoint(x: selected.minX + 16, y: selected.minY + 10)
            engine.moveSelection(to: destination)
            engine.resizeSelection(to: CGSize(width: selected.width * 2, height: selected.height * 2))
            engine.commitSelection()

            let changed = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(engine.textObjects.count, 1)
            XCTAssertEqual(changed.id, original.id)
            XCTAssertEqual(changed.text, original.text)
            XCTAssertEqual(changed.scaleX, original.scaleX * 2, accuracy: 0.001)
            XCTAssertEqual(changed.scaleY, original.scaleY * 2, accuracy: 0.001)
            XCTAssertEqual(changed.position.x, destination.x + (original.position.x - selected.minX) * 2, accuracy: 0.001)
            XCTAssertEqual(changed.position.y, destination.y + (original.position.y - selected.minY) * 2, accuracy: 0.001)
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position)
            XCTAssertEqual(engine.textObjects.first?.scaleX, original.scaleX)
            XCTAssertEqual(engine.textObjects.first?.scaleY, original.scaleY)
        }
    }

    func testUnchangedSelectAllPreservesTextAndDoesNotAddUndoStep() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Still editable", at: CGPoint(x: 8, y: 6), width: 160)
            engine.commitSelection()
            engine.markSaved()
            let original = try XCTUnwrap(engine.textObjects.first)
            let rasterBefore = engine.bitmap.pixels
            let exportBefore = try engine.exportPNG()
            engine.selectAll()
            engine.commitSelection()

            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position)
            XCTAssertEqual(engine.bitmap.pixels, rasterBefore)
            XCTAssertEqual(try engine.exportPNG(), exportBefore)
            XCTAssertFalse(engine.isDirty)
            engine.undo()
            XCTAssertTrue(engine.textObjects.isEmpty, "An unchanged selection must not add a no-op undo step")
        }
    }

    func testCropTranslatesAndClipsTextWithoutLosingIdentity() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine(width: 96, height: 64)
            engine.textBackgroundEnabled = true
            engine.textBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            engine.insertText("Wide text", at: CGPoint(x: 8, y: 8), width: 80)
            let original = try XCTUnwrap(engine.textObjects.first)
            let exportBefore = try engine.exportPNG()
            let crop = CGRect(x: 10, y: 10, width: 4, height: 3)
            engine.tool = .crop
            engine.select(rect: crop)
            XCTAssertEqual(engine.selectionRect, crop, "Cropping must not expand to fit intersected text")
            engine.confirmSelection()

            let cropped = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(cropped.id, original.id)
            XCTAssertEqual(cropped.text, original.text)
            XCTAssertEqual(cropped.position, CGPoint(x: original.position.x - crop.minX, y: original.position.y - crop.minY))
            XCTAssertEqual(engine.width, 4)
            XCTAssertEqual(engine.height, 3)
            XCTAssertEqual(try Self.rgba(engine.exportPNG(), x: 0, y: 0), [0, 0, 255, 255])

            try engine.resizeCanvas(width: 96, height: 64, scaleImage: false)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(try Self.rgba(engine.exportPNG(), x: 8, y: 8), [255, 255, 255, 255], "Enlarging the canvas must not reveal text removed by the crop")
            engine.undo()
            XCTAssertEqual(engine.width, 4)
            engine.undo()
            XCTAssertEqual(engine.width, 96)
            XCTAssertEqual(engine.height, 64)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position)
            XCTAssertEqual(try engine.exportPNG(), exportBefore)
        }
    }

    func testImageResizeTransformsTextWhileCanvasResizePreservesItsGeometry() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine(width: 100, height: 80)
            engine.insertText("Scale", at: CGPoint(x: 12, y: 8), width: 80)
            let original = try XCTUnwrap(engine.textObjects.first)
            try engine.resizeCanvas(width: 200, height: 120, scaleImage: true)

            let scaled = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(scaled.id, original.id)
            XCTAssertEqual(scaled.position, CGPoint(x: 24, y: 12))
            XCTAssertEqual(scaled.scaleX, original.scaleX * 2, accuracy: 0.001)
            XCTAssertEqual(scaled.scaleY, original.scaleY * 1.5, accuracy: 0.001)
            XCTAssertEqual(scaled.layoutWidth, original.layoutWidth, "Image scaling should preserve editable text layout")
            try engine.resizeCanvas(width: 220, height: 150, scaleImage: false)
            let expanded = try XCTUnwrap(engine.textObjects.first)
            XCTAssertEqual(expanded.id, original.id)
            XCTAssertEqual(expanded.position, scaled.position)
            XCTAssertEqual(expanded.scaleX, scaled.scaleX)
            XCTAssertEqual(expanded.scaleY, scaled.scaleY)
            engine.undo()
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position)
            XCTAssertEqual(engine.textObjects.first?.scaleX, original.scaleX)
            XCTAssertEqual(engine.textObjects.first?.scaleY, original.scaleY)
        }
    }

    func testBrushChangesRasterWithoutDeletingOrFlatteningText() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Keep editable", at: CGPoint(x: 8, y: 6), width: 160)
            let original = try XCTUnwrap(engine.textObjects.first)
            let rasterBefore = engine.bitmap.pixels
            engine.tool = .brush
            engine.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            engine.brushSize = 5
            engine.beginStroke(at: CGPoint(x: 170, y: 90))
            engine.continueStroke(to: CGPoint(x: 180, y: 90))
            engine.endStroke()

            XCTAssertNotEqual(engine.bitmap.pixels, rasterBefore)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.text, original.text)
            XCTAssertEqual(try Self.rgba(engine.exportPNG(), x: 175, y: 90), [255, 0, 0, 255])
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, rasterBefore)
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertNotNil(engine.beginTextEditing(id: original.id))
            engine.cancelTextEditing()
        }
    }

    func testCopyPasteRetainsEditableTextAndCancelRemovesOnlyNewObjects() async throws {
        try await MainActor.run {
            let source = Self.makeEngine()
            source.textBorder = true
            source.insertText("Editable copy", at: CGPoint(x: 20, y: 20), width: 160)
            let original = try XCTUnwrap(source.textObjects.first)
            let copiedPixels = try XCTUnwrap(source.selectionPNG())
            let board = NSPasteboard(name: .init("NathPaint.Tests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            try source.copy(to: board)
            XCTAssertEqual(source.textObjects.first?.id, original.id)
            let target = Self.makeEngine()
            target.paste(from: board)
            XCTAssertEqual(target.textObjects.count, 1)
            XCTAssertNotEqual(target.textObjects.first?.id, original.id)
            XCTAssertEqual(target.textObjects.first?.text, original.text)
            XCTAssertEqual(target.textObjects.first?.style, original.style)
            XCTAssertEqual(try target.exportPNG(), copiedPixels)
            target.cancelSelection()
            XCTAssertTrue(target.textObjects.isEmpty)
            XCTAssertEqual(target.width, 200)
            target.paste(from: board)
            target.commitSelection()
            let pasted = try XCTUnwrap(target.textObjects.first)
            XCTAssertNotNil(target.beginTextEditing(id: pasted.id))
            target.updateText(id: pasted.id, text: "Changed", layoutWidth: pasted.layoutWidth)
            XCTAssertEqual(target.textObjects.first?.id, pasted.id)
            XCTAssertEqual(target.textObjects.first?.text, "Changed")
            target.undo()
            XCTAssertEqual(target.textObjects.first?.text, original.text)
        }
    }

    func testCopyEntireCanvasDoesNotBakeTextIntoPastedRaster() async throws {
        try await MainActor.run {
            let source = Self.makeEngine()
            source.insertText("Foreground", at: CGPoint(x: 8, y: 8), width: 160)
            let expected = try source.exportPNG()
            let board = NSPasteboard(name: .init("NathPaint.Tests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            try source.copy(to: board, entireCanvas: true)
            let target = Self.makeEngine()
            target.paste(from: board); target.commitSelection()
            XCTAssertEqual(target.textObjects.count, 1)
            XCTAssertEqual(target.bitmap.pixels, source.bitmap.pixels)
            XCTAssertEqual(try target.exportPNG(), expected)
            target.selectText(id: try XCTUnwrap(target.textObjects.first?.id))
            target.deleteSelection()
            XCTAssertTrue(target.textObjects.isEmpty)
            XCTAssertEqual(target.bitmap.pixels, source.bitmap.pixels)
        }
    }

    func testSelectedTextStyleControlsApplyWithoutReopeningEditor() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Style", at: CGPoint(x: 8, y: 8), width: 120)
            let original = try XCTUnwrap(engine.textObjects.first)
            engine.textColor = .blue
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.style.color, .blue)
            XCTAssertNil(engine.editingTextID)
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.style, original.style)
        }
    }

    func testCancellingPendingTextDragRestoresSavedStateWithoutExtraUndo() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Cancel drag", at: CGPoint(x: 8, y: 6), width: 160)
            engine.commitSelection()
            engine.markSaved()
            let original = try XCTUnwrap(engine.textObjects.first)
            engine.selectText(id: original.id)
            engine.beginTextMove()
            engine.moveSelectedText(to: CGPoint(x: 30, y: 22))
            XCTAssertTrue(engine.isDirty)

            engine.cancelSelection()
            engine.endTextMove() // The mouse-up event can still arrive after Escape.
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position)
            XCTAssertFalse(engine.isDirty)
            engine.undo()
            XCTAssertTrue(engine.textObjects.isEmpty, "Cancelling a drag must not add a history entry after the text insertion")
        }
    }

    func testExportDuringPendingTextDragFinalizesMoveBeforeSaveAndMouseUp() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine()
            engine.insertText("Save drag", at: CGPoint(x: 8, y: 6), width: 160)
            engine.commitSelection()
            engine.markSaved()
            let original = try XCTUnwrap(engine.textObjects.first)
            engine.selectText(id: original.id)
            engine.beginTextMove()
            let destination = CGPoint(x: 30, y: 22)
            engine.moveSelectedText(to: destination)

            let exported = try engine.exportPNG()
            engine.markSaved()
            engine.endTextMove()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, destination)
            XCTAssertFalse(engine.isDirty, "A late mouse-up must not dirty the image that was just exported and marked saved")
            XCTAssertEqual(try engine.exportPNG(), exported)
            engine.undo()
            XCTAssertEqual(engine.textObjects.first?.id, original.id)
            XCTAssertEqual(engine.textObjects.first?.position, original.position)
            engine.redo()
            XCTAssertEqual(engine.textObjects.first?.position, destination)
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testShrinkingCanvasClipsIntersectingTextAndRemovesOutsideTextPermanently() async throws {
        try await MainActor.run {
            let engine = Self.makeEngine(width: 120, height: 80)
            engine.textBackgroundEnabled = true
            engine.textBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            engine.insertText("Wide label", at: CGPoint(x: 10, y: 10), width: 90)
            let intersecting = try XCTUnwrap(engine.textObjects.first)
            engine.insertText("Outside", at: CGPoint(x: 70, y: 45), width: 50)
            engine.commitSelection()
            let originalIDs = engine.textObjects.map(\.id)
            XCTAssertEqual(originalIDs.count, 2)
            let originalExport = try engine.exportPNG()
            XCTAssertEqual(try Self.rgba(originalExport, x: 25, y: 12), [0, 0, 255, 255])
            XCTAssertEqual(try Self.rgba(originalExport, x: 75, y: 47), [0, 0, 255, 255])

            try engine.resizeCanvas(width: 20, height: 20, scaleImage: false)
            XCTAssertEqual(engine.textObjects.map(\.id), [intersecting.id])
            XCTAssertEqual(engine.textObjects.first?.position, intersecting.position)
            XCTAssertEqual(try Self.rgba(engine.exportPNG(), x: 12, y: 12), [0, 0, 255, 255])
            try engine.resizeCanvas(width: 120, height: 80, scaleImage: false)
            XCTAssertEqual(engine.textObjects.map(\.id), [intersecting.id])
            let expanded = try engine.exportPNG()
            XCTAssertEqual(try Self.rgba(expanded, x: 25, y: 12), [255, 255, 255, 255], "Expansion must not reveal the discarded part of an intersecting text object")
            XCTAssertEqual(try Self.rgba(expanded, x: 75, y: 47), [255, 255, 255, 255], "Expansion must not restore a text object outside the shrunken canvas")
            engine.undo()
            engine.undo()
            XCTAssertEqual(engine.textObjects.map(\.id), originalIDs)
            XCTAssertEqual(try engine.exportPNG(), originalExport)
        }
    }

    @MainActor private static func makeEngine(width: Int = 200, height: Int = 120) -> PaintEngine {
        _ = NSApplication.shared
        let engine = PaintEngine(width: width, height: height)
        engine.fontSize = 18
        engine.textColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return engine
    }

    private static func rgba(_ data: Data, x: Int, y: Int) throws -> [Int] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples, atX: x, y: y)
        let maximum = Double((1 << bitmap.bitsPerSample) - 1)
        let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : samples.count - 1
        let alpha = bitmap.hasAlpha ? Double(samples[alphaIndex]) / maximum : 1
        var colors = samples.enumerated().compactMap { index, value in
            bitmap.hasAlpha && index == alphaIndex ? nil : Double(value) / maximum
        }
        if colors.count == 1 { colors = Array(repeating: colors[0], count: 3) }
        XCTAssertEqual(colors.count, 3)
        let premultiplied = bitmap.hasAlpha && !bitmap.bitmapFormat.contains(.alphaNonpremultiplied)
        return colors.map { channel in
            let straight = premultiplied && alpha > 0 ? channel / alpha : channel
            return Int((min(1, max(0, straight)) * 255).rounded())
        } + [Int((alpha * 255).rounded())]
    }
}
