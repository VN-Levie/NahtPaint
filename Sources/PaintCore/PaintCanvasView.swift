import AppKit
import SwiftUI
import Combine

public struct PaintCanvasView: NSViewRepresentable {
    @ObservedObject private var engine: PaintEngine
    public init(engine: PaintEngine) { self.engine = engine }
    public func makeNSView(context: Context) -> NSScrollView { CanvasScrollView(engine: engine) }
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView as? CanvasScrollView)?.updateCanvas()
    }
}

@MainActor final class CanvasScrollView: NSScrollView {
    let canvas: NativePaintView
    let board: CanvasBoardView
    init(engine: PaintEngine) {
        canvas = NativePaintView(engine: engine)
        board = CanvasBoardView(canvas: canvas)
        super.init(frame: .zero)
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        borderType = .noBorder
        documentView = board
        canvas.wantsLayer = true
        canvas.layer?.shadowColor = NSColor.black.cgColor
        canvas.layer?.shadowOpacity = 0.16
        canvas.layer?.shadowRadius = 5
        canvas.layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityLabel(L10n.tr("Image canvas scroll area"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateCanvas() }
    override func layout() { super.layout(); updateCanvas() }
    override func scrollWheel(with event: NSEvent) {
        // Keep trackpad navigation and an explicit mouse-wheel pan gesture available.
        let trackpadGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard !event.modifierFlags.contains(.shift),
              !trackpadGesture || event.modifierFlags.contains(.command),
              event.scrollingDeltaY != 0,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        // A changed coordinate system mid-drag would move artwork or place a stroke incorrectly.
        guard !board.isExpanding, !canvas.isDraggingCanvasContent else { return }
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        guard delta.isFinite else { return }
        let oldZoom = max(0.05, min(16, canvas.engine.zoom))
        let steps = max(-4, min(4, event.hasPreciseScrollingDeltas ? delta / 100 : delta))
        let newZoom = max(0.05, min(8, oldZoom * pow(1.25, steps)))
        guard abs(newZoom - canvas.engine.zoom) > 0.000001 else { return }

        let imagePoint = canvas.convert(event.locationInWindow, from: nil)
        let pixelPoint = CGPoint(x: imagePoint.x / oldZoom, y: imagePoint.y / oldZoom)
        let clipPoint = contentView.convert(event.locationInWindow, from: nil)
        let viewportOffset = CGPoint(x: clipPoint.x - contentView.bounds.minX,
                                     y: clipPoint.y - contentView.bounds.minY)
        canvas.engine.zoom = newZoom
        updateCanvas()
        let origin = CGPoint(x: canvas.frame.minX + pixelPoint.x * newZoom - viewportOffset.x,
                             y: canvas.frame.minY + pixelPoint.y * newZoom - viewportOffset.y)
        let proposed = CGRect(origin: origin, size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
    func updateCanvas() {
        setAccessibilityLabel(L10n.tr("Image canvas scroll area"))
        setAccessibilityHelp(L10n.tr("Mouse wheel to zoom. Shift-wheel to pan. ⌘-scroll to zoom with a trackpad."))
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        backgroundColor = NSColor(calibratedWhite: dark ? 0.105 : 0.78, alpha: 1)
        if board.isExpanding {
            if board.expansionMatchesDocument { return }
            board.cancelExpansion()
            return
        }
        let zoom = max(0.05, min(16, canvas.engine.zoom))
        let size = CGSize(width: CGFloat(canvas.engine.width) * zoom, height: CGFloat(canvas.engine.height) * zoom)
        let documentSize = CGSize(width: max(contentSize.width, size.width + 72), height: max(contentSize.height, size.height + 72))
        if board.frame.size != documentSize { board.setFrameSize(documentSize) }
        let frame = CGRect(x: max(36, (documentSize.width - size.width) / 2), y: max(36, (documentSize.height - size.height) / 2), width: size.width, height: size.height)
        if canvas.frame != frame { canvas.frame = frame }
        board.updateHandles()
        canvas.needsDisplay = true
        canvas.updateTextAppearance()
    }
}

@MainActor final class CanvasBoardView: NSView {
    let canvas: NativePaintView
    private var preview: CanvasExpansionPreviewView!
    private(set) var handles: [CanvasExpansionHandleView] = []
    private struct ExpansionDrag {
        var handle: CanvasExpansionHandle
        var start: CGPoint
        var originalFrame: CGRect
        var width: Int
        var height: Int
        var zoom: CGFloat
        var renderVersion: Int
        var padding = CanvasExpansionPadding()
    }
    private var expansion: ExpansionDrag?
    var isExpanding: Bool { expansion != nil }
    var expansionMatchesDocument: Bool {
        guard let expansion else { return true }
        return expansion.width == canvas.engine.width && expansion.height == canvas.engine.height
            && expansion.zoom == max(0.05, min(16, canvas.engine.zoom))
            && expansion.renderVersion == canvas.engine.renderVersion
    }
    override var isFlipped: Bool { true }

    init(canvas: NativePaintView) {
        self.canvas = canvas
        super.init(frame: .zero)
        addSubview(canvas)
        preview = CanvasExpansionPreviewView(board: self)
        addSubview(preview)
        handles = CanvasExpansionHandle.allCases.map { CanvasExpansionHandleView(handle: $0, board: self) }
        handles.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateHandles() {
        preview.frame = bounds
        preview.needsDisplay = true
        let rect = expansion.map { $0.padding.rect(from: $0.originalFrame, zoom: $0.zoom) } ?? canvas.frame
        for handle in handles {
            let point = handle.handle.center(outside: rect)
            handle.frame = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
            handle.updateAccessibility()
            handle.needsDisplay = true
            window?.invalidateCursorRects(for: handle)
        }
        needsDisplay = true
    }

    func beginExpansion(_ handle: CanvasExpansionHandle, event: NSEvent) {
        guard let scroll = enclosingScrollView as? CanvasScrollView else { return }
        canvas.engine.finishEditing()
        scroll.updateCanvas()
        let zoom = max(0.05, min(16, canvas.engine.zoom))
        let point = convert(event.locationInWindow, from: nil)
        let frame = canvas.frame
        // Reserve workspace before tracking. Shifting the scroll origin by the same
        // amount keeps the artwork still on screen; its frame is then frozen for the drag.
        let horizontalRoom = CGFloat(8192 - canvas.engine.width) * zoom + 36
        let verticalRoom = CGFloat(8192 - canvas.engine.height) * zoom + 36
        let shift = CGPoint(x: max(0, horizontalRoom - frame.minX), y: max(0, verticalRoom - frame.minY))
        let shiftedFrame = frame.offsetBy(dx: shift.x, dy: shift.y)
        let scrollOrigin = scroll.contentView.bounds.origin
        expansion = ExpansionDrag(handle: handle, start: CGPoint(x: point.x + shift.x, y: point.y + shift.y),
                                  originalFrame: shiftedFrame, width: canvas.engine.width, height: canvas.engine.height,
                                  zoom: zoom, renderVersion: canvas.engine.renderVersion)
        setFrameSize(CGSize(width: max(bounds.width + shift.x, shiftedFrame.maxX + horizontalRoom),
                            height: max(bounds.height + shift.y, shiftedFrame.maxY + verticalRoom)))
        canvas.frame = shiftedFrame
        scroll.contentView.scroll(to: CGPoint(x: scrollOrigin.x + shift.x, y: scrollOrigin.y + shift.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateHandles()
    }

    func dragExpansion(with event: NSEvent) {
        guard var drag = expansion else { return }
        guard expansionMatchesDocument else { cancelExpansion(); return }
        if event.type == .leftMouseDragged { autoscroll(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        drag.padding = .dragging(drag.handle, translation: CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y),
                                 zoom: drag.zoom, width: drag.width, height: drag.height)
        expansion = drag
        updateHandles()
    }

    func endExpansion(with event: NSEvent) {
        guard expansion != nil else { return }
        dragExpansion(with: event)
        guard let drag = expansion else { return }
        finishExpansion(padding: drag.padding)
    }

    func cancelExpansion() {
        guard expansion != nil else { return }
        finishExpansion(padding: CanvasExpansionPadding())
        canvas.engine.report("Canvas expansion cancelled")
    }

    func expandAccessibly(_ handle: CanvasExpansionHandle) -> Bool {
        let direction = CGPoint(x: handle.extendsLeft ? -32 : handle.extendsRight ? 32 : 0,
                                y: handle.extendsTop ? -32 : handle.extendsBottom ? 32 : 0)
        let padding = CanvasExpansionPadding.dragging(handle, translation: direction, zoom: 1,
                                                       width: canvas.engine.width, height: canvas.engine.height)
        guard !padding.isEmpty else { return false }
        finishExpansion(padding: padding)
        return true
    }

    private func finishExpansion(padding: CanvasExpansionPadding) {
        guard let scroll = enclosingScrollView as? CanvasScrollView else { expansion = nil; return }
        let visibleOffset = CGPoint(x: canvas.frame.minX - scroll.contentView.bounds.minX,
                                    y: canvas.frame.minY - scroll.contentView.bounds.minY)
        expansion = nil
        var applied = CanvasExpansionPadding()
        if !padding.isEmpty {
            do {
                try canvas.engine.expandCanvas(left: padding.left, top: padding.top, right: padding.right, bottom: padding.bottom)
                applied = padding
            } catch { canvas.engine.report(error.localizedDescription) }
        }
        scroll.updateCanvas()
        let zoom = max(0.05, min(16, canvas.engine.zoom))
        let origin = CGPoint(x: canvas.frame.minX + CGFloat(applied.left) * zoom - visibleOffset.x,
                             y: canvas.frame.minY + CGFloat(applied.top) * zoom - visibleOffset.y)
        let proposed = CGRect(origin: origin, size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        window?.makeFirstResponder(canvas)
        needsDisplay = true
    }

    fileprivate func drawExpansionPreview() {
        guard let drag = expansion else { return }
        let rect = drag.padding.rect(from: drag.originalFrame, zoom: drag.zoom)
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 1.5
        outline.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke(); outline.stroke()
        let label = "\(drag.width + drag.padding.left + drag.padding.right) × \(drag.height + drag.padding.top + drag.padding.bottom) px"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                       .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attributes)
        let visible = visibleRect
        let labelRect = CGRect(x: max(visible.minX + 6, min(rect.midX - size.width / 2 - 7, visible.maxX - size.width - 20)),
                               y: max(visible.minY + 6, min(rect.maxY + 29, visible.maxY - size.height - 16)),
                               width: size.width + 14, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: CGPoint(x: labelRect.minX + 7, y: labelRect.minY + 4), withAttributes: attributes)
    }
}

@MainActor private final class CanvasExpansionPreviewView: NSView {
    private weak var board: CanvasBoardView?
    override var isFlipped: Bool { true }
    init(board: CanvasBoardView) {
        self.board = board
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { board?.drawExpansionPreview() }
}

@MainActor final class CanvasExpansionHandleView: NSView {
    let handle: CanvasExpansionHandle
    private weak var board: CanvasBoardView?
    override var acceptsFirstResponder: Bool { true }
    init(handle: CanvasExpansionHandle, board: CanvasBoardView) {
        self.handle = handle; self.board = board
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateAccessibility() {
        let title = L10n.tr(handle.label)
        setAccessibilityLabel(title)
        setAccessibilityHelp(L10n.tr("Drag outward to add space. Escape cancels."))
        toolTip = title + " · " + L10n.tr("Drag outward to add space. Escape cancels.")
    }
    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        NSColor.controlAccentColor.setFill(); dot.fill()
        NSColor.white.setStroke(); dot.lineWidth = 1.5; dot.stroke()
    }
    private var cursor: NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return Self.diagonalDownCursor
        case .topRight, .bottomLeft: return Self.diagonalUpCursor
        }
    }
    private static let diagonalDownCursor = diagonalCursor(down: true)
    private static let diagonalUpCursor = diagonalCursor(down: false)
    private static func diagonalCursor(down: Bool) -> NSCursor {
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { _ in
            let path = NSBezierPath()
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: down ? 20 - y : y) }
            path.move(to: point(4, 4)); path.line(to: point(16, 16))
            path.move(to: point(4, 10)); path.line(to: point(4, 4)); path.line(to: point(10, 4))
            path.move(to: point(10, 16)); path.line(to: point(16, 16)); path.line(to: point(16, 10))
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func mouseDown(with event: NSEvent) {
        board?.beginExpansion(handle, event: event)
        window?.makeFirstResponder(self)
        cursor.set()
    }
    override func mouseDragged(with event: NSEvent) { cursor.set(); board?.dragExpansion(with: event) }
    override func mouseUp(with event: NSEvent) { board?.endExpansion(with: event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { board?.cancelExpansion(); return }
        if event.keyCode == 36 || event.keyCode == 49 { _ = accessibilityPerformPress(); return }
        super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { board?.expandAccessibly(handle) ?? false }
}

@MainActor final class NativePaintView: NSView, NSTextViewDelegate {
    let engine: PaintEngine
    private var subscription: AnyCancellable?
    private var dragStart = CGPoint.zero
    private var initialSelection = CGRect.zero
    private var marquee: CGRect?
    private var dragging: DragMode = .none
    private var textEditor: CanvasTextView?
    private var editingObjectID: UUID?
    private var textPoint = CGPoint.zero
    private var editorPixelWidth: CGFloat = 0
    private var editorScale = CGSize(width: 1, height: 1)
    private var initialTextPosition = CGPoint.zero
    private var tracking: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private enum DragMode { case none, draw, select, move, moveText, resize(Int) }
    var isDraggingCanvasContent: Bool {
        if case .none = dragging { return false }
        return true
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    private var zoom: CGFloat { max(0.05, min(16, engine.zoom)) }

    init(engine: PaintEngine) {
        self.engine = engine
        super.init(frame: CGRect(x: 0, y: 0, width: engine.width, height: engine.height))
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.tr("Painting canvas"))
        setAccessibilityHelp(L10n.tr("Choose a tool, then draw. Command V pastes an image. Return places a selection. Escape cancels it."))
        engine.finishTextEditing = { [weak self] in self?.finishText(commit: true) }
        engine.beginPastedTextEditing = { [weak self] text in self?.beginPastedText(text) }
        engine.fitViewAfterImagePaste = { [weak self] in self?.fitPastedImageInViewport() }
        subscription = engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func fitPastedImageInViewport() {
        guard let viewport = enclosingScrollView?.contentSize, viewport.width > 0, viewport.height > 0 else { return }
        engine.zoom = max(0.05, min(1, (viewport.width - 72) / CGFloat(engine.width),
                                   (viewport.height - 72) / CGFloat(engine.height)))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(self) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: engine.tool == .text ? .iBeam : engine.tool == .select ? .arrow : .crosshair)
    }
    override func cursorUpdate(with event: NSEvent) {
        (engine.tool == .text ? NSCursor.iBeam : engine.tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hoverPoint = nil; needsDisplay = true }
    private func updateHover(_ event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.white.setFill(); bounds.fill()
        // The checkerboard is only visible where imported artwork is transparent.
        let cell: CGFloat = 10
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
        let minX = max(0, Int(dirtyRect.minX / cell)), maxX = Int(ceil(dirtyRect.maxX / cell))
        let minY = max(0, Int(dirtyRect.minY / cell)), maxY = Int(ceil(dirtyRect.maxY / cell))
        if minX < maxX, minY < maxY {
            for y in minY..<maxY { for x in minX..<maxX where (x + y) % 2 == 0 {
                CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
            } }
        }
        NSGraphicsContext.current?.imageInterpolation = zoom >= 2 ? .none : .high
        engine.displayBitmap(excludingTextID: engine.editingTextID).nsImage()
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let rect = marquee ?? engine.selectionRect, textEditor == nil || engine.selection != nil {
            drawSelection(scaled(rect), handles: marquee == nil && engine.selection != nil)
        }
        drawBrushPreview()
    }
    private func drawBrushPreview() {
        guard let point = hoverPoint, bounds.contains(point), window?.isKeyWindow == true,
              textEditor == nil, [.pencil, .brush, .highlighter, .eraser].contains(engine.tool), case .none = dragging else { return }
        let diameter = engine.effectiveBrushSize * zoom
        let square = engine.tool == .pencil || engine.tool == .highlighter
        let nibCenter = square ? SquareTipRasterizer.center(CGPoint(x: point.x / zoom, y: point.y / zoom), size: engine.effectiveBrushSize) : CGPoint(x: point.x / zoom, y: point.y / zoom)
        let rect = CGRect(x: nibCenter.x * zoom - diameter / 2, y: nibCenter.y * zoom - diameter / 2, width: diameter, height: diameter)
        let outline = square ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
        // Draw only an overlay: the centerline follows the real raster footprint.
        NSColor.white.setStroke(); outline.lineWidth = 3; outline.stroke()
        NSColor.black.setStroke(); outline.lineWidth = 1; outline.stroke()
    }
    private func scaled(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }
    private func drawSelection(_ rect: CGRect, handles: Bool) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        NSColor.white.setStroke(); path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.setStroke(); path.stroke()
        if handles {
            for point in corners(rect) {
                let handle = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
                NSColor.white.setFill(); handle.fill()
                NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: handle).stroke()
            }
        }
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / zoom, y: p.y / zoom)
    }
    override func mouseDown(with event: NSEvent) {
        hoverPoint = nil
        engine.finishEditing()
        window?.makeFirstResponder(self)
        let point = pixelPoint(event)
        dragStart = point
        if engine.tool == .select || engine.tool == .crop {
            // Pixel-selection handles remain available even above a text object.
            if let rect = engine.selection?.rect {
                initialSelection = rect
                if let corner = corners(rect).firstIndex(where: { hypot(($0.x-point.x)*zoom, ($0.y-point.y)*zoom) < 9 }) {
                    dragging = .resize(corner); return
                }
                if rect.contains(point) { dragging = .move; NSCursor.closedHand.set(); return }
            }
        }
        if engine.tool == .text || engine.tool == .select,
           let object = engine.textObject(at: point) {
            if event.clickCount >= 2 {
                beginEditingText(id: object.id)
            } else {
                engine.selectText(id: object.id)
                initialTextPosition = object.position
                engine.beginTextMove()
                dragging = .moveText
            }
            needsDisplay = true
            return
        }
        if engine.tool == .text { engine.commitSelection(); beginText(at: point); return }
        if engine.tool == .select || engine.tool == .crop {
            engine.commitSelection()
            marquee = CGRect(origin: point, size: .zero); dragging = .select; needsDisplay = true
        } else {
            dragging = .draw; engine.beginStroke(at: point)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = pixelPoint(event)
        switch dragging {
        case .none: break
        case .draw: engine.continueStroke(to: point, constrained: event.modifierFlags.contains(.shift))
        case .select:
            let clipped = CGPoint(x: max(0, min(CGFloat(engine.width), point.x)), y: max(0, min(CGFloat(engine.height), point.y)))
            marquee = CGRect(x: min(dragStart.x, clipped.x), y: min(dragStart.y, clipped.y), width: abs(clipped.x-dragStart.x), height: abs(clipped.y-dragStart.y))
            needsDisplay = true
        case .move:
            engine.moveSelection(to: CGPoint(x: initialSelection.minX + point.x-dragStart.x, y: initialSelection.minY + point.y-dragStart.y))
        case .moveText:
            NSCursor.closedHand.set()
            engine.moveSelectedText(to: CGPoint(x: initialTextPosition.x + point.x-dragStart.x,
                                               y: initialTextPosition.y + point.y-dragStart.y))
        case .resize(let corner):
            let fixed = corners(initialSelection)[(corner+2)%4]
            var moving = point
            if event.modifierFlags.contains(.shift) {
                let ratio = initialSelection.width / initialSelection.height
                let dx = moving.x-fixed.x, dy = moving.y-fixed.y
                if abs(dx) / ratio > abs(dy) { moving.y = fixed.y + (dy >= 0 ? 1 : -1) * abs(dx) / ratio }
                else { moving.x = fixed.x + (dx >= 0 ? 1 : -1) * abs(dy) * ratio }
            }
            engine.setSelectionRect(CGRect(x: min(fixed.x, moving.x), y: min(fixed.y, moving.y), width: max(1, abs(fixed.x-moving.x)), height: max(1, abs(fixed.y-moving.y))))
        }
        autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        switch dragging {
        case .draw: engine.endStroke()
        case .moveText: engine.endTextMove()
        case .select:
            if let marquee, marquee.width >= 1, marquee.height >= 1 { engine.select(rect: marquee) }
            marquee = nil; needsDisplay = true
        default: break
        }
        dragging = .none
        updateHover(event)
        window?.invalidateCursorRects(for: self)
    }
    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self, textEditor == nil else { super.keyDown(with: event); return }
        if event.keyCode == 53 { engine.cancelSelection(); return }
        if event.keyCode == 36 || event.keyCode == 76 { engine.confirmSelection(); return }
        if event.keyCode == 51 || event.keyCode == 117 { engine.deleteSelection(); return }
        if let selection = engine.selectionRect, [123,124,125,126].contains(Int(event.keyCode)) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            if engine.selectedTextID != nil { engine.nudgeSelectedText(dx: dx, dy: dy) }
            else { engine.moveSelection(to: CGPoint(x: selection.minX+dx, y: selection.minY+dy)) }
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.uppercased(),
           let tool = PaintTool.allCases.first(where: { $0.shortcut == key }) { engine.setTool(tool); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": engine.copyToClipboard(entireCanvas: event.modifierFlags.contains(.shift))
        case "v": engine.pasteFromClipboard()
        case "x": engine.cutToClipboard()
        case "a": engine.selectAll()
        case "z": event.modifierFlags.contains(.shift) ? engine.redo() : engine.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    private func beginPastedText(_ text: String) {
        let visible = visibleRect.intersection(bounds)
        let region = visible.isNull || visible.isEmpty ? bounds : visible
        let inset = min(16, min(region.width, region.height) / zoom / 4)
        beginText(at: CGPoint(x: region.minX / zoom + inset, y: region.minY / zoom + inset), initialText: text)
    }
    private func beginEditingText(id: UUID) {
        guard let object = engine.beginTextEditing(id: id) else { return }
        beginText(at: object.position, initialText: object.text, object: object)
    }
    private func beginText(at point: CGPoint, initialText: String = "", object: PaintTextObject? = nil) {
        editingObjectID = object?.id
        textPoint = object?.position ?? CGPoint(x: max(0, floor(point.x)), y: max(0, floor(point.y)))
        editorPixelWidth = object?.layoutWidth ?? max(1, min(560, CGFloat(engine.width)-textPoint.x))
        editorScale = CGSize(width: max(0.001, object?.scaleX ?? 1), height: max(0.001, object?.scaleY ?? 1))
        let field = CanvasTextView(frame: CGRect(x: textPoint.x*zoom, y: textPoint.y*zoom,
            width: editorPixelWidth*zoom, height: max(1, min(200*zoom, bounds.height-textPoint.y*zoom))))
        field.isRichText = false; field.importsGraphics = false
        field.isEditable = true; field.isSelectable = true
        // Own the geometry explicitly so resizing the document can scale text
        // independently on each axis without changing its original line wrapping.
        field.isVerticallyResizable = false; field.isHorizontallyResizable = false
        field.minSize = CGSize(width: 1, height: 1)
        field.maxSize = CGSize(width: editorPixelWidth*zoom, height: max(1, bounds.height-textPoint.y*zoom))
        field.autoresizingMask = []
        field.textContainer?.widthTracksTextView = false
        field.textContainer?.heightTracksTextView = false
        field.textContainer?.lineFragmentPadding = 0
        field.textContainerInset = NSSize(width: PaintEngine.textInset*zoom, height: PaintEngine.textInset*zoom)
        field.font = engine.textAttributes(scale: zoom)[.font] as? NSFont
        field.textColor = engine.textColor
        field.typingAttributes = engine.textAttributes(scale: zoom)
        if !initialText.isEmpty {
            field.textStorage?.setAttributedString(NSAttributedString(string: initialText, attributes: engine.textAttributes(scale: zoom)))
        }
        field.drawsBackground = false
        field.insertionPointColor = engine.textColor
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.allowsUndo = true
        field.delegate = self
        field.wantsLayer = true; field.layer?.borderWidth = 1; field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.onFinish = { [weak self] commit in self?.finishText(commit: commit) }
        field.setAccessibilityLabel(L10n.tr("Text on canvas"))
        textEditor = field
        updateTextAppearance()
        addSubview(field); window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (initialText as NSString).length, length: 0))
        engine.report("Type your text · ⌘Return to place · Esc to cancel")
    }
    func updateTextAppearance() {
        setAccessibilityLabel(L10n.tr("Painting canvas"))
        setAccessibilityHelp(L10n.tr("Choose a tool, then draw. Command V pastes an image. Return places a selection. Escape cancels it."))
        guard let field = textEditor else { return }
        field.setAccessibilityLabel(L10n.tr("Text on canvas"))
        if !field.hasMarkedText() {
            let attributes = engine.textAttributes(scale: zoom)
            let font = attributes[.font] as? NSFont
            if field.font != font { field.font = font }
            if field.textColor != engine.textColor { field.textColor = engine.textColor }
            field.typingAttributes = attributes
        }
        field.insertionPointColor = engine.textColor
        field.textContainerInset = NSSize(width: PaintEngine.textInset*zoom, height: PaintEngine.textInset*zoom)
        field.previewTextColor = engine.textColor
        field.previewBorder = engine.textBorder
        field.previewBackground = engine.textBackgroundEnabled ? engine.textBackgroundColor : nil
        field.previewScale = zoom
        updateTextGeometry(field)
        field.needsDisplay = true
    }
    private func updateTextGeometry(_ field: CanvasTextView) {
        let width = editorPixelWidth * zoom
        let inset = PaintEngine.textInset * zoom
        field.textContainer?.containerSize = CGSize(width: max(1, width - inset * 2), height: .greatestFiniteMagnitude)
        let contentHeight: CGFloat
        if let layout = field.layoutManager, let container = field.textContainer {
            layout.ensureLayout(for: container)
            let usedHeight = layout.usedRect(for: container).maxY
            // Include the caret line after a trailing newline as well as glyphs.
            let caretHeight = layout.extraLineFragmentRect.maxY
            contentHeight = max(usedHeight, caretHeight) + inset * 2
        } else { contentHeight = 40 * zoom }
        let availableHeight = max(1, (CGFloat(engine.height) - textPoint.y) / editorScale.height) * zoom
        let minimumHeight = max(1, (field.font?.ascender ?? 24 * zoom) - (field.font?.descender ?? 0) + inset * 2)
        let naturalSize = CGSize(width: width, height: min(availableHeight, max(minimumHeight, ceil(contentHeight / zoom) * zoom)))
        field.maxSize = CGSize(width: width, height: availableHeight)
        field.frame = CGRect(x: textPoint.x * zoom, y: textPoint.y * zoom,
                             width: naturalSize.width * editorScale.width, height: naturalSize.height * editorScale.height)
        field.bounds = CGRect(origin: .zero, size: naturalSize)
    }
    func textDidChange(_ notification: Notification) {
        guard let field = textEditor else { return }
        updateTextGeometry(field)
        field.needsDisplay = true
    }
    private func finishText(commit: Bool) {
        guard let field = textEditor else { return }
        let string = field.string
        let objectID = editingObjectID
        textEditor = nil
        editingObjectID = nil
        let wasEditing = window?.firstResponder === field
        if wasEditing { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        if commit {
            if let objectID { engine.updateText(id: objectID, text: string, layoutWidth: editorPixelWidth) }
            else { engine.insertText(string, at: textPoint, width: editorPixelWidth) }
        } else {
            engine.cancelTextEditing()
            engine.report("Text cancelled")
        }
        needsDisplay = true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let image = ImageImport.image(from: board, optimizeScreenshots: engine.optimizeScreenshots)
        guard let image else { engine.report("Drop an image file here"); return false }
        do {
            try engine.pasteImage(image)
            window?.makeFirstResponder(self)
            return true
        } catch { engine.report(error.localizedDescription); return false }
    }
}

@MainActor private final class CanvasTextView: NSTextView {
    var onFinish: ((Bool) -> Void)?
    var previewTextColor = NSColor.black
    var previewBorder = false
    var previewBackground: NSColor?
    var previewScale: CGFloat = 1
    override func draw(_ dirtyRect: NSRect) {
        if !string.isEmpty, let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let box = CGRect(x: 0, y: 0, width: min(bounds.width, ceil(used.maxX / previewScale) * previewScale + textContainerInset.width * 2),
                             height: min(bounds.height, ceil(used.maxY / previewScale) * previewScale + textContainerInset.height * 2))
            if let previewBackground { previewBackground.setFill(); box.fill() }
            if previewBorder {
                previewTextColor.setStroke()
                let path = NSBezierPath(rect: box.insetBy(dx: previewScale / 2, dy: previewScale / 2))
                path.lineWidth = previewScale; path.stroke()
            }
        }
        super.draw(dirtyRect)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && !hasMarkedText() { onFinish?(false); return }
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) { onFinish?(true); return }
        super.keyDown(with: event)
    }
}
