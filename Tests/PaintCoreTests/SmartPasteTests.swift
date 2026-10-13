import AppKit
import XCTest
@testable import PaintCore

final class SmartPasteTests: XCTestCase {
    func testFirstPasteUsesNaturalDimensionsInEveryMode() async throws {
        try await MainActor.run {
            let engine = PaintEngine(width: 12, height: 8)
            engine.imagePasteMode = .automatic
            for mode in [engine.imagePasteMode, .fitCanvas, .expandCanvas] {
                engine.newCanvas(width: 12, height: 8)
                engine.imagePasteMode = mode
                try engine.pasteImage(Self.image(width: 20, height: 10, rgba: [255, 0, 0, 255]))

                XCTAssertEqual(engine.width, 20)
                XCTAssertEqual(engine.height, 10)
                XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 20, height: 10))
                XCTAssertEqual(engine.selection?.image.width, 20)
                XCTAssertEqual(engine.selection?.image.height, 10)
                engine.cancelSelection()
                XCTAssertEqual(engine.width, 12)
                XCTAssertEqual(engine.height, 8)
            }
        }
    }

    func testFitModeKeepsSourcePixelsAndDoesNotUpscaleSmallImagesOrAlwaysFitView() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 12, height: 8, rgba: [0, 0, 255, 255]))
            engine.imagePasteMode = .fitCanvas
            XCTAssertTrue(engine.fitViewAfterPasting)
            var fitViewCalls = 0
            engine.fitViewAfterImagePaste = { fitViewCalls += 1 }
            try engine.pasteImage(Self.image(width: 24, height: 8, rgba: [255, 0, 0, 255]))

            XCTAssertEqual(engine.width, 12)
            XCTAssertEqual(engine.height, 8)
            XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 12, height: 4))
            XCTAssertEqual(engine.selection?.image.width, 24, "Fitting a floating image must retain its full-resolution source")
            XCTAssertEqual(engine.selection?.image.height, 8)
            XCTAssertEqual(fitViewCalls, 1)
            engine.cancelSelection()

            engine.fitViewAfterPasting = false
            try engine.pasteImage(Self.image(width: 4, height: 2, rgba: [0, 255, 0, 255]))
            XCTAssertEqual(engine.width, 12)
            XCTAssertEqual(engine.height, 8)
            XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 4, height: 2), "Smaller images should keep their natural size")
            XCTAssertEqual(fitViewCalls, 1, "Disabling fit view must suppress its callback")
            engine.cancelSelection()

            engine.fitViewAfterPasting = true
            try engine.pasteImage(Self.image(width: 4, height: 2, rgba: [0, 255, 0, 255]))
            XCTAssertEqual(fitViewCalls, 2)
        }
    }

    func testAutomaticModeFitsAtHalfScaleAndExpandsBelowIt() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 12, height: 8, rgba: [0, 0, 255, 255]))
            engine.imagePasteMode = .automatic
            try engine.pasteImage(Self.image(width: 24, height: 12, rgba: [255, 0, 0, 255]))

            XCTAssertEqual(engine.width, 12)
            XCTAssertEqual(engine.height, 8)
            XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 12, height: 6))
            XCTAssertEqual(engine.selection?.image.width, 24)
            engine.cancelSelection()

            try engine.pasteImage(Self.image(width: 25, height: 10, rgba: [255, 0, 0, 255]))
            XCTAssertEqual(engine.width, 25)
            XCTAssertEqual(engine.height, 10)
            XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 25, height: 10))
            engine.cancelSelection()
            XCTAssertEqual(engine.width, 12)
            XCTAssertEqual(engine.height, 8)
        }
    }

    func testExpansionPreservesRasterAndEditableTextThroughCancelAndUndo() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = PaintEngine()
            try engine.loadImage(Self.image(width: 32, height: 24, rgba: [0, 0, 255, 255]))
            engine.fontSize = 8
            engine.insertText("A", at: CGPoint(x: 2, y: 14), width: 24)
            engine.commitSelection()
            let text = try XCTUnwrap(engine.textObjects.first)
            let originalRaster = engine.bitmap.pixels
            engine.imagePasteMode = .expandCanvas
            let pasted = Self.image(width: 40, height: 12, rgba: [255, 0, 0, 255])
            try engine.pasteImage(pasted)

            XCTAssertEqual(engine.width, 40)
            XCTAssertEqual(engine.height, 24)
            XCTAssertEqual(engine.selectionRect, CGRect(x: 0, y: 0, width: 40, height: 12))
            XCTAssertEqual(engine.textObjects.map(\.id), [text.id])
            XCTAssertEqual(engine.textObjects.first?.position, text.position)
            XCTAssertEqual(try Self.rgba(engine.exportPNG(), x: 0, y: 23), [0, 0, 255, 255], "The old raster outside the paste must survive canvas expansion")
            engine.cancelSelection()
            XCTAssertEqual(engine.width, 32)
            XCTAssertEqual(engine.height, 24)
            XCTAssertEqual(engine.bitmap.pixels, originalRaster)
            XCTAssertEqual(engine.textObjects.map(\.id), [text.id])

            try engine.pasteImage(pasted)
            engine.commitSelection()
            XCTAssertEqual(engine.width, 40)
            XCTAssertEqual(engine.textObjects.map(\.id), [text.id])
            engine.undo()
            XCTAssertEqual(engine.width, 32)
            XCTAssertEqual(engine.height, 24)
            XCTAssertEqual(engine.bitmap.pixels, originalRaster)
            XCTAssertEqual(engine.textObjects.map(\.id), [text.id])
            XCTAssertEqual(engine.textObjects.first?.position, text.position)
        }
    }

    func testInvalidCombinedExpansionFallsBackToFitWithoutAllocatingHugeCanvas() async throws {
        try await MainActor.run {
            let engine = PaintEngine()
            // Each input is tiny; only their proposed combined 8000×4000 canvas exceeds 24 MP.
            try engine.loadImage(Self.image(width: 1, height: 4_000, rgba: [0, 0, 255, 255]))
            let originalRaster = engine.bitmap.pixels
            engine.imagePasteMode = .expandCanvas
            try engine.pasteImage(Self.image(width: 8_000, height: 1, rgba: [255, 0, 0, 255]))

            XCTAssertEqual(engine.width, 1)
            XCTAssertEqual(engine.height, 4_000)
            let fitted = try XCTUnwrap(engine.selectionRect)
            XCTAssertGreaterThan(fitted.width, 0)
            XCTAssertGreaterThan(fitted.height, 0)
            XCTAssertLessThanOrEqual(fitted.width, 1)
            XCTAssertLessThanOrEqual(fitted.height, 4_000)
            XCTAssertEqual(engine.selection?.image.width, 8_000)
            XCTAssertEqual(engine.selection?.image.height, 1)
            engine.cancelSelection()
            XCTAssertEqual(engine.bitmap.pixels, originalRaster)
        }
    }

    private static func image(width: Int, height: Int, rgba: [Int]) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bitmapFormat: .alphaNonpremultiplied, bytesPerRow: width * 4,
                                      bitsPerPixel: 32)!
        var samples = rgba
        for y in 0..<height {
            for x in 0..<width { bitmap.setPixel(&samples, atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap.retagging(with: .sRGB)!)
        return image
    }

    private static func rgba(_ data: Data, x: Int, y: Int) throws -> [Int] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.bitsPerSample, 8)
        XCTAssertEqual(bitmap.samplesPerPixel, 4)
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples, atX: x, y: y)
        if bitmap.bitmapFormat.contains(.alphaFirst) { return Array(samples.dropFirst()) + [samples[0]] }
        return samples
    }
}
