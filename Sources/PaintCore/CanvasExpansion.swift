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

struct CanvasExpansionPadding: Equatable {
    var left = 0
    var top = 0
    var right = 0
    var bottom = 0
    var isEmpty: Bool { left + top + right + bottom == 0 }

    func rect(from original: CGRect, zoom: CGFloat) -> CGRect {
        CGRect(x: original.minX - CGFloat(left) * zoom, y: original.minY - CGFloat(top) * zoom,
               width: original.width + CGFloat(left + right) * zoom,
               height: original.height + CGFloat(top + bottom) * zoom)
    }

    static func dragging(_ handle: CanvasExpansionHandle, translation: CGPoint, zoom: CGFloat,
                         width: Int, height: Int) -> Self {
        guard zoom.isFinite, zoom > 0, translation.x.isFinite, translation.y.isFinite,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000 else { return Self() }
        let dx = translation.x / zoom, dy = translation.y / zoom
        let horizontal = handle.extendsLeft ? -dx : handle.extendsRight ? dx : 0
        let vertical = handle.extendsTop ? -dy : handle.extendsBottom ? dy : 0
        let extraWidth = Int(max(0, min(CGFloat(8192 - width), horizontal.rounded())))
        let extraHeight = Int(max(0, min(CGFloat(8192 - height), vertical.rounded())))
        var addedWidth = extraWidth, addedHeight = extraHeight
        if (width + extraWidth) * (height + extraHeight) > 24_000_000 {
            // Preserve the pointer's direction while stopping at the allocation limit.
            var lower: Double = 0, upper: Double = 1
            for _ in 0..<40 {
                let fraction = (lower + upper) / 2
                let w = Int(floor(Double(extraWidth) * fraction))
                let h = Int(floor(Double(extraHeight) * fraction))
                if (width + w) * (height + h) <= 24_000_000 { lower = fraction }
                else { upper = fraction }
            }
            addedWidth = Int(floor(Double(extraWidth) * lower))
            addedHeight = Int(floor(Double(extraHeight) * lower))
        }
        return Self(left: handle.extendsLeft ? addedWidth : 0, top: handle.extendsTop ? addedHeight : 0,
                    right: handle.extendsRight ? addedWidth : 0, bottom: handle.extendsBottom ? addedHeight : 0)
    }
}
