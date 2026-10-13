import AppKit
import Combine

public enum PaintTool: String, CaseIterable, Identifiable {
    case select, crop, pencil, brush, eraser, fill, eyedropper, text, line, rectangle, ellipse
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .select: return L10n.tr("Select")
        case .crop: return L10n.tr("Crop")
        case .pencil: return L10n.tr("Pencil")
        case .brush: return L10n.tr("Brush")
        case .eraser: return L10n.tr("Eraser")
        case .fill: return L10n.tr("Fill")
        case .eyedropper: return L10n.tr("Pick color")
        case .text: return L10n.tr("Text")
        case .line: return L10n.tr("Line")
        case .rectangle: return L10n.tr("Rectangle")
        case .ellipse: return L10n.tr("Ellipse")
        }
    }
    public var symbol: String {
        switch self {
        case .select: return "selection.pin.in.out"
        case .crop: return "crop"
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
    public var shortcut: String {
        switch self {
        case .select: return "M"
        case .crop: return "C"
        case .pencil: return "P"
        case .brush: return "B"
        case .eraser: return "E"
        case .fill: return "G"
        case .eyedropper: return "I"
        case .text: return "T"
        case .line: return "L"
        case .rectangle: return "R"
        case .ellipse: return "O"
        }
    }
}

@MainActor public final class PaintEngine: ObservableObject {
    @Published public var tool: PaintTool = .pencil {
        didSet { if oldValue != tool { finishEditing(); commitSelection(); status = tool.title } }
    }
    @Published public var color: NSColor = .black
    @Published public var textColor: NSColor = .black
    @Published public var textBorder = false
    @Published public var textBackgroundEnabled = false
    @Published public var textBackgroundColor: NSColor = .white
    @Published public var brushSize: CGFloat = 3
    @Published public var fontSize: CGFloat = 24
    @Published public var fillShapes = false
    @Published public var zoom: CGFloat = 1
    @Published public private(set) var width: Int
    @Published public private(set) var height: Int
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var isDirty = false
    @Published public private(set) var hasSelection = false
    @Published public private(set) var status = L10n.tr("Ready · Paste an image with ⌘V")
    @Published public private(set) var renderVersion = 0
    public var selectionRect: CGRect? { selection?.rect }

    struct Snapshot {
        var bitmap: Bitmap
        var revision: Int
        var pristine: Bool
    }
    struct Selection {
        var image: Bitmap
        var rect: CGRect
        var originalRect: CGRect?
        var before: Snapshot
        var isCrop = false
    }
    var bitmap: Bitmap
    var selection: Selection?
    var finishTextEditing: (() -> Void)?
    var beginPastedTextEditing: ((String) -> Void)?
    private var finishingText = false
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var revision = 0
    private var nextRevision = 1
    private var savedRevision = 0
    private var pristine = true
    private var strokeBefore: Snapshot?
    private var strokeStart: CGPoint = .zero
    private var lastPoint: CGPoint = .zero

    public init(width: Int = 960, height: Int = 640) {
        let valid = (try? Bitmap.validate(width, height)) != nil
        self.width = valid ? width : 960
        self.height = valid ? height : 640
        bitmap = Bitmap(width: valid ? width : 960, height: valid ? height : 640)
    }
    public func setTool(_ tool: PaintTool) { self.tool = tool }
    public func finishEditing() {
        guard !finishingText else { return }
        finishingText = true
        finishTextEditing?()
        finishingText = false
    }
    private func snapshot() -> Snapshot { Snapshot(bitmap: bitmap, revision: revision, pristine: pristine) }
    private func restore(_ snapshot: Snapshot) {
        bitmap = snapshot.bitmap; revision = snapshot.revision; pristine = snapshot.pristine
        width = bitmap.width; height = bitmap.height
        selection = nil; hasSelection = false
        refresh()
    }
    private func refresh() {
        canUndo = !undoStack.isEmpty || selection != nil
        canRedo = !redoStack.isEmpty
        isDirty = revision != savedRevision || selection.map { !$0.isCrop && ($0.originalRect == nil || $0.rect != $0.originalRect) } == true
        renderVersion &+= 1
    }
    private func record(_ before: Snapshot) {
        undoStack.append(before)
        redoStack.removeAll()
        // Bound history by both count and actual raster bytes. Always retain the latest step.
        var bytes = undoStack.reduce(0) { $0 + $1.bitmap.pixels.count }
        while undoStack.count > 1 && (undoStack.count > 20 || bytes > 96 * 1024 * 1024) {
            bytes -= undoStack.removeFirst().bitmap.pixels.count
        }
        revision = nextRevision; nextRevision += 1; pristine = false
        refresh()
    }
    public func newCanvas(width: Int, height: Int) {
        guard (try? Bitmap.validate(width, height)) != nil else { status = PaintError.invalidSize.localizedDescription; return }
        finishEditing()
        bitmap = Bitmap(width: width, height: height)
        self.width = width; self.height = height
        selection = nil; hasSelection = false; undoStack = []; redoStack = []
        revision = nextRevision; nextRevision += 1; savedRevision = revision; pristine = true
        status = L10n.tr("New canvas"); refresh()
    }
    public func loadImage(_ image: NSImage) throws {
        let loaded = try Bitmap(image: image)
        finishEditing()
        bitmap = loaded; width = loaded.width; height = loaded.height
        selection = nil; hasSelection = false; undoStack = []; redoStack = []
        revision = nextRevision; nextRevision += 1; savedRevision = revision; pristine = false
        status = L10n.tr("Image opened"); refresh()
    }
    public func pasteImage(_ image: NSImage) throws {
        let pasted = try Bitmap(image: image)
        finishEditing(); commitSelection()
        let before = snapshot()
        if pristine {
            bitmap = Bitmap(width: pasted.width, height: pasted.height, white: false)
            width = pasted.width; height = pasted.height
        }
        // Set the tool before attaching the selection; its observer commits older edits.
        tool = .select
        selection = Selection(image: pasted, rect: CGRect(x: 0, y: 0, width: pasted.width, height: pasted.height),
                              originalRect: nil, before: before)
        hasSelection = true
        status = L10n.tr("Drag to move · Drag a corner to resize · Return to place · Esc to cancel")
        refresh()
    }
    public func select(rect: CGRect) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return }
        finishEditing(); commitSelection()
        let clipped = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        if tool != .crop { tool = .select }
        let before = snapshot()
        selection = Selection(image: bitmap.crop(clipped), rect: clipped, originalRect: clipped, before: before, isCrop: tool == .crop)
        if tool != .crop { bitmap.clear(clipped) }
        hasSelection = true
        status = L10n.tr(tool == .crop ? "Drag to select · Return to crop · Esc to cancel" : "Selection · Drag to move · Return to place · Esc to cancel")
        refresh()
    }
    public func selectAll() { select(rect: CGRect(x: 0, y: 0, width: width, height: height)) }
    public func moveSelection(to point: CGPoint) {
        guard selection != nil, point.x.isFinite, point.y.isFinite else { return }
        if let active = selection, active.isCrop {
            selection?.rect.origin = CGPoint(x: max(0, min(CGFloat(width) - active.rect.width, point.x.rounded())),
                                             y: max(0, min(CGFloat(height) - active.rect.height, point.y.rounded())))
        } else {
            selection?.rect.origin = CGPoint(x: max(-8192, min(8192, point.x.rounded())), y: max(-8192, min(8192, point.y.rounded())))
        }
        refresh()
    }
    public func resizeSelection(to size: CGSize) {
        guard selection != nil, size.width.isFinite, size.height.isFinite else { return }
        let w = Int(max(1, min(8192, size.width.rounded())))
        let h = Int(max(1, min(8192, size.height.rounded())))
        guard (try? Bitmap.validate(w, h)) != nil else { status = PaintError.invalidSize.localizedDescription; return }
        if let active = selection, active.isCrop {
            selection?.rect.size = CGSize(width: min(CGFloat(w), CGFloat(width) - active.rect.minX),
                                         height: min(CGFloat(h), CGFloat(height) - active.rect.minY))
        } else { selection?.rect.size = CGSize(width: w, height: h) }
        refresh()
    }
    func setSelectionRect(_ rect: CGRect) {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        if selection?.isCrop == true {
            let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
            selection?.rect = clipped; refresh(); return
        }
        let w = Int(max(1, min(8192, rect.width.rounded())))
        let h = Int(max(1, min(8192, rect.height.rounded())))
        guard (try? Bitmap.validate(w, h)) != nil else { status = PaintError.invalidSize.localizedDescription; return }
        moveSelection(to: rect.origin); resizeSelection(to: rect.size)
    }
    private func composited() -> Bitmap {
        guard let selection else { return bitmap }
        if selection.isCrop { return bitmap }
        if selection.originalRect == selection.rect { return selection.before.bitmap }
        var result = bitmap
        result.composite(selection.image, in: selection.rect)
        return result
    }
    public func canvasImage() -> NSImage { composited().nsImage() }
    public func commitSelection() {
        guard let active = selection else { return }
        if active.isCrop { selection = nil; hasSelection = false; refresh(); return }
        if active.originalRect == active.rect {
            bitmap = active.before.bitmap
            selection = nil; hasSelection = false; refresh(); return
        }
        bitmap = composited(); selection = nil; hasSelection = false
        record(active.before); status = L10n.tr("Selection placed")
    }
    public func confirmSelection() {
        if selection?.isCrop == true { cropToSelection() } else { commitSelection() }
    }
    public func cancelSelection() {
        guard let active = selection else { return }
        restore(active.before); status = L10n.tr("Selection cancelled")
    }
    public func deleteSelection() {
        finishEditing()
        guard let active = selection else { return }
        if active.isCrop { cancelSelection(); return }
        selection = nil; hasSelection = false
        record(active.before); status = L10n.tr("Selection deleted")
    }
    public func cropToSelection() {
        finishEditing()
        guard let active = selection else { return }
        let crop = active.rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { status = L10n.tr("Move the selection onto the canvas before cropping"); return }
        bitmap = composited().crop(crop); width = bitmap.width; height = bitmap.height
        selection = nil; hasSelection = false
        record(active.before); status = L10n.tr("Cropped to selection")
    }
    public func resizeCanvas(width: Int, height: Int, scaleImage: Bool) throws {
        try Bitmap.validate(width, height)
        finishEditing(); commitSelection()
        guard width != self.width || height != self.height else { return }
        let before = snapshot()
        if scaleImage { bitmap = bitmap.resized(width: width, height: height) }
        else {
            var resized = Bitmap(width: width, height: height)
            // Preserve existing pixels including alpha when changing canvas bounds.
            let copyWidth = min(width, bitmap.width), copyHeight = min(height, bitmap.height)
            for y in 0..<copyHeight {
                let start = y * bitmap.width * 4, target = y * width * 4
                resized.pixels.replaceSubrange(target..<(target + copyWidth * 4), with: bitmap.pixels[start..<(start + copyWidth * 4)])
            }
            bitmap = resized
        }
        self.width = width; self.height = height
        record(before); status = L10n.tr(scaleImage ? "Image resized" : "Canvas resized")
    }
    public func undo() {
        finishEditing()
        if selection != nil { cancelSelection(); return }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot()); restore(previous); status = L10n.tr("Undo")
    }
    public func redo() {
        finishEditing(); commitSelection()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot()); restore(next); status = L10n.tr("Redo")
    }
    public func markSaved() {
        finishEditing(); commitSelection(); savedRevision = revision; refresh(); status = L10n.tr("Saved")
    }
    public func markUnsaved() { savedRevision = -1; refresh() }
    public func refreshLanguage() { status = tool.title; renderVersion &+= 1 }
    public func exportPNG() throws -> Data { finishEditing(); return try composited().encoded(.png) }
    public func exportJPEG() throws -> Data { finishEditing(); return try composited().encoded(.jpeg) }
    public func selectionPNG() throws -> Data? {
        finishEditing()
        guard let active = selection else { return nil }
        if active.isCrop { return try bitmap.crop(active.rect).encoded(.png) }
        try Bitmap.validate(Int(active.rect.width), Int(active.rect.height))
        return try active.image.resized(width: Int(active.rect.width), height: Int(active.rect.height)).encoded(.png)
    }
    public func copyToClipboard(entireCanvas: Bool = false) {
        finishEditing()
        do {
            try writeClipboard(entireCanvas: entireCanvas)
            status = L10n.tr(entireCanvas || !hasSelection ? "Image copied · Ready to paste" : "Selection copied")
        } catch { status = error.localizedDescription }
    }
    private func writeClipboard(entireCanvas: Bool) throws {
        let data = try (!entireCanvas ? selectionPNG() : nil) ?? exportPNG()
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(data, forType: .png) else { throw PaintError.clipboardUnavailable }
        // TIFF is understood by older native macOS applications.
        if let image = NSImage(data: data), let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
    }
    public func cutToClipboard() {
        finishEditing()
        guard hasSelection else { status = L10n.tr("Select an area to cut"); return }
        do { try writeClipboard(entireCanvas: false); deleteSelection(); status = L10n.tr("Selection cut") }
        catch { status = error.localizedDescription }
    }
    public func pasteFromClipboard() {
        paste(from: .general)
    }
    /// A named pasteboard allows clipboard behavior to be tested without altering the user's clipboard.
    func paste(from board: NSPasteboard) {
        if let image = NSImage(pasteboard: board) {
            do { try pasteImage(image) } catch { status = error.localizedDescription }
            return
        }
        let plain = board.string(forType: .string)
        let rich = board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        guard let text = [plain, rich].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            status = L10n.tr("The clipboard does not contain an image or text"); return
        }
        finishEditing(); commitSelection(); setTool(.text)
        beginPastedTextEditing?(text)
    }
    func report(_ message: String) { status = L10n.tr(message) }

    func beginStroke(at point: CGPoint) {
        finishEditing(); commitSelection()
        strokeBefore = snapshot(); strokeStart = point; lastPoint = point
        if tool == .fill {
            floodFill(at: point); endStroke(); return
        }
        if tool == .eyedropper {
            if let picked = bitmap.color(at: point) { color = picked; status = L10n.tr("Color picked") }
            strokeBefore = nil; return
        }
        if [.pencil, .brush, .eraser].contains(tool) { drawLine(from: point, to: point) }
        refresh()
    }
    func continueStroke(to point: CGPoint, constrained: Bool = false) {
        guard let before = strokeBefore else { return }
        if [.pencil, .brush, .eraser].contains(tool) { drawLine(from: lastPoint, to: point); lastPoint = point }
        else {
            bitmap = before.bitmap
            var end = point
            if constrained {
                if tool == .line {
                    let dx = point.x - strokeStart.x, dy = point.y - strokeStart.y
                    let distance = hypot(dx, dy), angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                    end = CGPoint(x: strokeStart.x + cos(angle) * distance, y: strokeStart.y + sin(angle) * distance)
                } else {
                    let side = max(abs(point.x - strokeStart.x), abs(point.y - strokeStart.y))
                    end = CGPoint(x: strokeStart.x + (point.x >= strokeStart.x ? side : -side), y: strokeStart.y + (point.y >= strokeStart.y ? side : -side))
                }
            }
            if tool == .line { drawLine(from: strokeStart, to: end) }
            else {
                let rect = CGRect(x: min(strokeStart.x, end.x), y: min(strokeStart.y, end.y), width: abs(end.x - strokeStart.x), height: abs(end.y - strokeStart.y))
                let lineWidth = max(1, min(128, brushSize)), cg = drawingColor.cgColor
                let fill = fillShapes, ellipse = tool == .ellipse
                bitmap.withContext { context in
                    context.setStrokeColor(cg); context.setFillColor(cg); context.setLineWidth(lineWidth)
                    if ellipse { context.addEllipse(in: rect) } else { context.addRect(rect) }
                    context.drawPath(using: fill ? .fillStroke : .stroke)
                }
            }
        }
        refresh()
    }
    func endStroke() {
        guard let before = strokeBefore else { return }
        strokeBefore = nil
        if bitmap.pixels != before.bitmap.pixels { record(before); status = tool.title }
    }
    private var drawingColor: NSColor { (tool == .eraser ? NSColor.white : color).usingColorSpace(.sRGB) ?? .black }
    var effectiveBrushSize: CGFloat { max(1, min(128, brushSize)) }
    private func drawLine(from start: CGPoint, to end: CGPoint) {
        let size = effectiveBrushSize
        let cg = drawingColor.cgColor
        bitmap.withContext { context in
            context.setStrokeColor(cg); context.setFillColor(cg); context.setLineWidth(size)
            context.setLineCap(.round); context.setLineJoin(.round)
            if start == end { context.fillEllipse(in: CGRect(x: start.x - size / 2, y: start.y - size / 2, width: size, height: size)) }
            else { context.move(to: start); context.addLine(to: end); context.strokePath() }
        }
    }
    private func floodFill(at point: CGPoint) {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let c = drawingColor, a = c.alphaComponent
        let replacement: [UInt8] = [c.redComponent * a, c.greenComponent * a, c.blueComponent * a, a].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        let index = (y * width + x) * 4
        let target = Array(bitmap.pixels[index..<(index+4)])
        guard target != replacement else { return }
        func matches(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return bitmap.pixels[i] == target[0] && bitmap.pixels[i+1] == target[1] && bitmap.pixels[i+2] == target[2] && bitmap.pixels[i+3] == target[3]
        }
        var stack: [(Int, Int)] = [(x, y)]
        while let (sx, sy) = stack.popLast() {
            guard matches(sx, sy) else { continue }
            var left = sx, right = sx
            while left > 0 && matches(left - 1, sy) { left -= 1 }
            while right + 1 < width && matches(right + 1, sy) { right += 1 }
            for px in left...right {
                let i = (sy * width + px) * 4
                bitmap.pixels[i] = replacement[0]; bitmap.pixels[i+1] = replacement[1]
                bitmap.pixels[i+2] = replacement[2]; bitmap.pixels[i+3] = replacement[3]
            }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < height {
                var inSpan = false
                for px in left...right {
                    if matches(px, ny) { if !inSpan { stack.append((px, ny)); inSpan = true } }
                    else { inSpan = false }
                }
            }
        }
    }
    func insertText(_ string: String, at point: CGPoint, width: CGFloat) {
        guard !string.isEmpty, point.x.isFinite, point.y.isFinite, width.isFinite else { return }
        commitSelection()
        let before = snapshot()
        let origin = CGPoint(x: max(0, min(CGFloat(self.width - 1), floor(point.x))),
                             y: max(0, min(CGFloat(height - 1), floor(point.y))))
        let availableWidth = max(1, min(width, CGFloat(self.width) - origin.x))
        let availableHeight = CGFloat(height) - origin.y
        let storage = NSTextStorage(string: string, attributes: textAttributes())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, availableWidth - Self.textInset * 2), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: max(1, min(availableWidth, ceil(used.maxX) + Self.textInset * 2)),
                          height: max(1, min(availableHeight, ceil(used.maxY) + Self.textInset * 2)))
        guard (try? Bitmap.validate(Int(size.width), Int(size.height))) != nil else { status = L10n.tr("Text is too large"); return }
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        let box = CGRect(origin: .zero, size: size)
        NSBezierPath(rect: box).addClip()
        if textBackgroundEnabled { textBackgroundColor.setFill(); box.fill() }
        if textBorder {
            textColor.setStroke()
            let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
        }
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: CGPoint(x: Self.textInset, y: Self.textInset))
        image.unlockFocus()
        if let layer = try? Bitmap(image: image) {
            bitmap.composite(layer, in: CGRect(origin: origin, size: size)); record(before); status = L10n.tr("Text placed")
        }
    }
    static let textInset: CGFloat = 4
    func textAttributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let safeSize = fontSize.isFinite ? max(1, min(512, fontSize)) : 24
        return [.font: NSFont.systemFont(ofSize: safeSize * scale), .foregroundColor: textColor, .paragraphStyle: paragraph]
    }
}
