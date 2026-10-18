import AppKit
import Darwin
import ImageIO

/// Normalizes identifiable Retina screenshots at import, before canvas placement or resizing.
public enum ImageImport {
    public static func image(from pasteboard: NSPasteboard, optimizeScreenshots: Bool) -> NSImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url), image.isValid {
            return prepared(image, sourceURL: url, pasteboard: pasteboard, optimizeScreenshots: optimizeScreenshots)
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return prepared(image, pasteboard: pasteboard, optimizeScreenshots: optimizeScreenshots)
    }

    /// The switch affects incoming screenshots only. Ordinary images and app clipboard round trips retain their pixels.
    public static func prepared(_ image: NSImage, sourceURL: URL? = nil, pasteboard: NSPasteboard? = nil,
                                optimizeScreenshots: Bool = true) -> NSImage {
        guard optimizeScreenshots else { return image }
        let pasteboardTypes = pasteboard?.types?.map(\.rawValue) ?? []
        guard !pasteboardTypes.contains(where: { $0.hasPrefix("com.nathpaint.") }) else { return image }
        // This metadata type is emitted by macOS Screenshot, including clipboard captures.
        let fromScreenshotClipboard = pasteboardTypes.contains("com.apple.screencapture.mditem")
        let fromScreenshotFile = sourceURL.map { hasScreenshotMetadata($0) || hasScreenshotFilename($0) } ?? false
        guard fromScreenshotClipboard || fromScreenshotFile else { return image }

        let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let representation = representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        var bounds = CGRect(origin: .zero, size: image.size)
        guard let cgImage = representation?.cgImage ?? image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return image }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        var scale: CGFloat?
        if let sourceURL, let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpiWidth = properties[kCGImagePropertyDPIWidth] as? NSNumber,
           let dpiHeight = properties[kCGImagePropertyDPIHeight] as? NSNumber {
            scale = retinaScale(x: CGFloat(truncating: dpiWidth) / 72, y: CGFloat(truncating: dpiHeight) / 72)
        }
        if scale == nil, let representation {
            scale = retinaScale(pixels: pixelSize, points: representation.size)
        }
        if scale == nil { scale = retinaScale(pixels: pixelSize, points: image.size) }
        guard let scale else { return image }
        let width = max(1, Int((pixelSize.width / scale).rounded()))
        let height = max(1, Int((pixelSize.height / scale).rounded()))
        guard width < cgImage.width, height < cgImage.height,
              (try? Bitmap.validate(width, height)) != nil,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { return image }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }

    private static func retinaScale(pixels: CGSize, points: CGSize) -> CGFloat? {
        guard points.width > 0, points.height > 0 else { return nil }
        return retinaScale(x: pixels.width / points.width, y: pixels.height / points.height)
    }

    private static func retinaScale(x: CGFloat, y: CGFloat) -> CGFloat? {
        guard x.isFinite, y.isFinite, abs(x - y) < 0.03 else { return nil }
        let scale = x.rounded()
        // Accept standard Retina density only; arbitrary print DPI is not a screen scale.
        guard (scale == 2 || scale == 3), abs(x - scale) < 0.03 else { return nil }
        return scale
    }

    private static func hasScreenshotFilename(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        return name.range(of: #"^(?:screen\s?shot|ảnh chụp màn hình)[\s_-]+\d{4}[-.]\d{2}[-.]\d{2}(?:[\s_-]|$)"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasScreenshotMetadata(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // Read the screenshot flag directly so newly created files do not depend on Spotlight indexing.
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            let attribute = "com.apple.metadata:kMDItemIsScreenCapture"
            let count = getxattr(path, attribute, nil, 0, 0, 0)
            guard count > 0, count <= 1024 else { return false }
            var data = Data(count: count)
            let readCount = data.withUnsafeMutableBytes { bytes in
                getxattr(path, attribute, bytes.baseAddress, count, 0, 0)
            }
            guard readCount == count,
                  let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return false }
            return (value as? Bool) == true
        }
    }
}
