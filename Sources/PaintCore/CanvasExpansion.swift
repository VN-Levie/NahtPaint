import Foundation

enum CanvasExpansionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var extendsLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var extendsRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var extendsTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var extendsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    var label: String {
        switch self {
        case .topLeft: return "Expand canvas top left"
        case .top: return "Expand canvas top"
        case .topRight: return "Expand canvas top right"
        case .right: return "Expand canvas right"
        case .bottomRight: return "Expand canvas bottom right"
        case .bottom: return "Expand canvas bottom"
        case .bottomLeft: return "Expand canvas bottom left"
        case .left: return "Expand canvas left"
        }
    }

    func center(outside rect: CGRect) -> CGPoint {
        // Give corners more room so their hit targets remain distinct even at 5% zoom.
        let corner = (extendsLeft || extendsRight) && (extendsTop || extendsBottom)
        let offset: CGFloat = corner ? 22 : max(12, 21 - min(rect.width, rect.height) / 2)
        return CGPoint(x: extendsLeft ? rect.minX - offset : extendsRight ? rect.maxX + offset : rect.midX,
                       y: extendsTop ? rect.minY - offset : extendsBottom ? rect.maxY + offset : rect.midY)
    }
}

/// Blank margin on each side of the artwork, where an inward drag pauses.
struct CanvasContentInsets: Equatable {
    var left = 0, top = 0, right = 0, bottom = 0
    init(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    init(content: CGRect?, width: Int, height: Int) {
        guard let content else { return }
        left = max(0, Int(content.minX)); top = max(0, Int(content.minY))
        right = max(0, width - Int(content.maxX)); bottom = max(0, height - Int(content.maxY))
    }
}

/// Signed edge offsets: positive adds space, negative crops that side.
struct CanvasExpansionPadding: Equatable {
    /// Screen distance an inward drag must travel past a stop before it moves on.
    static let detent: CGFloat = 24

    var left = 0
    var top = 0
    var right = 0
    var bottom = 0
    /// True while an inward drag is paused at the artwork edge.
    var holdingAtContent = false
    var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    var isCropping: Bool { min(left, top, right, bottom) < 0 }

    init(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0, holdingAtContent: Bool = false) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
        self.holdingAtContent = holdingAtContent
    }

    func rect(from original: CGRect, zoom: CGFloat) -> CGRect {
        CGRect(x: original.minX - CGFloat(left) * zoom, y: original.minY - CGFloat(top) * zoom,
               width: original.width + CGFloat(left + right) * zoom,
               height: original.height + CGFloat(top + bottom) * zoom)
    }

    /// Map an outward screen distance to pixels. Inward, the value pauses for `detent` points
    /// where the blank margin ends, so blank space is trimmed exactly and cropping into the
    /// artwork needs a deliberate push past it.
    static func detented(_ screen: CGFloat, zoom: CGFloat, contentInset: Int) -> (pixels: CGFloat, holding: Bool) {
        let pixels = screen / zoom, stop = -CGFloat(contentInset)
        guard contentInset > 0, pixels <= stop else { return (pixels, false) }
        if screen > stop * zoom - detent { return (stop, true) }
        return ((screen + detent) / zoom, false)
    }

    static func dragging(_ handle: CanvasExpansionHandle, translation: CGPoint, zoom: CGFloat,
                         width: Int, height: Int, content: CanvasContentInsets = CanvasContentInsets()) -> Self {
        guard zoom.isFinite, zoom > 0, translation.x.isFinite, translation.y.isFinite,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000 else { return Self() }
        let horizontal = handle.extendsLeft ? -translation.x : handle.extendsRight ? translation.x : 0
        let vertical = handle.extendsTop ? -translation.y : handle.extendsBottom ? translation.y : 0
        let x = (handle.extendsLeft || handle.extendsRight)
            ? detented(horizontal, zoom: zoom, contentInset: handle.extendsLeft ? content.left : content.right) : (pixels: 0, holding: false)
        let y = (handle.extendsTop || handle.extendsBottom)
            ? detented(vertical, zoom: zoom, contentInset: handle.extendsTop ? content.top : content.bottom) : (pixels: 0, holding: false)
        // Keep at least one pixel; never exceed the dimension limit.
        let deltaWidth = Int(max(CGFloat(1 - width), min(CGFloat(8192 - width), x.pixels.rounded())))
        let deltaHeight = Int(max(CGFloat(1 - height), min(CGFloat(8192 - height), y.pixels.rounded())))
        var addedWidth = deltaWidth, addedHeight = deltaHeight
        if (width + deltaWidth) * (height + deltaHeight) > 24_000_000 {
            // Preserve the pointer's direction while stopping at the allocation limit.
            let growWidth = max(0, deltaWidth), growHeight = max(0, deltaHeight)
            func scaled(_ grow: Int, _ delta: Int, _ fraction: Double) -> Int {
                grow > 0 ? Int(floor(Double(grow) * fraction)) : delta
            }
            var lower: Double = 0, upper: Double = 1
            for _ in 0..<40 {
                let fraction = (lower + upper) / 2
                if (width + scaled(growWidth, deltaWidth, fraction)) * (height + scaled(growHeight, deltaHeight, fraction)) <= 24_000_000 {
                    lower = fraction
                } else { upper = fraction }
            }
            addedWidth = scaled(growWidth, deltaWidth, lower)
            addedHeight = scaled(growHeight, deltaHeight, lower)
        }
        let holding = [x.holding, y.holding].compactMap { $0 }
        return Self(left: handle.extendsLeft ? addedWidth : 0, top: handle.extendsTop ? addedHeight : 0,
                    right: handle.extendsRight ? addedWidth : 0, bottom: handle.extendsBottom ? addedHeight : 0,
                    holdingAtContent: x.holding || y.holding)
    }
}
