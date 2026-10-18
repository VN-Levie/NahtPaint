import SwiftUI
import AppKit
import PaintCore

private func uiColor(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    })
}
private let chrome = uiColor((0.93, 0.93, 0.91), (0.15, 0.16, 0.18))
private let edge = uiColor((0.67, 0.68, 0.67), (0.32, 0.34, 0.38))
private let ink = uiColor((0.16, 0.18, 0.22), (0.90, 0.91, 0.94))
private let active = uiColor((0.15, 0.32, 0.64), (0.36, 0.58, 0.96))
private let toolBackground = uiColor((0.98, 0.98, 0.97), (0.20, 0.22, 0.25))
private let selectedBackground = uiColor((0.83, 0.88, 0.96), (0.18, 0.28, 0.43))

struct EditorView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var engine: PaintEngine
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var pngBytes: Int?

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            optionsBar
            Divider()
            HStack(spacing: 0) {
                toolbox
                Rectangle().fill(edge).frame(width: 1)
                PaintCanvasView(engine: engine)
            }
            Divider()
            palette
            Divider()
            statusBar
        }
        .background(chrome)
        .foregroundStyle(ink)
        .sheet(isPresented: $controller.resizePresented) {
            ResizeSheet(engine: engine, scale: controller.scaleOnResize)
        }
        .task(id: engine.renderVersion) {
            pngBytes = nil
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            let bytes = await engine.pngByteCount()
            guard !Task.isCancelled else { return }
            pngBytes = bytes
        }
    }

    private var actionBar: some View {
        HStack(spacing: 5) {
            action("New", "doc", controller.newDocument)
            action("Open", "folder", controller.openDocument)
            action("Save", "square.and.arrow.down") { controller.save() }
            separator
            action("Undo", "arrow.uturn.backward", controller.undo).disabled(!engine.canUndo)
            action("Redo", "arrow.uturn.forward", controller.redo).disabled(!engine.canRedo)
            separator
            action("Paste", "doc.on.clipboard", controller.paste)
            action("Crop", "crop") { engine.cropToSelection() }.disabled(!engine.hasSelection)
            flipAction("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", engine.flipSelectionHorizontally)
            flipAction("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down", engine.flipSelectionVertically)
            Spacer(minLength: 4)
            Button { controller.showPreferences() } label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                .buttonStyle(.plain).help(L10n.tr("Settings…"))
                .accessibilityLabel(L10n.tr("Settings…"))
            Button(action: controller.copyAll) {
                Label(L10n.tr("Copy Image"), systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(.white).background(active, in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Copy the complete image to paste into another app (⇧⌘C)"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var optionsBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(engine.tool.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(width: 92, alignment: .leading)
                if engine.tool == .text || engine.hasSelectedText {
                    Picker(L10n.tr("Text size"), selection: $engine.fontSize) {
                        ForEach([12, 16, 20, 24, 32, 48, 64, 96], id: \.self) { size in Text("\(size) pt").tag(CGFloat(size)) }
                    }.labelsHidden().frame(width: 78).help(L10n.tr("Text size"))
                    ColorPicker(L10n.tr("Text color"), selection: Binding(get: { Color(nsColor: engine.textColor) }, set: { engine.textColor = NSColor($0) }))
                        .fixedSize()
                    Toggle(L10n.tr("Border"), isOn: $engine.textBorder).toggleStyle(.checkbox)
                    Toggle(L10n.tr("Background"), isOn: $engine.textBackgroundEnabled).toggleStyle(.checkbox)
                    if engine.textBackgroundEnabled {
                        ColorPicker(L10n.tr("Background color"), selection: Binding(get: { Color(nsColor: engine.textBackgroundColor) }, set: { engine.textBackgroundColor = NSColor($0) }))
                            .labelsHidden().help(L10n.tr("Background color"))
                    }
                } else if engine.tool == .select || engine.tool == .crop {
                    Text(L10n.tr(engine.tool == .crop ? "Drag to select · Return to crop · Esc to cancel" : "Drag to select · drag corners to resize · Return to place"))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(L10n.tr("Size"))
                    Slider(value: $engine.brushSize, in: 1...(engine.tool == .highlighter ? 80 : 40), step: 1).frame(width: 100)
                    Text("\(Int(engine.brushSize)) px").monospacedDigit().frame(width: 36, alignment: .leading)
                    if engine.tool == .highlighter {
                        Text(L10n.tr("Opacity"))
                        Slider(value: $engine.highlighterOpacity, in: 0.1...0.6, step: 0.05).frame(width: 90)
                        Text("\(Int((engine.highlighterOpacity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 32, alignment: .leading)
                    }
                    if engine.tool == .rectangle || engine.tool == .ellipse {
                        Toggle(L10n.tr("Fill"), isOn: $engine.fillShapes).toggleStyle(.checkbox)
                    }
                }
                Spacer(minLength: 0)
                Button(L10n.tr("Resize…")) { controller.presentResize(scale: true) }
            }
            .font(.system(size: 11)).frame(minHeight: 29)
        }
        .padding(.horizontal, 12).frame(height: 35)
    }

    private var currentColor: NSColor {
        if engine.tool == .text || engine.hasSelectedText { return engine.textColor }
        return engine.tool == .highlighter ? engine.highlighterColor : engine.color
    }
    private func setCurrentColor(_ color: NSColor) {
        if engine.tool == .text || engine.hasSelectedText { engine.textColor = color }
        else if engine.tool == .highlighter { engine.highlighterColor = color }
        else { engine.color = color }
    }

    private var toolbox: some View {
        ScrollView(.vertical) {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.fixed(46), spacing: 4), GridItem(.fixed(46), spacing: 4)], spacing: 5) {
                ForEach(PaintTool.allCases) { tool in
                    Button { engine.setTool(tool) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tool.symbol).font(.system(size: 17, weight: .regular)).frame(height: 23)
                            Text(tool.title).font(.system(size: 9)).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center)
                        }
                        .frame(width: 46, height: 48)
                        .foregroundStyle(engine.tool == tool ? active : ink)
                        .background(engine.tool == tool ? selectedBackground : toolBackground)
                        .overlay(Rectangle().stroke(engine.tool == tool ? active : edge.opacity(0.65), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(tool.shortcut.uppercased()))")
                    .accessibilityLabel(tool.title)
                    .accessibilityValue(engine.tool == tool ? L10n.tr("Selected") : "")
                }
            }
            Divider().padding(.vertical, 5)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: currentColor))
                .frame(width: 36, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(edge))
                .padding(7)
                .background(toolBackground)
                .overlay(Rectangle().stroke(edge.opacity(0.6)))
                .accessibilityLabel(L10n.tr("Current drawing color"))
            Text(L10n.tr("COLOR")).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        }.scrollIndicators(.hidden).frame(width: 114)
    }

    private var palette: some View {
        HStack(spacing: 12) {
            ColorPicker(L10n.tr("Color"), selection: Binding(get: { Color(nsColor: currentColor) }, set: { setCurrentColor(NSColor($0)) }), supportsOpacity: true)
                .labelsHidden().help(L10n.tr("Choose a custom color")).frame(width: 42)
            HStack(spacing: 3) {
                ForEach(0..<14, id: \.self) { column in
                    VStack(spacing: 3) {
                        swatch(Palette.colors[column])
                        swatch(Palette.colors[column + 14])
                    }
                }
            }
            Spacer(minLength: 8)
            Text(L10n.tr("⌘V Paste    ⇧⌘C Copy Image"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func swatch(_ entry: Palette.Entry) -> some View {
        Button { setCurrentColor(NSColor(Color(red: entry.r, green: entry.g, blue: entry.b))) } label: {
            Rectangle().fill(Color(red: entry.r, green: entry.g, blue: entry.b))
                .frame(width: 20, height: 19)
                .overlay(Rectangle().stroke(.white, lineWidth: 1).padding(1))
                .overlay(Rectangle().stroke(edge, lineWidth: 1))
        }
        .buttonStyle(.plain).help(L10n.tr(entry.name)).accessibilityLabel(L10n.tr(entry.name))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(engine.status).lineLimit(1).truncationMode(.tail)
            Spacer()
            Text("\(engine.width) × \(engine.height) px").monospacedDigit()
                .help(L10n.tr("Canvas width × height in pixels"))
                .fixedSize()
            Text(pngBytes.map { "PNG ≈ " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "PNG …")
                .monospacedDigit().fixedSize()
                .help(L10n.tr("PNG size of the entire canvas. Clipboard apps may use a different format."))
            Divider().frame(height: 13)
            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain).help(L10n.tr("Zoom out"))
            Picker(L10n.tr("Zoom"), selection: $engine.zoom) {
                ForEach(zoomLevels, id: \.self) { value in Text("\(Int((value * 100).rounded()))%").tag(value) }
            }.labelsHidden().frame(width: 76)
                .help(L10n.tr("Mouse wheel to zoom. Shift-wheel to pan. ⌘-scroll to zoom with a trackpad."))
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain).help(L10n.tr("Zoom in"))
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 29)
    }
    private var zoomLevels: [CGFloat] { Array(Set([CGFloat(0.125), 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 8, engine.zoom])).sorted() }
    private var separator: some View { Divider().frame(height: 22).padding(.horizontal, 5) }
    private func flipAction(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(L10n.tr(title))
        .accessibilityLabel(L10n.tr(title))
        .disabled(!engine.canFlipSelection)
    }
    private func action(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.tr(title), systemImage: symbol).font(.system(size: 12)).padding(.horizontal, 7).padding(.vertical, 6)
        }.buttonStyle(.plain).help(L10n.tr(title))
    }
}

