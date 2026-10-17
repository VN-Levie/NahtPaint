import AppKit

struct PaintTextStyle: Equatable {
    var fontSize: CGFloat
    var color: NSColor
    var border: Bool
    var backgroundEnabled: Bool
    var backgroundColor: NSColor

    func attributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let size = fontSize.isFinite ? max(1, min(512, fontSize)) : 24
        return [.font: NSFont.systemFont(ofSize: size * scale), .foregroundColor: color, .paragraphStyle: paragraph]
    }
}

/// Text stays a value object. Its cached raster is only a drawing aid, never the document source.
struct PaintTextObject: Identifiable {
    let id: UUID
    var text: String
    var position: CGPoint
    var layoutWidth: CGFloat
    var style: PaintTextStyle
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var flippedHorizontally = false
    var flippedVertically = false
    var raster: Bitmap
    /// An optional crop in the object's natural, unscaled coordinates.
    var clipRect: CGRect?

    var localBounds: CGRect {
        let full = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        return clipRect.map { full.intersection($0) } ?? full
    }
    var bounds: CGRect {
        let local = displayedLocalBounds
        guard !local.isNull else { return .null }
        return CGRect(x: position.x + local.minX * scaleX, y: position.y + local.minY * scaleY,
                      width: local.width * scaleX, height: local.height * scaleY)
    }
    private var displayedLocalBounds: CGRect {
        let local = localBounds
        guard !local.isNull else { return .null }
        return CGRect(x: flippedHorizontally ? CGFloat(raster.width) - local.maxX : local.minX,
                      y: flippedVertically ? CGFloat(raster.height) - local.maxY : local.minY,
                      width: local.width, height: local.height)
    }
    func flipped(in rect: CGRect, horizontally: Bool, vertically: Bool) -> PaintTextObject {
        var result = self
        if horizontally {
            result.position.x = rect.minX + rect.maxX - position.x - CGFloat(raster.width) * scaleX
            result.flippedHorizontally.toggle()
        }
        if vertically {
            result.position.y = rect.minY + rect.maxY - position.y - CGFloat(raster.height) * scaleY
            result.flippedVertically.toggle()
        }
        return result
    }
    func transformed(from source: CGRect, to target: CGRect) -> PaintTextObject {
        var result = self
        let sx = target.width / source.width, sy = target.height / source.height
        result.position = CGPoint(x: target.minX + (position.x - source.minX) * sx,
                                  y: target.minY + (position.y - source.minY) * sy)
        result.scaleX *= sx; result.scaleY *= sy
        return result
    }
    func clipped(to rect: CGRect) -> PaintTextObject? {
        let visible = bounds.intersection(rect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        var result = self
        let displayedCrop = CGRect(x: (visible.minX - position.x) / scaleX, y: (visible.minY - position.y) / scaleY,
                                   width: visible.width / scaleX, height: visible.height / scaleY)
        let localCrop = CGRect(x: flippedHorizontally ? CGFloat(raster.width) - displayedCrop.maxX : displayedCrop.minX,
                               y: flippedVertically ? CGFloat(raster.height) - displayedCrop.maxY : displayedCrop.minY,
                               width: displayedCrop.width, height: displayedCrop.height)
        if visible != bounds { result.clipRect = localBounds.intersection(localCrop) }
        result.position.x -= rect.minX; result.position.y -= rect.minY
        return result
    }
    func draw(on bitmap: inout Bitmap, offset: CGPoint = .zero) {
        let local = localBounds
        let visible = bounds.offsetBy(dx: -offset.x, dy: -offset.y)
            .intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        // Sample in object coordinates so fractional crops after scaling cannot reveal clipped pixels later.
        for y in max(0, Int(floor(visible.minY)))..<min(bitmap.height, Int(ceil(visible.maxY))) {
            let destinationY = CGFloat(y) + offset.y - position.y
            let sy = flippedVertically ? CGFloat(raster.height) - (destinationY + 1) / scaleY : destinationY / scaleY
            guard sy >= local.minY, sy < local.maxY else { continue }
            for x in max(0, Int(floor(visible.minX)))..<min(bitmap.width, Int(ceil(visible.maxX))) {
                let destinationX = CGFloat(x) + offset.x - position.x
                let sx = flippedHorizontally ? CGFloat(raster.width) - (destinationX + 1) / scaleX : destinationX / scaleX
                guard sx >= local.minX, sx < local.maxX else { continue }
                let source = (min(raster.height - 1, max(0, Int(sy))) * raster.width + min(raster.width - 1, max(0, Int(sx)))) * 4
                let target = (y * bitmap.width + x) * 4
                let inverseAlpha = 255 - Int(raster.pixels[source + 3])
                for component in 0..<4 {
                    bitmap.pixels[target + component] = UInt8(min(255, Int(raster.pixels[source + component])
                        + (Int(bitmap.pixels[target + component]) * inverseAlpha + 127) / 255))
                }
            }
        }
    }

    @MainActor static func render(text: String, width: CGFloat, style: PaintTextStyle) throws -> Bitmap {
        let width = max(1, min(8192, width.rounded(.up)))
        let inset = PaintEngine.textInset
        let storage = NSTextStorage(string: text, attributes: style.attributes())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width - inset * 2), height: 8192 - inset * 2))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: max(1, min(width, ceil(used.maxX) + inset * 2)),
                          height: max(1, min(8192, ceil(used.maxY) + inset * 2)))
        try Bitmap.validate(Int(size.width), Int(size.height))
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        let box = CGRect(origin: .zero, size: size)
        NSBezierPath(rect: box).addClip()
        if style.backgroundEnabled { style.backgroundColor.setFill(); box.fill() }
        if style.border {
            style.color.setStroke()
            let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1; border.stroke()
        }
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: CGPoint(x: inset, y: inset))
        image.unlockFocus()
        // Store exactly one raster pixel per document pixel, independent of display density.
        return try Bitmap(image: image).resized(width: Int(size.width), height: Int(size.height))
    }
}

