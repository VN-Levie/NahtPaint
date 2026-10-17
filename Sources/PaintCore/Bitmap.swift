import AppKit
import CoreGraphics

public enum PaintError: LocalizedError {
    case invalidSize, unreadableImage, encodingFailed, clipboardUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidSize: return L10n.tr("Use dimensions from 1–8192 pixels, with no more than 24 million pixels.")
        case .unreadableImage: return L10n.tr("This image could not be opened.")
        case .encodingFailed: return L10n.tr("The image could not be encoded.")
        case .clipboardUnavailable: return L10n.tr("The clipboard could not be updated. Try again.")
        }
    }
}

/// RGBA, premultiplied, with row zero at the top of the image.
struct Bitmap {
    var width: Int
    var height: Int
    var pixels: [UInt8]
    static func validate(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 24_000_000 else { throw PaintError.invalidSize }
    }
    init(width: Int, height: Int, white: Bool = true) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: white ? 255 : 0, count: width * height * 4)
    }
    init(image: NSImage) throws {
        // NSImage.size is in points. Prefer the representation's real pixel dimensions.
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let cg: CGImage?
        if let best = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            cg = best.cgImage
        } else {
            var bounds = CGRect(origin: .zero, size: image.size)
            cg = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)
        }
        guard let cg else { throw PaintError.unreadableImage }
        try Self.validate(cg.width, cg.height)
        self.init(width: cg.width, height: cg.height, white: false)
        let imageBounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        withContext(flipped: false) { context in
            context.setBlendMode(.copy)
            context.draw(cg, in: imageBounds)
        }
    }
    mutating func withContext(flipped: Bool = true, _ body: (CGContext) -> Void) {
        let w = width, h = height
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            if flipped {
                context.translateBy(x: 0, y: CGFloat(h))
                context.scaleBy(x: 1, y: -1)
            }
            body(context)
        }
    }
    func cgImage() -> CGImage {
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    func nsImage() -> NSImage { NSImage(cgImage: cgImage(), size: NSSize(width: width, height: height)) }
    func encoded(_ format: NSBitmapImageRep.FileType) throws -> Data {
        let image: Bitmap
        if format == .jpeg {
            var opaque = Bitmap(width: width, height: height)
            opaque.composite(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = opaque
        } else { image = self }
        let rep = NSBitmapImageRep(cgImage: image.cgImage())
        guard let data = rep.representation(using: format, properties: format == .jpeg ? [.compressionFactor: 0.92] : [:]) else {
            throw PaintError.encodingFailed
        }
        return data
    }
    func crop(_ rect: CGRect) -> Bitmap {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard r.width > 0, r.height > 0 else { return Bitmap(width: 1, height: 1, white: false) }
        var result = Bitmap(width: Int(r.width), height: Int(r.height), white: false)
        for y in 0..<result.height {
            let src = ((Int(r.minY) + y) * width + Int(r.minX)) * 4
            let dst = y * result.width * 4
            result.pixels.replaceSubrange(dst..<(dst + result.width * 4), with: pixels[src..<(src + result.width * 4)])
        }
        return result
    }
    mutating func clear(_ rect: CGRect) {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard r.width > 0, r.height > 0 else { return }
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let i = (y * width + x) * 4
                pixels[i] = 255; pixels[i+1] = 255; pixels[i+2] = 255; pixels[i+3] = 255
            }
        }
    }
    /// Pixel-copy / source-over compositing also avoids NSImage point-size and flipped-coordinate ambiguity.
    mutating func composite(_ source: Bitmap, in rect: CGRect, flippedHorizontally: Bool = false,
                            flippedVertically: Bool = false, replacing: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        let minX = max(0, Int(floor(rect.minX))), minY = max(0, Int(floor(rect.minY)))
        let maxX = min(width, Int(ceil(rect.maxX))), maxY = min(height, Int(ceil(rect.maxY)))
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            let destinationY = CGFloat(y) - rect.minY
            let sampleY = flippedVertically ? rect.height - 1 - destinationY : destinationY
            let sy = min(source.height - 1, max(0, Int(sampleY * CGFloat(source.height) / rect.height)))
            for x in minX..<maxX {
                // Reflect destination pixels before resampling. Reversing source indices would
                // assign repeated pixels to the wrong side when the scale is not an integer.
                let destinationX = CGFloat(x) - rect.minX
                let sampleX = flippedHorizontally ? rect.width - 1 - destinationX : destinationX
                let sx = min(source.width - 1, max(0, Int(sampleX * CGFloat(source.width) / rect.width)))
                let si = (sy * source.width + sx) * 4, di = (y * width + x) * 4
                if replacing {
                    for c in 0..<4 { pixels[di+c] = source.pixels[si+c] }
                    continue
                }
                let a = Int(source.pixels[si+3]), inv = 255 - a
                for c in 0..<4 { pixels[di+c] = UInt8(min(255, Int(source.pixels[si+c]) + (Int(pixels[di+c]) * inv + 127) / 255)) }
            }
        }
    }
    func resized(width: Int, height: Int, flippedHorizontally: Bool = false, flippedVertically: Bool = false) -> Bitmap {
        var result = Bitmap(width: width, height: height, white: false)
        result.composite(self, in: CGRect(x: 0, y: 0, width: width, height: height),
                         flippedHorizontally: flippedHorizontally, flippedVertically: flippedVertically)
        return result
    }
    func color(at point: CGPoint) -> NSColor? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4, a = CGFloat(pixels[i+3]) / 255
        guard a > 0 else { return .clear }
        return NSColor(srgbRed: CGFloat(pixels[i]) / 255 / a, green: CGFloat(pixels[i+1]) / 255 / a,
            blue: CGFloat(pixels[i+2]) / 255 / a, alpha: a)
    }
}