private enum Palette {
    struct Entry { let name: String; let r: Double; let g: Double; let b: Double }
    static let colors: [Entry] = [
        .init(name: "Black", r: 0, g: 0, b: 0), .init(name: "Gray", r: 0.48, g: 0.48, b: 0.48),
        .init(name: "Maroon", r: 0.5, g: 0, b: 0), .init(name: "Olive", r: 0.5, g: 0.5, b: 0),
        .init(name: "Green", r: 0, g: 0.5, b: 0), .init(name: "Teal", r: 0, g: 0.5, b: 0.5),
        .init(name: "Navy", r: 0, g: 0, b: 0.5), .init(name: "Purple", r: 0.5, g: 0, b: 0.5),
        .init(name: "Ochre", r: 0.68, g: 0.43, b: 0.12), .init(name: "Forest", r: 0.1, g: 0.3, b: 0.18),
        .init(name: "Slate", r: 0.25, g: 0.35, b: 0.48), .init(name: "Indigo", r: 0.28, g: 0.2, b: 0.55),
        .init(name: "Rose", r: 0.65, g: 0.2, b: 0.4), .init(name: "Brown", r: 0.4, g: 0.25, b: 0.18),
        .init(name: "White", r: 1, g: 1, b: 1), .init(name: "Silver", r: 0.76, g: 0.76, b: 0.76),
        .init(name: "Red", r: 1, g: 0.1, b: 0.1), .init(name: "Yellow", r: 1, g: 0.87, b: 0.05),
        .init(name: "Lime", r: 0.2, g: 0.85, b: 0.22), .init(name: "Cyan", r: 0.1, g: 0.85, b: 0.91),
        .init(name: "Blue", r: 0.1, g: 0.3, b: 0.96), .init(name: "Magenta", r: 0.91, g: 0.15, b: 0.82),
        .init(name: "Orange", r: 1, g: 0.52, b: 0.08), .init(name: "Mint", r: 0.65, g: 0.89, b: 0.65),
        .init(name: "Sky", r: 0.61, g: 0.82, b: 1), .init(name: "Lavender", r: 0.76, g: 0.7, b: 0.91),
        .init(name: "Pink", r: 1, g: 0.69, b: 0.76), .init(name: "Cream", r: 1, g: 0.9, b: 0.7)
    ]
}