/// Portable metadata accompanies PNG on NahtPaint's clipboard without changing other apps' image paste.
struct PaintTextTransfer: Codable {
    var text: String
    var position: CGPoint
    var layoutWidth: CGFloat
    var fontSize: CGFloat
    var color: [CGFloat]
    var border: Bool
    var backgroundEnabled: Bool
    var backgroundColor: [CGFloat]
    var scaleX: CGFloat
    var scaleY: CGFloat
    var clipRect: CGRect?
    // Optional so clipboard payloads from earlier releases still decode.
    var flippedHorizontally: Bool?
    var flippedVertically: Bool?

    init(_ object: PaintTextObject, offset: CGPoint) {
        text = object.text; position = CGPoint(x: object.position.x - offset.x, y: object.position.y - offset.y)
        layoutWidth = object.layoutWidth; fontSize = object.style.fontSize
        color = Self.components(object.style.color); border = object.style.border
        backgroundEnabled = object.style.backgroundEnabled; backgroundColor = Self.components(object.style.backgroundColor)
        scaleX = object.scaleX; scaleY = object.scaleY; clipRect = object.clipRect
        flippedHorizontally = object.flippedHorizontally; flippedVertically = object.flippedVertically
    }
    private static func components(_ color: NSColor) -> [CGFloat] {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }
    @MainActor func object() throws -> PaintTextObject {
        guard position.x.isFinite, position.y.isFinite, abs(position.x) <= 16384, abs(position.y) <= 16384,
              layoutWidth.isFinite, (1...8192).contains(layoutWidth), fontSize.isFinite, (1...512).contains(fontSize),
              scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0, scaleX <= 8192, scaleY <= 8192,
              color.count == 4, backgroundColor.count == 4,
              (color + backgroundColor).allSatisfy({ $0.isFinite && (0...1).contains($0) }), text.utf8.count <= 1_000_000 else { throw PaintError.unreadableImage }
        if let clipRect {
            guard clipRect.minX.isFinite, clipRect.minY.isFinite, clipRect.width.isFinite, clipRect.height.isFinite,
                  clipRect.width > 0, clipRect.height > 0 else { throw PaintError.unreadableImage }
        }
        let style = PaintTextStyle(fontSize: fontSize,
                                  color: NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3]), border: border,
                                  backgroundEnabled: backgroundEnabled,
                                  backgroundColor: NSColor(srgbRed: backgroundColor[0], green: backgroundColor[1], blue: backgroundColor[2], alpha: backgroundColor[3]))
        let raster = try PaintTextObject.render(text: text, width: layoutWidth, style: style)
        return PaintTextObject(id: UUID(), text: text, position: position, layoutWidth: layoutWidth, style: style,
                               scaleX: scaleX, scaleY: scaleY, flippedHorizontally: flippedHorizontally ?? false,
                               flippedVertically: flippedVertically ?? false, raster: raster, clipRect: clipRect)
    }
}
