import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import PaintCore

@MainActor
final class AppController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppController()
    let engine = PaintEngine()
    @Published var fileURL: URL?
    @Published var resizePresented = false
    @Published var scaleOnResize = true
    weak var window: NSWindow?
    private var preferencesWindow: NSWindow?
    private var systemLocaleObservation: AnyCancellable?
    private var observation: AnyCancellable?
    private var languageObservation: AnyCancellable?

    override init() {
        super.init()
        languageObservation = AppPreferences.shared.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.engine.finishEditing()
                self.engine.refreshLanguage()
                self.syncTitle()
                self.preferencesWindow?.title = "NathPaint — " + L10n.tr("Settings…")
                self.objectWillChange.send()
            }
        }
        systemLocaleObservation = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard AppPreferences.shared.language == .system, let self else { return }
                AppPreferences.shared.objectWillChange.send()
                self.engine.refreshLanguage(); self.syncTitle()
                self.preferencesWindow?.title = "NathPaint — " + L10n.tr("Settings…")
            }
        }
        observation = engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncTitle(); self?.objectWillChange.send() }
        }
    }

    func attach(_ window: NSWindow) {
        self.window = window
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NathPaint.Editor")
        syncTitle()
    }
    private func syncTitle() {
        window?.title = "\(fileURL?.lastPathComponent ?? L10n.tr("Untitled")) — NathPaint"
        window?.isDocumentEdited = engine.isDirty
        window?.representedURL = fileURL
    }
    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if preferencesWindow == nil {
            let host = NSHostingController(rootView: PreferencesView())
            let settings = NSWindow(contentViewController: host)
            settings.styleMask = [.titled, .closable]
            settings.isReleasedWhenClosed = false
            settings.title = "NathPaint — " + L10n.tr("Settings…")
            settings.center()
            preferencesWindow = settings
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the document and window alive while the app lives in the menu bar.
        engine.finishEditing()
        sender.orderOut(nil)
        return false
    }
    private var textEditor: NSTextView? {
        guard let text = window?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text
    }
    func copy() { if let text = textEditor { text.copy(nil) } else { engine.copyToClipboard() } }
    func copyAll() { engine.finishEditing(); engine.copyToClipboard(entireCanvas: true) }
    func cut() { if let text = textEditor { text.cut(nil) } else { engine.cutToClipboard() } }
    func paste() { if let text = textEditor { text.paste(nil) } else { engine.pasteFromClipboard() } }
    func selectAll() { if let text = textEditor { text.selectAll(nil) } else { engine.selectAll() } }
    func undo() { if let text = textEditor { text.undoManager?.undo() } else { engine.undo() } }
    func redo() { if let text = textEditor { text.undoManager?.redo() } else { engine.redo() } }

    func confirmDiscard() -> Bool {
        engine.finishEditing()
        guard engine.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Save changes to %@?", fileURL?.lastPathComponent ?? L10n.tr("Untitled"))
        alert.informativeText = L10n.tr("Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L10n.tr("Save"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.addButton(withTitle: L10n.tr("Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func newDocument() {
        guard confirmDiscard() else { return }
        engine.newCanvas(width: 960, height: 640)
        fileURL = nil
        syncTitle(); showWindow()
    }
    func openDocument() {
        showWindow()
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Open Image")
        panel.prompt = L10n.tr("Open")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openURL(url) }
    }
    func openURL(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.isValid else {
            showError(L10n.tr("This file could not be opened as an image.")); return
        }
        guard confirmDiscard() else { return }
        do {
            try engine.loadImage(image)
            fileURL = url; engine.markSaved(); syncTitle(); showWindow()
        } catch { showError(error.localizedDescription) }
    }
    func newFromClipboard() {
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first else {
            showError(L10n.tr("Copy an image first, then choose New from Clipboard.")); return
        }
        guard confirmDiscard() else { return }
        do {
            try engine.loadImage(image)
            fileURL = nil
            // Clipboard images are new, unsaved documents.
            engine.markUnsaved()
            syncTitle(); showWindow()
        } catch { showError(error.localizedDescription) }
    }

    @discardableResult
    func save(asNew: Bool = false) -> Bool {
        engine.finishEditing()
        engine.commitSelection()
        var target = asNew ? nil : fileURL
        if let url = target, !["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) { target = nil }
        if target == nil {
            let panel = NSSavePanel()
            panel.title = L10n.tr("Save Image")
            panel.prompt = L10n.tr("Save")
            panel.allowedContentTypes = [.png, .jpeg]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = fileURL.map { $0.deletingPathExtension().lastPathComponent + ".png" } ?? L10n.tr("Untitled") + ".png"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            target = url
        }
        guard let url = target else { return false }
        do {
            let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            let data = try isJPEG ? engine.exportJPEG() : engine.exportPNG()
            try data.write(to: url, options: .atomic)
            fileURL = url; engine.markSaved(); syncTitle()
            return true
        } catch { showError(error.localizedDescription); return false }
    }
    func presentResize(scale: Bool) {
        engine.finishEditing(); scaleOnResize = scale; resizePresented = true
    }
    func zoomIn() { engine.zoom = min(8, engine.zoom * 1.25) }
    func zoomOut() { engine.zoom = max(0.125, engine.zoom / 1.25) }
    func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: L10n.tr("OK")); alert.runModal()
    }
}