private struct ResizeSheet: View {
    @ObservedObject var engine: PaintEngine
    let scale: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var height = ""
    @State private var lockRatio = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(scale ? L10n.tr("Resize Image") : L10n.tr("Canvas Size")).font(.headline)
            HStack {
                Text(L10n.tr("Width")).frame(width: 84, alignment: .leading)
                TextField(L10n.tr("Width"), text: $width).frame(width: 110)
                    .onChange(of: width) { _, value in
                        if lockRatio, let w = Int(value), engine.width > 0 { height = String(max(1, Int((Double(w) * Double(engine.height) / Double(engine.width)).rounded()))) }
                    }
                Text("px").foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.tr("Height")).frame(width: 84, alignment: .leading)
                TextField(L10n.tr("Height"), text: $height).frame(width: 110).disabled(lockRatio)
                Text("px").foregroundStyle(.secondary)
            }
            Toggle(L10n.tr("Keep proportions"), isOn: $lockRatio)
            if !scale { Text(L10n.tr("Existing pixels stay at the top left.")).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Resize")) { resize() }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder).padding(24).frame(width: 390)
        .onAppear { width = String(engine.width); height = String(engine.height); lockRatio = scale }
    }
    private func resize() {
        guard let w = Int(width), let h = Int(height) else { error = L10n.tr("Enter whole numbers for width and height."); return }
        do { try engine.resizeCanvas(width: w, height: h, scaleImage: scale); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
