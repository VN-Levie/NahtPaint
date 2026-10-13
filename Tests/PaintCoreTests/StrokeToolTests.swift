import AppKit
import XCTest
@testable import PaintCore

final class StrokeToolTests: XCTestCase {
    func testOddWidthPencilDotsCoverTheirExactPixelSquareAndCenter() async {
        await MainActor.run {
            for width in [1, 3] {
                let engine = PaintEngine(width: 24, height: 24)
                engine.tool = .pencil
                engine.brushSize = CGFloat(width)
                engine.color = .black
                Self.stroke(engine, points: [CGPoint(x: 12, y: 12)])

                let pixels = engine.bitmap.pixels
                let coloredPixelCount = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 255 }.count
                XCTAssertEqual(coloredPixelCount, width * width, "A width-\(width) pencil dot should fill exactly its pixel square")
                XCTAssertEqual(Self.rgba(engine.bitmap, x: 12, y: 12), [0, 0, 0, 255])
            }
        }
    }

    func testPencilHasSquareHardEdgesWhileBrushIsRoundAndAntialiased() async {
        await MainActor.run {
            let pencil = PaintEngine(width: 32, height: 28)
            pencil.tool = .pencil
            pencil.brushSize = 8
            pencil.color = .black
            Self.stroke(pencil, points: [CGPoint(x: 12, y: 12)])
            let brush = PaintEngine(width: 32, height: 28)
            brush.tool = .brush
            brush.brushSize = 8
            brush.color = .black
            Self.stroke(brush, points: [CGPoint(x: 12, y: 12)])

            XCTAssertEqual(Self.rgba(pencil.bitmap, x: 8, y: 8), [0, 0, 0, 255])
            XCTAssertEqual(Self.rgba(brush.bitmap, x: 8, y: 8), [255, 255, 255, 255])
            XCTAssertEqual(Self.rgba(pencil.bitmap, x: 12, y: 12), [0, 0, 0, 255])
            XCTAssertEqual(Self.rgba(brush.bitmap, x: 12, y: 12), [0, 0, 0, 255])

            pencil.newCanvas(width: 32, height: 28)
            brush.newCanvas(width: 32, height: 28)
            pencil.brushSize = 3
            brush.brushSize = 3
            let diagonal = [CGPoint(x: 5, y: 5), CGPoint(x: 25, y: 19)]
            Self.stroke(pencil, points: diagonal)
            Self.stroke(brush, points: diagonal)
            let pencilValues = stride(from: 0, to: pencil.bitmap.pixels.count, by: 4).map { pencil.bitmap.pixels[$0] }
            let brushValues = stride(from: 0, to: brush.bitmap.pixels.count, by: 4).map { brush.bitmap.pixels[$0] }
            XCTAssertTrue(pencilValues.contains(0))
            XCTAssertTrue(pencilValues.allSatisfy { $0 == 0 || $0 == 255 }, "Pencil coverage should have no antialiased intermediate pixels")
            XCTAssertTrue(brushValues.contains { $0 > 0 && $0 < 255 }, "A diagonal brush stroke should have smooth edge coverage")
        }
    }

    func testToolsRememberIndependentWidthsAndShapesShareTheirOwnWidth() async {
        await MainActor.run {
            let engine = PaintEngine(width: 16, height: 16)
            XCTAssertEqual(engine.tool, .pencil)
            XCTAssertEqual(engine.brushSize, 3)
            engine.brushSize = 5
            engine.tool = .brush
            XCTAssertEqual(engine.brushSize, 10)
            engine.brushSize = 12
            engine.tool = .eraser
            XCTAssertEqual(engine.brushSize, 16)
            engine.brushSize = 20
            engine.tool = .highlighter
            XCTAssertEqual(engine.brushSize, 24)
            engine.brushSize = 28
            engine.tool = .line
            XCTAssertEqual(engine.brushSize, 3)
            engine.brushSize = 4
            engine.tool = .rectangle
            XCTAssertEqual(engine.brushSize, 4)
            engine.brushSize = 6
            engine.tool = .ellipse
            XCTAssertEqual(engine.brushSize, 6)
            engine.brushSize = 7

            engine.tool = .pencil
            XCTAssertEqual(engine.brushSize, 5)
            engine.tool = .brush
            XCTAssertEqual(engine.brushSize, 12)
            engine.tool = .eraser
            XCTAssertEqual(engine.brushSize, 20)
            engine.tool = .highlighter
            XCTAssertEqual(engine.brushSize, 28)
            engine.tool = .line
            XCTAssertEqual(engine.brushSize, 7)
        }
    }

    func testHighlighterTintsWhiteAtConfiguredOpacityAndPreservesBlack() async throws {
        try await MainActor.run {
            var source = Bitmap(width: 48, height: 32)
            for y in 12..<20 {
                for x in 20..<28 {
                    let offset = (y * source.width + x) * 4
                    source.pixels.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 255])
                }
            }
            let engine = Self.highlighter(width: 48, height: 32)
            XCTAssertEqual(engine.highlighterOpacity, 0.35, accuracy: 0.0001)
            try engine.loadImage(source.nsImage())
            Self.stroke(engine, points: [CGPoint(x: 4, y: 16), CGPoint(x: 42, y: 16)])

            let tintedWhite = Self.rgba(engine.bitmap, x: 10, y: 16)
            XCTAssertEqual(tintedWhite[0], 255)
            XCTAssertEqual(tintedWhite[1], 255)
            XCTAssertEqual(Double(tintedWhite[2]), 166, accuracy: 1)
            XCTAssertEqual(tintedWhite[3], 255)
            XCTAssertEqual(Self.rgba(engine.bitmap, x: 24, y: 16), [0, 0, 0, 255])
            XCTAssertEqual(Self.rgba(engine.bitmap, x: 10, y: 4), [255, 255, 255, 255])
        }
    }

    func testHighlighterCoverageIsIndependentOfSamplingDensityAndBacktracking() async {
        await MainActor.run {
            let coarse = Self.highlighter()
            let dense = Self.highlighter()
            let backtracking = Self.highlighter()
            Self.stroke(coarse, points: [CGPoint(x: 8, y: 20), CGPoint(x: 48, y: 20)])
            Self.stroke(dense, points: stride(from: 8, through: 48, by: 2).map { CGPoint(x: $0, y: 20) })
            Self.stroke(backtracking, points: [
                CGPoint(x: 8, y: 20), CGPoint(x: 48, y: 20),
                CGPoint(x: 20, y: 20), CGPoint(x: 48, y: 20), CGPoint(x: 8, y: 20)
            ])

            XCTAssertEqual(dense.bitmap.pixels, coarse.bitmap.pixels)
            XCTAssertEqual(backtracking.bitmap.pixels, coarse.bitmap.pixels, "Coverage inside one stroke should be a union, without repeated blending")
        }
    }

    func testSeparateHighlighterStrokesDeepenColorAndUndoRedoIndependently() async {
        await MainActor.run {
            let engine = Self.highlighter()
            let path = [CGPoint(x: 8, y: 20), CGPoint(x: 48, y: 20)]
            Self.stroke(engine, points: path)
            let first = engine.bitmap.pixels
            let firstBlue = Self.rgba(engine.bitmap, x: 20, y: 20)[2]
            Self.stroke(engine, points: path)
            let second = engine.bitmap.pixels
            let secondBlue = Self.rgba(engine.bitmap, x: 20, y: 20)[2]

            XCTAssertLessThan(secondBlue, firstBlue)
            XCTAssertEqual(Double(firstBlue), 166, accuracy: 1)
            XCTAssertEqual(Double(secondBlue), 108, accuracy: 2)
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, first)
            engine.redo()
            XCTAssertEqual(engine.bitmap.pixels, second)
        }
    }

    func testHighlighterOverTransparencyPreservesPremultiplicationAndPNGColor() async throws {
        try await MainActor.run {
            let engine = Self.highlighter(width: 32, height: 32)
            try engine.loadImage(Bitmap(width: 32, height: 32, white: false).nsImage())
            Self.stroke(engine, points: [CGPoint(x: 8, y: 16), CGPoint(x: 24, y: 16)])

            let stored = Self.rgba(engine.bitmap, x: 16, y: 16)
            XCTAssertEqual(Double(stored[3]), 89, accuracy: 1)
            XCTAssertEqual(Double(stored[0]), Double(stored[3]), accuracy: 1)
            XCTAssertEqual(Double(stored[1]), Double(stored[3]), accuracy: 1)
            XCTAssertEqual(stored[2], 0)
            let exported = try Self.straightRGBA(engine.exportPNG(), x: 16, y: 16)
            XCTAssertEqual(Double(exported[0]), 255, accuracy: 1)
            XCTAssertEqual(Double(exported[1]), 255, accuracy: 1)
            XCTAssertEqual(exported[2], 0)
            XCTAssertEqual(Double(exported[3]), 89, accuracy: 1)
            XCTAssertEqual(try Self.straightRGBA(engine.exportPNG(), x: 0, y: 0)[3], 0)
        }
    }

    func testHighlightingKeepsForegroundTextEditableAndUndoOnlyRemovesStroke() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let engine = Self.highlighter(width: 160, height: 64)
            engine.fontSize = 18
            engine.insertText("Keep editable", at: CGPoint(x: 8, y: 6), width: 140)
            let original = try XCTUnwrap(engine.textObjects.first)
            let rasterBefore = engine.bitmap.pixels
            engine.tool = .highlighter
            Self.stroke(engine, points: [CGPoint(x: 4, y: 20), CGPoint(x: 140, y: 20)])

            XCTAssertNotEqual(engine.bitmap.pixels, rasterBefore)
            XCTAssertEqual(engine.textObjects.map(\.id), [original.id])
            XCTAssertEqual(engine.textObjects.first?.text, original.text)
            XCTAssertEqual(engine.textObjects.first?.style, original.style)
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, rasterBefore)
            XCTAssertEqual(engine.textObjects.map(\.id), [original.id])
            XCTAssertNotNil(engine.beginTextEditing(id: original.id))
            engine.cancelTextEditing()
        }
    }

    func testFinishEditingAndToolChangeFinalizePendingStrokesOnlyOnce() async {
        await MainActor.run {
            let engine = Self.highlighter(width: 48, height: 40)
            let blank = engine.bitmap.pixels
            engine.beginStroke(at: CGPoint(x: 4, y: 8))
            engine.continueStroke(to: CGPoint(x: 20, y: 8))
            engine.finishEditing()
            let first = engine.bitmap.pixels
            engine.endStroke()
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, blank)
            engine.redo()
            XCTAssertEqual(engine.bitmap.pixels, first)

            engine.tool = .brush
            engine.brushSize = 6
            engine.color = .black
            engine.beginStroke(at: CGPoint(x: 4, y: 28))
            engine.continueStroke(to: CGPoint(x: 20, y: 28))
            engine.tool = .pencil
            let second = engine.bitmap.pixels
            engine.continueStroke(to: CGPoint(x: 40, y: 28))
            engine.endStroke()
            XCTAssertEqual(engine.bitmap.pixels, second, "A late drag event must not continue a stroke after switching tools")
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, first)
            engine.undo()
            XCTAssertEqual(engine.bitmap.pixels, blank, "Each completed stroke should contribute exactly one history entry")
        }
    }

    func testWriteStrokeComparisonFixturesWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NATHPAINT_STROKE_FIXTURES"] else { return }
        guard (directory as NSString).isAbsolutePath else {
            XCTFail("NATHPAINT_STROKE_FIXTURES must be an absolute output directory")
            return
        }
        try await MainActor.run {
            _ = NSApplication.shared
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let background = PaintEngine(width: 420, height: 220)
            background.fontSize = 24
            background.textColor = .black
            background.insertText("Same path, same width\nBlack text stays readable", at: CGPoint(x: 24, y: 56), width: 372)
            background.tool = .line
            background.color = .black
            background.brushSize = 2
            Self.stroke(background, points: [CGPoint(x: 24, y: 155), CGPoint(x: 396, y: 155)])
            let rasterBackground = background.canvasImage()
            let path = [
                CGPoint(x: 44, y: 28), CGPoint(x: 145, y: 92),
                CGPoint(x: 50, y: 137), CGPoint(x: 215, y: 80),
                CGPoint(x: 356, y: 166), CGPoint(x: 374, y: 116)
            ]
            let options: [(String, PaintTool)] = [("pencil", .pencil), ("brush", .brush), ("highlighter", .highlighter)]
            for (name, tool) in options {
                let engine = PaintEngine(width: 420, height: 220)
                try engine.loadImage(rasterBackground)
                engine.tool = tool
                engine.brushSize = 12
                engine.color = NSColor(srgbRed: 0.1, green: 0.35, blue: 0.85, alpha: 1)
                engine.highlighterColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
                engine.highlighterOpacity = 0.35
                Self.stroke(engine, points: path)
                try engine.exportPNG().write(to: output.appendingPathComponent("\(name).png"))
            }
        }
    }

    @MainActor private static func highlighter(width: Int = 64, height: Int = 40) -> PaintEngine {
        let engine = PaintEngine(width: width, height: height)
        engine.tool = .highlighter
        engine.highlighterColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        engine.brushSize = 8
        return engine
    }

    @MainActor private static func stroke(_ engine: PaintEngine, points: [CGPoint]) {
        guard let first = points.first else { return }
        engine.beginStroke(at: first)
        for point in points.dropFirst() { engine.continueStroke(to: point) }
        engine.endStroke()
    }

    private static func rgba(_ bitmap: Bitmap, x: Int, y: Int) -> [Int] {
        let offset = (y * bitmap.width + x) * 4
        return bitmap.pixels[offset..<(offset + 4)].map(Int.init)
    }

    private static func straightRGBA(_ data: Data, x: Int, y: Int) throws -> [Int] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples, atX: x, y: y)
        let maximum = Double((1 << bitmap.bitsPerSample) - 1)
        let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : samples.count - 1
        let alpha = bitmap.hasAlpha ? Double(samples[alphaIndex]) / maximum : 1
        let colors = samples.enumerated().compactMap { index, value in
            bitmap.hasAlpha && index == alphaIndex ? nil : Double(value) / maximum
        }
        XCTAssertEqual(colors.count, 3)
        let premultiplied = bitmap.hasAlpha && !bitmap.bitmapFormat.contains(.alphaNonpremultiplied)
        return colors.map { channel in
            let straight = premultiplied && alpha > 0 ? channel / alpha : channel
            return Int((min(1, max(0, straight)) * 255).rounded())
        } + [Int((alpha * 255).rounded())]
    }
}
