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

@MainActor private final class CanvasScrollView: NSScrollView {
    let canvas: NativePaintView
    let board = CanvasBoardView()
    init(engine: PaintEngine) {
        canvas = NativePaintView(engine: engine)
        super.init(frame: .zero)
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        borderType = .noBorder
        documentView = board
        board.addSubview(canvas)
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
    func updateCanvas() {
        setAccessibilityLabel(L10n.tr("Image canvas scroll area"))
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        backgroundColor = NSColor(calibratedWhite: dark ? 0.105 : 0.78, alpha: 1)
        let zoom = max(0.05, min(16, canvas.engine.zoom))
        let size = CGSize(width: CGFloat(canvas.engine.width) * zoom, height: CGFloat(canvas.engine.height) * zoom)
        let documentSize = CGSize(width: max(contentSize.width, size.width + 48), height: max(contentSize.height, size.height + 48))
        if board.frame.size != documentSize { board.setFrameSize(documentSize) }
        let frame = CGRect(x: max(24, (documentSize.width - size.width) / 2), y: max(24, (documentSize.height - size.height) / 2), width: size.width, height: size.height)
        if canvas.frame != frame { canvas.frame = frame }
        canvas.needsDisplay = true
        canvas.updateTextAppearance()
    }
}

private final class CanvasBoardView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class NativePaintView: NSView, NSTextViewDelegate {
    let engine: PaintEngine
    private var subscription: AnyCancellable?
    private var dragStart = CGPoint.zero
    private var initialSelection = CGRect.zero
    private var marquee: CGRect?
    private var dragging: DragMode = .none
    private var textEditor: CanvasTextView?
    private var textPoint = CGPoint.zero
    private var editorPixelWidth: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private enum DragMode { case none, draw, select, move, resize(Int) }
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
        subscription = engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
        if let selected = engine.selection, selected.isCrop || selected.originalRect == selected.rect {
            selected.before.bitmap.nsImage().draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            engine.bitmap.nsImage().draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if let selected = engine.selection {
                selected.image.nsImage().draw(in: scaled(selected.rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let rect = marquee ?? engine.selectionRect { drawSelection(scaled(rect), handles: marquee == nil) }
        drawBrushPreview()
    }
    private func drawBrushPreview() {
        guard let point = hoverPoint, bounds.contains(point), window?.isKeyWindow == true,
              textEditor == nil, [.pencil, .brush, .eraser].contains(engine.tool), case .none = dragging else { return }
        let diameter = engine.effectiveBrushSize * zoom
        let circle = NSBezierPath(ovalIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter))
        // Draw only an overlay: the centerline follows the real raster footprint.
        NSColor.white.setStroke(); circle.lineWidth = 3; circle.stroke()
        NSColor.black.setStroke(); circle.lineWidth = 1; circle.stroke()
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
        if engine.tool == .text { engine.commitSelection(); beginText(at: point); return }
        if engine.tool == .select || engine.tool == .crop {
            if let rect = engine.selectionRect {
                initialSelection = rect
                if let corner = corners(rect).firstIndex(where: { hypot(($0.x-point.x)*zoom, ($0.y-point.y)*zoom) < 9 }) {
                    dragging = .resize(corner); return
                }
                if rect.contains(point) { dragging = .move; NSCursor.closedHand.set(); return }
            }
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
            engine.moveSelection(to: CGPoint(x: selection.minX+dx, y: selection.minY+dy)); return
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
    private func beginText(at point: CGPoint, initialText: String = "") {
        textPoint = CGPoint(x: max(0, floor(point.x)), y: max(0, floor(point.y)))
        editorPixelWidth = max(1, min(560, CGFloat(engine.width)-textPoint.x))
        let field = CanvasTextView(frame: CGRect(x: textPoint.x*zoom, y: textPoint.y*zoom,
            width: editorPixelWidth*zoom, height: max(1, min(200*zoom, bounds.height-textPoint.y*zoom))))
        field.isRichText = false; field.importsGraphics = false
        field.isEditable = true; field.isSelectable = true
        field.isVerticallyResizable = true; field.isHorizontallyResizable = false
        field.minSize = CGSize(width: 1, height: 1)
        field.maxSize = CGSize(width: editorPixelWidth*zoom, height: max(1, bounds.height-textPoint.y*zoom))
        field.autoresizingMask = []
        field.textContainer?.widthTracksTextView = true
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
        field.frame.origin = CGPoint(x: textPoint.x*zoom, y: textPoint.y*zoom)
        field.frame.size.width = editorPixelWidth*zoom
        field.maxSize = CGSize(width: editorPixelWidth*zoom, height: max(1, bounds.height-textPoint.y*zoom))
        field.frame.size.height = min(field.frame.height, field.maxSize.height)
        field.needsDisplay = true
    }
    func textDidChange(_ notification: Notification) { textEditor?.needsDisplay = true }
    private func finishText(commit: Bool) {
        guard let field = textEditor else { return }
        let string = field.string
        textEditor = nil
        let wasEditing = window?.firstResponder === field
        if wasEditing { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        if commit { engine.insertText(string, at: textPoint, width: editorPixelWidth) }
        else { engine.report("Text cancelled") }
        needsDisplay = true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let image: NSImage?
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first { image = NSImage(contentsOf: url) }
        else { image = NSImage(pasteboard: board) }
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
