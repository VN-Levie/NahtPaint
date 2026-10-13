import AppKit
import Combine

public enum ImagePasteMode: String, CaseIterable, Identifiable {
    case automatic, fitCanvas, expandCanvas
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return L10n.tr("Automatic")
        case .fitCanvas: return L10n.tr("Fit to canvas")
        case .expandCanvas: return L10n.tr("Expand canvas")
        }
    }
}

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
    @Published public var textColor: NSColor = .black { didSet { applySelectedTextStyle() } }
    @Published public var textBorder = false { didSet { applySelectedTextStyle() } }
    @Published public var textBackgroundEnabled = false { didSet { applySelectedTextStyle() } }
    @Published public var textBackgroundColor: NSColor = .white { didSet { applySelectedTextStyle() } }
    @Published public var brushSize: CGFloat = 3
    @Published public var fontSize: CGFloat = 24 { didSet { applySelectedTextStyle() } }
    @Published public var fillShapes = false
    @Published public var zoom: CGFloat = 1
    @Published public var imagePasteMode: ImagePasteMode = .automatic
    @Published public var fitViewAfterPasting = true
    @Published public private(set) var width: Int
    @Published public private(set) var height: Int
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var isDirty = false
    @Published public private(set) var hasSelection = false
    @Published public private(set) var status = L10n.tr("Ready · Paste an image with ⌘V")
    @Published public private(set) var renderVersion = 0
    public var selectionRect: CGRect? { selection?.rect ?? selectedTextObject?.bounds }
    public var hasSelectedText: Bool { selectedTextID != nil }
    private(set) var textObjects: [PaintTextObject] = []
    private(set) var selectedTextID: UUID?
    private(set) var editingTextID: UUID?
    var selectedTextObject: PaintTextObject? { textObjects.first { $0.id == selectedTextID } }

    struct Snapshot {
        var bitmap: Bitmap
        var revision: Int
        var pristine: Bool
        var textObjects: [PaintTextObject]
    }
    struct Selection {
        var image: Bitmap
        var rect: CGRect
        var originalRect: CGRect?
        var before: Snapshot
        var isCrop = false
        var textIDs: Set<UUID> = []
        var textSourceRect: CGRect?
    }
    var bitmap: Bitmap
    var selection: Selection?
    var finishTextEditing: (() -> Void)?
    var beginPastedTextEditing: ((String) -> Void)?
    var fitViewAfterImagePaste: (() -> Void)?
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
    private var textMoveBefore: Snapshot?
    private var updatingTextControls = false

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
        // A drag is one document operation even if Save/Undo arrives before mouse-up.
        endTextMove()
        finishTextEditing?()
        finishingText = false
    }
    private func snapshot() -> Snapshot { Snapshot(bitmap: bitmap, revision: revision, pristine: pristine, textObjects: textObjects) }
    private func restore(_ snapshot: Snapshot) {
        bitmap = snapshot.bitmap; revision = snapshot.revision; pristine = snapshot.pristine
        textObjects = snapshot.textObjects; selectedTextID = nil; editingTextID = nil; textMoveBefore = nil
        width = bitmap.width; height = bitmap.height
        selection = nil; hasSelection = false
        refresh()
    }
    private func refresh() {
        canUndo = !undoStack.isEmpty || selection != nil
        canRedo = !redoStack.isEmpty
        hasSelection = selection != nil || selectedTextID != nil
        isDirty = revision != savedRevision || selection.map { !$0.isCrop && ($0.originalRect == nil || $0.rect != $0.originalRect) } == true
            || textMoveBefore.map { before in zip(before.textObjects, textObjects).contains { $0.position != $1.position } } == true
        renderVersion &+= 1
    }
    private func record(_ before: Snapshot) {
        undoStack.append(before)
        redoStack.removeAll()
        // Bound history by both count and actual raster bytes. Always retain the latest step.
        func cost(_ snapshot: Snapshot) -> Int { snapshot.bitmap.pixels.count + snapshot.textObjects.reduce(0) { $0 + $1.raster.pixels.count } }
        var bytes = undoStack.reduce(0) { $0 + cost($1) }
        while undoStack.count > 1 && (undoStack.count > 20 || bytes > 96 * 1024 * 1024) {
            bytes -= cost(undoStack.removeFirst())
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
        textObjects = []; selectedTextID = nil; editingTextID = nil; textMoveBefore = nil
        revision = nextRevision; nextRevision += 1; savedRevision = revision; pristine = true
        status = L10n.tr("New canvas"); refresh()
    }
    public func loadImage(_ image: NSImage) throws {
        let loaded = try Bitmap(image: image)
        finishEditing()
        bitmap = loaded; width = loaded.width; height = loaded.height
        selection = nil; hasSelection = false; undoStack = []; redoStack = []
        textObjects = []; selectedTextID = nil; editingTextID = nil; textMoveBefore = nil
        revision = nextRevision; nextRevision += 1; savedRevision = revision; pristine = false
        status = L10n.tr("Image opened"); refresh()
    }
    public func pasteImage(_ image: NSImage) throws {
        let pasted = try Bitmap(image: image)
        finishEditing(); commitSelection()
        let before = snapshot()
        var pastedSize = CGSize(width: pasted.width, height: pasted.height)
        if pristine {
            bitmap = Bitmap(width: pasted.width, height: pasted.height, white: false)
            width = pasted.width; height = pasted.height
        } else if pasted.width > width || pasted.height > height {
            let ratio = min(CGFloat(width) / CGFloat(pasted.width), CGFloat(height) / CGFloat(pasted.height), 1)
            let shouldExpand = imagePasteMode == .expandCanvas || (imagePasteMode == .automatic && ratio < 0.5)
            let newWidth = max(width, pasted.width), newHeight = max(height, pasted.height)
            if shouldExpand, (try? Bitmap.validate(newWidth, newHeight)) != nil {
                var expanded = Bitmap(width: newWidth, height: newHeight)
                for y in 0..<height {
                    let source = y * width * 4, target = y * newWidth * 4
                    expanded.pixels.replaceSubrange(target..<(target + width * 4), with: bitmap.pixels[source..<(source + width * 4)])
                }
                bitmap = expanded; width = newWidth; height = newHeight
            } else {
                pastedSize = CGSize(width: max(1, floor(CGFloat(pasted.width) * ratio)),
                                    height: max(1, floor(CGFloat(pasted.height) * ratio)))
            }
        }
        // Set the tool before attaching the selection; its observer commits older edits.
        tool = .select
        selection = Selection(image: pasted, rect: CGRect(origin: .zero, size: pastedSize),
                              originalRect: nil, before: before)
        hasSelection = true
        status = L10n.tr("Drag to move · Drag a corner to resize · Return to place · Esc to cancel")
        refresh()
        if fitViewAfterPasting { fitViewAfterImagePaste?() }
    }
    public func select(rect: CGRect) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return }
        finishEditing(); commitSelection()
        let canvasBounds = CGRect(x: 0, y: 0, width: width, height: height)
        var clipped = rect.standardized.integral.intersection(canvasBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        if tool != .crop { tool = .select }
        var carried: Set<UUID> = []
        if tool != .crop {
            // Carry complete intersecting text objects rather than baking partial glyphs into pixels.
            var changed = true
            while changed {
                changed = false
                for object in textObjects where !carried.contains(object.id) {
                    let visible = object.bounds.intersection(canvasBounds)
                    if !visible.isNull, visible.intersects(clipped) {
                        carried.insert(object.id); clipped = clipped.union(visible).integral.intersection(canvasBounds); changed = true
                    }
                }
            }
        }
        let before = snapshot()
        selection = Selection(image: bitmap.crop(clipped), rect: clipped, originalRect: clipped, before: before, isCrop: tool == .crop, textIDs: carried)
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
    private func compositedRaster() -> Bitmap {
        guard let selection else { return bitmap }
        if selection.isCrop { return bitmap }
        if selection.originalRect == selection.rect { return selection.before.bitmap }
        var result = bitmap
        result.composite(selection.image, in: selection.rect)
        return result
    }
    private func projectedTextObjects() -> [PaintTextObject] {
        guard let selection, !selection.isCrop, let original = selection.textSourceRect ?? selection.originalRect,
              original != selection.rect else { return textObjects }
        return textObjects.map { selection.textIDs.contains($0.id) ? $0.transformed(from: original, to: selection.rect) : $0 }
    }
    func displayBitmap(excludingTextID: UUID? = nil) -> Bitmap {
        var result = compositedRaster()
        for object in projectedTextObjects() where object.id != excludingTextID { object.draw(on: &result) }
        return result
    }
    public func canvasImage() -> NSImage { displayBitmap().nsImage() }
    public func commitSelection() {
        selectedTextID = nil
        guard let active = selection else { refresh(); return }
        if active.isCrop { selection = nil; hasSelection = false; refresh(); return }
        if active.originalRect == active.rect {
            bitmap = active.before.bitmap
            selection = nil; hasSelection = false; refresh(); return
        }
        bitmap = compositedRaster(); textObjects = projectedTextObjects(); selection = nil; hasSelection = false
        record(active.before); status = L10n.tr("Selection placed")
    }
    public func confirmSelection() {
        if selection?.isCrop == true { cropToSelection() } else { commitSelection() }
    }
    public func cancelSelection() {
        if let before = textMoveBefore {
            restore(before); status = L10n.tr("Selection cancelled"); return
        }
        guard let active = selection else { selectedTextID = nil; refresh(); return }
        restore(active.before); status = L10n.tr("Selection cancelled")
    }
    public func deleteSelection() {
        finishEditing()
        if let id = selectedTextID {
            let before = snapshot(); textObjects.removeAll { $0.id == id }; selectedTextID = nil
            record(before); status = L10n.tr("Selection deleted"); return
        }
        guard let active = selection else { return }
        if active.isCrop { cancelSelection(); return }
        textObjects.removeAll { active.textIDs.contains($0.id) }
        selection = nil; hasSelection = false
        record(active.before); status = L10n.tr("Selection deleted")
    }
    public func cropToSelection() {
        finishEditing()
        guard let region = selectionRect else { return }
        let before = selection?.before ?? snapshot()
        let crop = region.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { status = L10n.tr("Move the selection onto the canvas before cropping"); return }
        bitmap = compositedRaster().crop(crop)
        textObjects = projectedTextObjects().compactMap { $0.clipped(to: crop) }
        width = bitmap.width; height = bitmap.height; selectedTextID = nil
        selection = nil; hasSelection = false
        record(before); status = L10n.tr("Cropped to selection")
    }
    public func resizeCanvas(width: Int, height: Int, scaleImage: Bool) throws {
        try Bitmap.validate(width, height)
        finishEditing(); commitSelection()
        guard width != self.width || height != self.height else { return }
        let before = snapshot()
        if scaleImage {
            let source = CGRect(x: 0, y: 0, width: self.width, height: self.height)
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            bitmap = bitmap.resized(width: width, height: height)
            textObjects = textObjects.map { $0.transformed(from: source, to: target) }
        }
        else {
            if width < self.width || height < self.height {
                let retained = CGRect(x: 0, y: 0, width: width, height: height)
                textObjects = textObjects.compactMap { $0.clipped(to: retained) }
            }
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
    public func exportPNG() throws -> Data { finishEditing(); return try displayBitmap().encoded(.png) }
    public func exportJPEG() throws -> Data { finishEditing(); return try displayBitmap().encoded(.jpeg) }
    public func selectionPNG() throws -> Data? {
        finishEditing()
        if let object = selectedTextObject {
            let rect = object.bounds.integral
            try Bitmap.validate(Int(rect.width), Int(rect.height))
            var output = Bitmap(width: Int(rect.width), height: Int(rect.height), white: false)
            object.draw(on: &output, offset: rect.origin)
            return try output.encoded(.png)
        }
        guard let active = selection else { return nil }
        if active.isCrop { return try displayBitmap().crop(active.rect).encoded(.png) }
        try Bitmap.validate(Int(active.rect.width), Int(active.rect.height))
        var output = active.image.resized(width: Int(active.rect.width), height: Int(active.rect.height))
        for object in projectedTextObjects() where active.textIDs.contains(object.id) { object.draw(on: &output, offset: active.rect.origin) }
        return try output.encoded(.png)
    }
    public func copyToClipboard(entireCanvas: Bool = false) {
        finishEditing()
        do {
            try writeClipboard(entireCanvas: entireCanvas)
            status = L10n.tr(entireCanvas || !hasSelection ? "Image copied · Ready to paste" : "Selection copied")
        } catch { status = error.localizedDescription }
    }
    private func writeClipboard(entireCanvas: Bool) throws {
        try copy(to: .general, entireCanvas: entireCanvas)
    }
    private static let textClipboardType = NSPasteboard.PasteboardType("com.nathpaint.editable-text.v1")
    private static let rasterClipboardType = NSPasteboard.PasteboardType("com.nathpaint.raster.png")
    func copy(to board: NSPasteboard, entireCanvas: Bool = false) throws {
        finishEditing()
        let data = try (!entireCanvas ? selectionPNG() : nil) ?? exportPNG()
        let layers = try clipboardLayers(entireCanvas: entireCanvas)
        let textData = layers.1.isEmpty ? nil : try JSONEncoder().encode(layers.1)
        let rasterData = textData == nil ? nil : try layers.0.encoded(.png)
        board.clearContents()
        guard board.setData(data, forType: .png) else { throw PaintError.clipboardUnavailable }
        // TIFF is understood by older native macOS applications.
        if let image = NSImage(data: data), let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        if let textData, let rasterData {
            board.setData(textData, forType: Self.textClipboardType)
            board.setData(rasterData, forType: Self.rasterClipboardType)
        }
    }
    private func clipboardLayers(entireCanvas: Bool) throws -> (Bitmap, [PaintTextTransfer]) {
        if !entireCanvas, let object = selectedTextObject {
            let rect = object.bounds.integral
            try Bitmap.validate(Int(rect.width), Int(rect.height))
            return (Bitmap(width: Int(rect.width), height: Int(rect.height), white: false), [PaintTextTransfer(object, offset: rect.origin)])
        }
        if !entireCanvas, let active = selection {
            if active.isCrop {
                let objects = projectedTextObjects().compactMap { $0.clipped(to: active.rect) }
                return (compositedRaster().crop(active.rect), objects.map { PaintTextTransfer($0, offset: .zero) })
            }
            try Bitmap.validate(Int(active.rect.width), Int(active.rect.height))
            let objects = projectedTextObjects().filter { active.textIDs.contains($0.id) }
            return (active.image.resized(width: Int(active.rect.width), height: Int(active.rect.height)),
                    objects.map { PaintTextTransfer($0, offset: active.rect.origin) })
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let objects = projectedTextObjects().compactMap { $0.clipped(to: canvas) }
        return (compositedRaster(), objects.map { PaintTextTransfer($0, offset: .zero) })
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
        if let metadata = board.data(forType: Self.textClipboardType), metadata.count <= 16 * 1024 * 1024,
           let raster = board.data(forType: Self.rasterClipboardType), let image = NSImage(data: raster),
           let transfers = try? JSONDecoder().decode([PaintTextTransfer].self, from: metadata), transfers.count <= 1024,
           let objects = try? decodeTextObjects(transfers) {
            do {
                try pasteImage(image)
                if let active = selection {
                    textObjects.append(contentsOf: objects)
                    selection?.textIDs = Set(objects.map(\.id))
                    selection?.textSourceRect = CGRect(x: 0, y: 0, width: active.image.width, height: active.image.height)
                    refresh()
                }
            } catch { status = error.localizedDescription }
            return
        }
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
    private func decodeTextObjects(_ transfers: [PaintTextTransfer]) throws -> [PaintTextObject] {
        var objects: [PaintTextObject] = []
        var bytes = 0
        for transfer in transfers {
            let object = try transfer.object()
            bytes += object.raster.pixels.count
            guard bytes <= 96 * 1024 * 1024 else { throw PaintError.invalidSize }
            objects.append(object)
        }
        return objects
    }
    func report(_ message: String) { status = L10n.tr(message) }

    func beginStroke(at point: CGPoint) {
        finishEditing(); commitSelection()
        strokeBefore = snapshot(); strokeStart = point; lastPoint = point
        if tool == .fill {
            floodFill(at: point); endStroke(); return
        }
        if tool == .eyedropper {
            if let picked = displayBitmap().color(at: point) { color = picked; status = L10n.tr("Color picked") }
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
    private var currentTextStyle: PaintTextStyle {
        PaintTextStyle(fontSize: fontSize, color: textColor.usingColorSpace(.sRGB) ?? .black, border: textBorder,
                       backgroundEnabled: textBackgroundEnabled, backgroundColor: textBackgroundColor.usingColorSpace(.sRGB) ?? .white)
    }
    private func useTextStyle(_ style: PaintTextStyle) {
        updatingTextControls = true
        defer { updatingTextControls = false }
        fontSize = style.fontSize; textColor = style.color; textBorder = style.border
        textBackgroundEnabled = style.backgroundEnabled; textBackgroundColor = style.backgroundColor
    }
    private func applySelectedTextStyle() {
        guard !updatingTextControls, editingTextID == nil, let object = selectedTextObject else { return }
        updateText(id: object.id, text: object.text, layoutWidth: object.layoutWidth)
    }
    func insertText(_ string: String, at point: CGPoint, width: CGFloat) {
        guard !string.isEmpty, point.x.isFinite, point.y.isFinite, width.isFinite else { return }
        commitSelection()
        let origin = CGPoint(x: max(0, min(CGFloat(self.width - 1), floor(point.x))),
                             y: max(0, min(CGFloat(height - 1), floor(point.y))))
        let layoutWidth = max(1, min(width, CGFloat(self.width) - origin.x))
        do {
            let style = currentTextStyle
            let raster = try PaintTextObject.render(text: string, width: layoutWidth, style: style)
            let before = snapshot()
            let object = PaintTextObject(id: UUID(), text: string, position: origin, layoutWidth: layoutWidth, style: style, raster: raster)
            textObjects.append(object); selectedTextID = object.id; editingTextID = nil
            record(before); status = L10n.tr("Text selected · Drag to move · Double-click to edit")
        } catch { status = error.localizedDescription }
    }
    func textObject(at point: CGPoint) -> PaintTextObject? {
        projectedTextObjects().reversed().first { $0.bounds.contains(point) }
    }
    func selectText(id: UUID) {
        finishEditing()
        if selection != nil { commitSelection() }
        guard let object = textObjects.first(where: { $0.id == id }) else { return }
        selectedTextID = id; useTextStyle(object.style)
        refresh(); status = L10n.tr("Text selected · Drag to move · Double-click to edit")
    }
    func beginTextEditing(id: UUID) -> PaintTextObject? {
        finishEditing(); commitSelection()
        guard let object = textObjects.first(where: { $0.id == id }) else { return nil }
        setTool(.text); selectedTextID = id; editingTextID = id
        useTextStyle(object.style); refresh()
        return object
    }
    func updateText(id: UUID, text: String, layoutWidth: CGFloat) {
        guard let index = textObjects.firstIndex(where: { $0.id == id }), layoutWidth.isFinite else { return }
        let original = textObjects[index]
        editingTextID = nil
        if text.isEmpty {
            let before = snapshot(); textObjects.remove(at: index); selectedTextID = nil; record(before); return
        }
        let style = currentTextStyle
        let width = max(1, min(8192, layoutWidth))
        if original.text == text, original.layoutWidth == width, original.style == style {
            selectedTextID = id; refresh(); return
        }
        do {
            let raster = try PaintTextObject.render(text: text, width: width, style: style)
            let before = snapshot()
            var edited = original
            edited.text = text; edited.layoutWidth = width; edited.style = style; edited.raster = raster
            textObjects[index] = edited; selectedTextID = id
            record(before); status = L10n.tr("Text selected · Drag to move · Double-click to edit")
        } catch { status = error.localizedDescription; refresh() }
    }
    func cancelTextEditing() {
        if let id = editingTextID, let object = textObjects.first(where: { $0.id == id }) {
            selectedTextID = id; useTextStyle(object.style)
        }
        editingTextID = nil; refresh(); status = L10n.tr("Text cancelled")
    }
    func beginTextMove() {
        finishEditing()
        guard selectedTextID != nil else { return }
        textMoveBefore = snapshot()
    }
    func moveSelectedText(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite,
              let index = textObjects.firstIndex(where: { $0.id == selectedTextID }) else { return }
        if textMoveBefore == nil { textMoveBefore = snapshot() }
        textObjects[index].position = CGPoint(x: max(-8192, min(8192, point.x.rounded())),
                                             y: max(-8192, min(8192, point.y.rounded())))
        refresh()
    }
    func endTextMove() {
        guard let before = textMoveBefore else { return }
        textMoveBefore = nil
        if zip(before.textObjects, textObjects).contains(where: { $0.position != $1.position }) { record(before) }
        else { refresh() }
    }
    func nudgeSelectedText(dx: CGFloat, dy: CGFloat) {
        guard let object = selectedTextObject else { return }
        beginTextMove(); moveSelectedText(to: CGPoint(x: object.position.x + dx, y: object.position.y + dy)); endTextMove()
    }
    static let textInset: CGFloat = 4
    func textAttributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] { currentTextStyle.attributes(scale: scale) }
}
