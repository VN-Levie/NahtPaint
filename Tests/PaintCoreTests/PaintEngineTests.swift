import AppKit
import XCTest
@testable import PaintCore

final class PaintEngineTests: XCTestCase {
    func testFirstPasteUsesPhysicalPixelsAndKeepsTopLeftOrientation() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            let source = Self.image(width: 4, height: 2, pixels: [.red, .red, .green, .green, .blue, .blue, .white, .white], logicalScale: 2)

            try engine.pasteImage(source)

            XCTAssertEqual(engine.width, 4)
            XCTAssertEqual(engine.height, 2)
            XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 4, height: 2))
            let exported = try Self.bitmap(engine.exportPNG())
            XCTAssertEqual(exported.pixelsWide, 4)
            XCTAssertEqual(exported.pixelsHigh, 2)
            try Self.assertPixel(exported, x: 0, y: 0, equals: .red)
            try Self.assertPixel(exported, x: 3, y: 0, equals: .green)
            try Self.assertPixel(exported, x: 0, y: 1, equals: .blue)
            try Self.assertPixel(exported, x: 3, y: 1, equals: .white)
            XCTAssertNotNil(engine.selectionRect, "Copying/exporting should leave the editable floating image intact")
        }
    }

    func testCancellingFirstPasteRestoresOriginalCanvasAndCommitIsUndoable() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            engine.newCanvas(width: 7, height: 5)
            let source = Self.image(width: 2, height: 2, pixels: [.red, .green, .blue, .white])

            try engine.pasteImage(source)
            engine.cancelSelection()
            XCTAssertEqual(engine.width, 7)
            XCTAssertEqual(engine.height, 5)
            XCTAssertNil(engine.selectionRect)
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 0, y: 0, equals: .white)

            try engine.pasteImage(source)
            engine.commitSelection()
            XCTAssertEqual(engine.width, 2)
            XCTAssertEqual(engine.height, 2)
            XCTAssertNil(engine.selectionRect)
            engine.undo()
            XCTAssertEqual(engine.width, 7)
            XCTAssertEqual(engine.height, 5)
            engine.redo()
            XCTAssertEqual(engine.width, 2)
            XCTAssertEqual(engine.height, 2)
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 0, y: 1, equals: .blue)
        }
    }

    func testPastedOverlayMovesAndCompositesWithoutErasingBackground() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 4, height: 3, pixels: Array(repeating: .blue, count: 12)))
            try engine.pasteImage(Self.image(width: 2, height: 2, pixels: [.red, .clear, .green, .white]))
            engine.moveSelection(to: CGPoint(x: 1, y: 1))
            engine.commitSelection()

            let result = try Self.bitmap(engine.canvasImage())
            try Self.assertPixel(result, x: 0, y: 0, equals: .blue)
            try Self.assertPixel(result, x: 1, y: 1, equals: .red)
            try Self.assertPixel(result, x: 2, y: 1, equals: .blue)
            try Self.assertPixel(result, x: 1, y: 2, equals: .green)
            try Self.assertPixel(result, x: 2, y: 2, equals: .white)

            engine.undo()
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 1, y: 1, equals: .blue)
            engine.redo()
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 1, y: 1, equals: .red)
        }
    }

    func testMoveExistingSelectionCutsSourceAndCancelRestoresIt() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            let source = Self.image(width: 3, height: 2, pixels: [.red, .green, .blue, .blue, .green, .red])
            try engine.loadImage(source)
            engine.select(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            engine.moveSelection(to: CGPoint(x: 2, y: 1))
            engine.cancelSelection()
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 0, y: 0, equals: .red)

            engine.select(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            engine.moveSelection(to: CGPoint(x: 1, y: 1))
            engine.commitSelection()
            let result = try Self.bitmap(engine.canvasImage())
            try Self.assertPixel(result, x: 0, y: 0, equals: .white)
            try Self.assertPixel(result, x: 1, y: 1, equals: .red)
            try Self.assertPixel(result, x: 0, y: 1, equals: .blue)
            engine.undo()
            let restored = try Self.bitmap(engine.canvasImage())
            try Self.assertPixel(restored, x: 0, y: 0, equals: .red)
            try Self.assertPixel(restored, x: 1, y: 1, equals: .green)
        }
    }

    func testSelectionCopyAndCropUseTopLeftPixelCoordinates() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 3, height: 2, pixels: [.red, .green, .blue, .blue, .white, .red]))
            XCTAssertNil(try engine.selectionPNG())
            engine.select(rect: CGRect(x: 1, y: 0, width: 2, height: 1))
            let selection = try Self.bitmap(XCTUnwrap(engine.selectionPNG()))
            XCTAssertEqual(selection.pixelsWide, 2)
            XCTAssertEqual(selection.pixelsHigh, 1)
            try Self.assertPixel(selection, x: 0, y: 0, equals: .green)
            try Self.assertPixel(selection, x: 1, y: 0, equals: .blue)

            engine.cropToSelection()
            XCTAssertEqual(engine.width, 2)
            XCTAssertEqual(engine.height, 1)
            XCTAssertNil(engine.selectionRect)
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 0, y: 0, equals: .green)
            engine.undo()
            XCTAssertEqual(engine.width, 3)
            XCTAssertEqual(engine.height, 2)
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 2, y: 1, equals: .red)
        }
    }

    func testUnmovedSelectionPreservesPartialAlphaAndDeleteIsUndoable() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            let translucent = Pixel(red: 255, green: 0, blue: 0, alpha: 128)
            try engine.loadImage(Self.image(width: 2, height: 1, pixels: [translucent, .blue]))
            engine.selectAll()
            engine.commitSelection()
            try Self.assertPixel(Self.bitmap(engine.exportPNG()), x: 0, y: 0, equals: translucent)

            engine.select(rect: CGRect(x: 1, y: 0, width: 1, height: 1))
            engine.deleteSelection()
            XCTAssertNil(engine.selectionRect)
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 1, y: 0, equals: .white)
            engine.undo()
            try Self.assertPixel(Self.bitmap(engine.canvasImage()), x: 1, y: 0, equals: .blue)
        }
    }

    func testCanvasResizePreservesTopLeftAndRejectsUnsafeDimensions() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 2, height: 2, pixels: [.red, .green, .blue, .white]))
            try engine.resizeCanvas(width: 4, height: 3, scaleImage: false)
            let result = try Self.bitmap(engine.canvasImage())
            try Self.assertPixel(result, x: 0, y: 0, equals: .red)
            try Self.assertPixel(result, x: 0, y: 1, equals: .blue)
            try Self.assertPixel(result, x: 3, y: 2, equals: .white)

            XCTAssertThrowsError(try engine.resizeCanvas(width: 0, height: 3, scaleImage: false))
            XCTAssertThrowsError(try engine.resizeCanvas(width: 8_193, height: 1, scaleImage: false))
            XCTAssertThrowsError(try engine.resizeCanvas(width: 6_000, height: 6_000, scaleImage: false))
            XCTAssertEqual(engine.width, 4)
            XCTAssertEqual(engine.height, 3)
            engine.undo()
            XCTAssertEqual(engine.width, 2)
            XCTAssertEqual(engine.height, 2)
        }
    }

    func testPNGKeepsAlphaAndJPEGFlattensAgainstWhite() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 8, height: 8, pixels: Array(repeating: .clear, count: 64)))
            let png = try Self.bitmap(engine.exportPNG())
            XCTAssertEqual(try Self.pixel(png, x: 4, y: 4).alpha, 0)
            let jpeg = try Self.bitmap(engine.exportJPEG())
            XCTAssertEqual(jpeg.pixelsWide, 8)
            XCTAssertEqual(jpeg.pixelsHigh, 8)
            XCTAssertFalse(jpeg.hasAlpha)
            try Self.assertPixel(jpeg, x: 4, y: 4, equals: .white, tolerance: 3)
        }
    }

    func testBrushStrokeUsesTopLeftCoordinatesAndUndoRestoresCanvas() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 16, height: 12)
            engine.tool = .brush
            engine.brushSize = 3
            engine.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            engine.beginStroke(at: CGPoint(x: 2, y: 2))
            engine.continueStroke(to: CGPoint(x: 6, y: 2))
            engine.endStroke()

            let painted = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(painted, x: 2, y: 2, equals: .red)
            try Self.assertPixel(painted, x: 5, y: 2, equals: .red)
            try Self.assertPixel(painted, x: 2, y: 10, equals: .white)
            engine.undo()
            let restored = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(restored, x: 2, y: 2, equals: .white)
            try Self.assertPixel(restored, x: 5, y: 2, equals: .white)
        }
    }

    func testFloodFillOnlyChangesConnectedRegionAndSupportsUndo() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 5, height: 3, pixels: [
                .white, .white, .blue, .white, .white,
                .white, .white, .blue, .white, .white,
                .white, .white, .blue, .white, .white
            ]))
            engine.tool = .fill
            engine.color = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            engine.beginStroke(at: CGPoint(x: 0, y: 0))
            engine.endStroke()

            let filled = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(filled, x: 0, y: 0, equals: .green)
            try Self.assertPixel(filled, x: 1, y: 2, equals: .green)
            try Self.assertPixel(filled, x: 2, y: 1, equals: .blue)
            try Self.assertPixel(filled, x: 3, y: 1, equals: .white)
            engine.undo()
            try Self.assertPixel(Self.bitmap(engine.exportPNG()), x: 0, y: 0, equals: .white)
        }
    }

    func testTextAppearsAtUpperCanvasAndUndoRemovesIt() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine(width: 96, height: 72)
            engine.fontSize = 18
            engine.color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            engine.insertText("Paint", at: CGPoint(x: 3, y: 3), width: 80)

            let withText = try Self.bitmap(engine.exportPNG())
            var upperChangedPixels = 0
            var bottomChangedPixels = 0
            for y in 0..<72 {
                for x in 0..<96 {
                    let pixel = try Self.pixel(withText, x: x, y: y)
                    if min(pixel.red, pixel.green, pixel.blue) < 240 {
                        if y < 36 { upperChangedPixels += 1 }
                        if y >= 36 { bottomChangedPixels += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(upperChangedPixels, 20, "The text should rasterize into the upper canvas")
            XCTAssertEqual(bottomChangedPixels, 0, "Text near the top must not be vertically flipped to the bottom")
            engine.undo()
            let restored = try Self.bitmap(engine.exportPNG())
            for y in 0..<36 {
                for x in 0..<96 {
                    try Self.assertPixel(restored, x: x, y: y, equals: .white)
                }
            }
        }
    }

    func testClipboardDocumentIsDirtyUntilSaved() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 1, height: 1, pixels: [.red]))
            engine.markUnsaved()
            XCTAssertTrue(engine.isDirty)
            engine.markSaved()
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testOversizedSelectionIsRejectedAndFailedCutKeepsData() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 2, height: 1, pixels: [.red, .blue]))
            engine.selectAll()
            engine.resizeSelection(to: CGSize(width: 8192, height: 8192))
            XCTAssertEqual(engine.selectionRect?.size, CGSize(width: 2, height: 1))
            // Exercise the defensive cut failure path without touching the system clipboard.
            engine.selection?.rect.size = CGSize(width: 8192, height: 8192)
            engine.cutToClipboard()
            XCTAssertTrue(engine.hasSelection)
            engine.cancelSelection()
            let restored = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(restored, x: 0, y: 0, equals: .red)
            try Self.assertPixel(restored, x: 1, y: 0, equals: .blue)
        }
    }

    func testTextDefaultsRemainTransparentAndTextColorIsIndependentFromBrushColor() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 96, height: 64, pixels: Array(repeating: .clear, count: 96 * 64)))
            XCTAssertFalse(engine.textBorder)
            XCTAssertFalse(engine.textBackgroundEnabled)
            engine.fontSize = 18
            engine.color = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            engine.textColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            engine.insertText("Paint", at: CGPoint(x: 4, y: 4), width: 80)

            let result = try Self.bitmap(engine.exportPNG())
            XCTAssertEqual(try Self.pixel(result, x: 4, y: 4).alpha, 0, "Default text must not create a border or opaque background")
            XCTAssertEqual(try Self.pixel(result, x: 6, y: 6).alpha, 0, "Text padding must stay transparent")
            var redPixels = 0
            var greenPixels = 0
            for y in 0..<64 {
                for x in 0..<96 {
                    let pixel = try Self.pixel(result, x: x, y: y)
                    guard pixel.alpha > 200 else { continue }
                    if pixel.red > 200 && pixel.green < 20 && pixel.blue < 20 { redPixels += 1 }
                    if pixel.green > 200 && pixel.red < 20 && pixel.blue < 20 { greenPixels += 1 }
                }
            }
            XCTAssertGreaterThan(redPixels, 20, "Glyphs should use the separate text color")
            XCTAssertEqual(greenPixels, 0, "The brush color must not color text")
            engine.undo()
            let restored = try Self.bitmap(engine.exportPNG())
            for y in 0..<64 {
                for x in 0..<96 {
                    XCTAssertEqual(try Self.pixel(restored, x: x, y: y).alpha, 0)
                }
            }
        }
    }

    func testTextBackgroundAndBorderStayInsideBoxAndUndoTogether() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 96, height: 64, pixels: Array(repeating: .clear, count: 96 * 64)))
            engine.fontSize = 18
            engine.textColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            engine.textBackgroundEnabled = true
            engine.textBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            engine.textBorder = true
            engine.insertText("A", at: CGPoint(x: 4, y: 4), width: 80)

            let result = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(result, x: 6, y: 6, equals: .blue)
            try Self.assertPixel(result, x: 4, y: 5, equals: .red)
            XCTAssertEqual(try Self.pixel(result, x: 3, y: 5).alpha, 0)
            XCTAssertEqual(try Self.pixel(result, x: 5, y: 3).alpha, 0)
            XCTAssertEqual(try Self.pixel(result, x: 90, y: 60).alpha, 0)
            engine.undo()
            let restored = try Self.bitmap(engine.exportPNG())
            XCTAssertEqual(try Self.pixel(restored, x: 6, y: 6).alpha, 0)
            XCTAssertEqual(try Self.pixel(restored, x: 4, y: 5).alpha, 0)
            XCTAssertFalse(engine.isDirty)
        }
    }

    func testCropToolMovesWindowWithoutMovingImageUntilConfirmed() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 4, height: 2, pixels: [
                .red, .green, .blue, .white,
                .white, .blue, .green, .red
            ]))
            engine.tool = .crop
            engine.select(rect: CGRect(x: 0, y: 0, width: 1, height: 2))
            XCTAssertEqual(engine.tool, .crop)
            XCTAssertFalse(engine.isDirty)
            engine.moveSelection(to: CGPoint(x: 2, y: 0))
            XCTAssertEqual(engine.selectionRect, CGRect(x: 2, y: 0, width: 1, height: 2))
            XCTAssertFalse(engine.isDirty, "Choosing a crop region must not change document pixels")
            XCTAssertEqual(engine.width, 4)
            XCTAssertEqual(engine.height, 2)
            let preview = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(preview, x: 0, y: 0, equals: .red)
            try Self.assertPixel(preview, x: 2, y: 0, equals: .blue)

            engine.confirmSelection()
            XCTAssertEqual(engine.width, 1)
            XCTAssertEqual(engine.height, 2)
            XCTAssertNil(engine.selectionRect)
            XCTAssertTrue(engine.isDirty)
            let cropped = try Self.bitmap(engine.exportPNG())
            try Self.assertPixel(cropped, x: 0, y: 0, equals: .blue)
            try Self.assertPixel(cropped, x: 0, y: 1, equals: .green)
            engine.undo()
            XCTAssertEqual(engine.width, 4)
            XCTAssertEqual(engine.height, 2)
            XCTAssertFalse(engine.isDirty)
            try Self.assertPixel(Self.bitmap(engine.exportPNG()), x: 0, y: 0, equals: .red)
        }
    }

    func testCancellingCropToolLeavesOriginalPixelsAndDimensionsUntouched() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            let pixels: [Pixel] = [.red, .green, .blue, .white, .white, .blue, .green, .red]
            try engine.loadImage(Self.image(width: 4, height: 2, pixels: pixels))
            engine.tool = .crop
            engine.select(rect: CGRect(x: 0, y: 0, width: 1, height: 2))
            engine.moveSelection(to: CGPoint(x: 2, y: 0))
            engine.cancelSelection()

            XCTAssertEqual(engine.tool, .crop)
            XCTAssertEqual(engine.width, 4)
            XCTAssertEqual(engine.height, 2)
            XCTAssertNil(engine.selectionRect)
            XCTAssertFalse(engine.isDirty)
            let result = try Self.bitmap(engine.exportPNG())
            for (index, expected) in pixels.enumerated() {
                try Self.assertPixel(result, x: index % 4, y: index / 4, equals: expected)
            }
        }
    }

    private struct Pixel: Equatable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int

        static let red = Pixel(red: 255, green: 0, blue: 0, alpha: 255)
        static let green = Pixel(red: 0, green: 255, blue: 0, alpha: 255)
        static let blue = Pixel(red: 0, green: 0, blue: 255, alpha: 255)
        static let white = Pixel(red: 255, green: 255, blue: 255, alpha: 255)
        static let clear = Pixel(red: 0, green: 0, blue: 0, alpha: 0)
    }

    /// Rows are deliberately supplied from the top to expose vertical flips.
    private static func image(width: Int, height: Int, pixels: [Pixel], logicalScale: CGFloat = 1) -> NSImage {
        precondition(pixels.count == width * height)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        for (index, pixel) in pixels.enumerated() {
            var values = [pixel.red, pixel.green, pixel.blue, pixel.alpha]
            bitmap.setPixel(&values, atX: index % width, y: index / width)
        }
        let result = NSImage(size: NSSize(width: CGFloat(width) / logicalScale, height: CGFloat(height) / logicalScale))
        result.addRepresentation(bitmap.retagging(with: .sRGB)!)
        return result
    }

    private static func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private static func bitmap(_ data: Data) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> Pixel {
        // colorAt creates calibrated NSColor values on macOS even for tagged sRGB
        // bitmaps. Read stored samples directly to avoid a second profile conversion.
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples, atX: x, y: y)
        let maximum = Double((1 << bitmap.bitsPerSample) - 1)
        let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : samples.count - 1
        let alpha = bitmap.hasAlpha ? Double(samples[alphaIndex]) / maximum : 1
        let colorSamples = samples.enumerated().compactMap { index, value in
            bitmap.hasAlpha && index == alphaIndex ? nil : Double(value) / maximum
        }
        let channels: [Double]
        if colorSamples.count == 1 {
            channels = Array(repeating: colorSamples[0], count: 3)
        } else {
            XCTAssertEqual(colorSamples.count, 3, "Expected RGB or grayscale output")
            channels = Array(colorSamples.prefix(3))
        }
        let premultiplied = bitmap.hasAlpha && !bitmap.bitmapFormat.contains(.alphaNonpremultiplied)
        func component(_ channel: Double) -> Int {
            let straight = premultiplied && alpha > 0 ? channel / alpha : channel
            return Int((min(1, max(0, straight)) * 255).rounded())
        }
        return Pixel(
            red: component(channels[0]),
            green: component(channels[1]),
            blue: component(channels[2]),
            alpha: Int((alpha * 255).rounded())
        )
    }

    private static func assertPixel(
        _ bitmap: NSBitmapImageRep,
        x: Int,
        y: Int,
        equals expected: Pixel,
        tolerance: Int = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try pixel(bitmap, x: x, y: y)
        XCTAssertEqual(Double(actual.red), Double(expected.red), accuracy: Double(tolerance), "Red at (\(x), \(y))", file: file, line: line)
        XCTAssertEqual(Double(actual.green), Double(expected.green), accuracy: Double(tolerance), "Green at (\(x), \(y))", file: file, line: line)
        XCTAssertEqual(Double(actual.blue), Double(expected.blue), accuracy: Double(tolerance), "Blue at (\(x), \(y))", file: file, line: line)
        XCTAssertEqual(Double(actual.alpha), Double(expected.alpha), accuracy: Double(tolerance), "Alpha at (\(x), \(y))", file: file, line: line)
    }
}
