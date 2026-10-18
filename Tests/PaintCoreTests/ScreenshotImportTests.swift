import AppKit
import Darwin
import ImageIO
import XCTest
@testable import PaintCore

final class ScreenshotImportTests: XCTestCase {
    func testRetinaClipboardScreenshotNormalizesBeforePasteAndCopy() async throws {
        try await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            let copied = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally(); copied.releaseGlobally() }
            try Self.write(Self.image(width: 120, height: 80, scale: 2), to: board, screenshot: true)
            let engine = PaintEngine(width: 12, height: 8)
            engine.paste(from: board)
            XCTAssertEqual(engine.width, 60)
            XCTAssertEqual(engine.height, 40)
            engine.selectAll()
            try engine.copy(to: copied)
            let data = try XCTUnwrap(copied.data(forType: .png))
            let output = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(output.pixelsWide, 60)
            XCTAssertEqual(output.pixelsHigh, 40)

            let roundTrip = PaintEngine(width: 12, height: 8)
            roundTrip.paste(from: copied)
            XCTAssertEqual(roundTrip.width, 60, "Copy/paste must not shrink an already optimized screenshot again")
            XCTAssertEqual(roundTrip.height, 40)
        }
    }

    func testDisabledOptimizationKeepsScreenshotPixels() async throws {
        try await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try Self.write(Self.image(width: 120, height: 80, scale: 2), to: board, screenshot: true)
            let engine = PaintEngine(width: 12, height: 8)
            engine.optimizeScreenshots = false
            engine.paste(from: board)
            XCTAssertEqual(engine.width, 120)
            XCTAssertEqual(engine.height, 80)
        }
    }

    func testOrdinaryHighDensityClipboardImageIsUnchanged() async throws {
        try await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try Self.write(Self.image(width: 120, height: 80, scale: 2), to: board, screenshot: false)
            let image = try XCTUnwrap(ImageImport.image(from: board, optimizeScreenshots: true))
            XCTAssertEqual(try Bitmap(image: image).width, 120)
            XCTAssertEqual(try Bitmap(image: image).height, 80)
        }
    }

    func testNativeClipboardMarkerPreventsOptimization() async throws {
        try await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try Self.write(Self.image(width: 120, height: 80, scale: 2), to: board, screenshot: true)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("com.nathpaint.editable-text.v1"))
            let image = try XCTUnwrap(ImageImport.image(from: board, optimizeScreenshots: true))
            XCTAssertEqual(try Bitmap(image: image).width, 120)
        }
    }

    func testRenamedScreenshotFileUsesMetadataAndDropFileURL() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("renamed.png")
            try Self.writePNG(Self.image(width: 120, height: 80, scale: 2), to: url, dpi: 144)
            let flag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            let result = flag.withUnsafeBytes { bytes in
                setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, flag.count, 0, 0)
            }
            XCTAssertEqual(result, 0)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(board.writeObjects([url as NSURL]))
            let image = try XCTUnwrap(ImageImport.image(from: board, optimizeScreenshots: true))
            XCTAssertEqual(try Bitmap(image: image).width, 60)
            XCTAssertEqual(try Bitmap(image: image).height, 40)
            let original = try XCTUnwrap(ImageImport.image(from: board, optimizeScreenshots: false))
            XCTAssertEqual(try Bitmap(image: original).width, 120)
        }
    }

    func testScreenshotFilenameNeedsRetinaDensityAndSupportsVietnamese() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let vietnamese = "Ảnh chụp Màn hình 2026-10-18 lúc 10.30.00.png"
            for name in ["Screenshot 2026-10-18 at 10.30.00.png", vietnamese, vietnamese.decomposedStringWithCanonicalMapping] {
                let url = directory.appendingPathComponent(name)
                try Self.writePNG(Self.image(width: 120, height: 90, scale: 3), to: url, dpi: 216)
                let image = try XCTUnwrap(NSImage(contentsOf: url))
                XCTAssertEqual(try Bitmap(image: ImageImport.prepared(image, sourceURL: url)).width, 40, name)
                try Self.writePNG(Self.image(width: 120, height: 90, scale: 1), to: url, dpi: 72)
                let standard = try XCTUnwrap(NSImage(contentsOf: url))
                XCTAssertEqual(try Bitmap(image: ImageImport.prepared(standard, sourceURL: url)).width, 120, name)
            }
            let photoURL = directory.appendingPathComponent("photo.png")
            try Self.writePNG(Self.image(width: 120, height: 80, scale: 2), to: photoURL, dpi: 144)
            let photo = try XCTUnwrap(NSImage(contentsOf: photoURL))
            XCTAssertEqual(try Bitmap(image: ImageImport.prepared(photo, sourceURL: photoURL)).width, 120)
        }
    }

    func testUnknownDensityDoesNotGuessOrUpscale() async throws {
        try await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setData(Data(), forType: NSPasteboard.PasteboardType("com.apple.screencapture.mditem"))
            for scale: CGFloat in [0.5, 1, 1.5, 4, 300 / 72] {
                let image = Self.image(width: 120, height: 80, scale: scale)
                XCTAssertEqual(try Bitmap(image: ImageImport.prepared(image, pasteboard: board)).width, 120)
            }
        }
    }

    func testOptimizationPreservesTransparencyAndSamplesBetweenSourcePixels() async throws {
        try await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setData(Data(), forType: NSPasteboard.PasteboardType("com.apple.screencapture.mditem"))
            let image = Self.image(width: 16, height: 16, scale: 2)
            let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
            for y in 0..<16 {
                for x in 0..<16 {
                    var pixel = [((x + y) % 2 == 0 ? 0 : 255), 0, 0, 128]
                    rep.setPixel(&pixel, atX: x, y: y)
                }
            }
            let result = try Bitmap(image: ImageImport.prepared(image, pasteboard: board))
            XCTAssertEqual(result.width, 8)
            XCTAssertEqual(result.height, 8)
            let color = try XCTUnwrap(result.color(at: CGPoint(x: 4, y: 4)))
            XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.02)
            XCTAssertGreaterThan(color.redComponent, 0.1)
            XCTAssertLessThan(color.redComponent, 0.9)
        }
    }

    private static func image(width: Int, height: Int, scale: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
                                  bytesPerRow: width * 4, bitsPerPixel: 32)!
        memset(rep.bitmapData!, 0, rep.bytesPerRow * height)
        rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ image: NSImage, to board: NSPasteboard, screenshot: Bool) throws {
        XCTAssertTrue(board.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff))
        if screenshot { board.setData(Data(), forType: NSPasteboard.PasteboardType("com.apple.screencapture.mditem")) }
    }

    private static func writePNG(_ image: NSImage, to url: URL, dpi: CGFloat) throws {
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(rep.cgImage),
                                  [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
