import AppKit

/// Rasterizes the swept area of an axis-aligned square nib, one bounded row at a time.
/// Visiting only the row span avoids scanning a whole canvas (or a long diagonal's bounding box).
enum SquareTipRasterizer {
    static func center(_ point: CGPoint, size: CGFloat) -> CGPoint {
        // Odd integer nibs straddle a pixel center, even nibs a pixel boundary.
        let shift: CGFloat = Int(max(1, min(128, size.rounded()))) % 2 == 0 ? 0 : 0.5
        return CGPoint(x: point.x + shift, y: point.y + shift)
    }
    static func visit(from start: CGPoint, to end: CGPoint, size: CGFloat, width: Int, height: Int,
                      pixel: (Int) -> Void) {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite, size.isFinite else { return }
        let half = max(1, min(128, size.rounded())) / 2
        let aStart = center(start, size: size), aEnd = center(end, size: size)
        let dx = aEnd.x - aStart.x, dy = aEnd.y - aStart.y
        guard dx.isFinite, dy.isFinite else { return }
        let top = max(0, min(aStart.y, aEnd.y) - half), bottom = min(CGFloat(height), max(aStart.y, aEnd.y) + half)
        guard top < bottom else { return }
        let firstRow = max(0, Int(ceil(top - 0.5))), endRow = min(height, Int(ceil(bottom - 0.5)))
        guard firstRow < endRow else { return }
        for y in firstRow..<endRow {
            let centerY = CGFloat(y) + 0.5
            var low: CGFloat = 0, high: CGFloat = 1
            if abs(dy) > 0.0000001 {
                let a = (centerY - half - aStart.y) / dy, b = (centerY + half - aStart.y) / dy
                low = max(0, min(a, b)); high = min(1, max(a, b))
                if low > high { continue }
            }
            let a = aStart.x + low * dx, b = aStart.x + high * dx
            let left = max(0, min(a, b) - half), right = min(CGFloat(width), max(a, b) + half)
            guard left < right else { continue }
            let firstColumn = max(0, Int(ceil(left - 0.5))), endColumn = min(width, Int(ceil(right - 0.5)))
            guard firstColumn < endColumn else { continue }
            for x in firstColumn..<endColumn { pixel(y * width + x) }
        }
    }

    static func pencil(on bitmap: inout Bitmap, from start: CGPoint, to end: CGPoint, size: CGFloat, color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let alpha = rgb.alphaComponent
        let source: [Int] = [rgb.redComponent * alpha, rgb.greenComponent * alpha, rgb.blueComponent * alpha, alpha]
            .map { Int(max(0, min(255, ($0 * 255).rounded()))) }
        let inverseAlpha = 255 - source[3], width = bitmap.width, height = bitmap.height
        bitmap.pixels.withUnsafeMutableBufferPointer { target in
            visit(from: start, to: end, size: size, width: width, height: height) { pixel in
                let offset = pixel * 4
                for c in 0..<4 { target[offset + c] = UInt8(min(255, source[c] + (Int(target[offset + c]) * inverseAlpha + 127) / 255)) }
            }
        }
    }
}

/// The marker is one multiply layer per mouse-down/up gesture. A coverage union makes
/// repeated samples and self-crossings idempotent; a separate stroke may deepen the mark.
final class HighlighterStroke {
    private let original: Bitmap
    private let size: CGFloat
    private let alpha: Double
    private let color: [Double]
    private var coverage: [UInt8]

    init(original: Bitmap, size: CGFloat, color: NSColor, opacity: CGFloat) {
        self.original = original
        self.size = size
        let rgb = color.usingColorSpace(.sRGB) ?? .yellow
        let opacity = opacity.isFinite ? max(0, min(1, opacity)) : 0.35
        alpha = Double(opacity * rgb.alphaComponent)
        self.color = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        coverage = [UInt8](repeating: 0, count: original.width * original.height)
    }

    func draw(on bitmap: inout Bitmap, from start: CGPoint, to end: CGPoint) {
        guard alpha > 0 else { return }
        let width = original.width, height = original.height
        original.pixels.withUnsafeBufferPointer { base in
            bitmap.pixels.withUnsafeMutableBufferPointer { target in
                coverage.withUnsafeMutableBufferPointer { mask in
                    SquareTipRasterizer.visit(from: start, to: end, size: size, width: width, height: height) { pixel in
                        guard mask[pixel] == 0 else { return }
                        mask[pixel] = 255
                        let offset = pixel * 4
                        let baseAlpha = Double(base[offset + 3]) / 255
                        let resultAlpha = alpha + baseAlpha * (1 - alpha)
                        for c in 0..<3 {
                            let premultipliedBase = Double(base[offset + c]) / 255
                            // Multiply with correct source-over alpha, including a transparent backdrop.
                            let result = premultipliedBase * (1 - alpha + alpha * color[c])
                                + alpha * color[c] * (1 - baseAlpha)
                            target[offset + c] = UInt8(max(0, min(255, (result * 255).rounded())))
                        }
                        target[offset + 3] = UInt8(max(0, min(255, (resultAlpha * 255).rounded())))
                    }
                }
            }
        }
    }
}
