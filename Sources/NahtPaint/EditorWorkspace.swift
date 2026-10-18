import AppKit
import PaintCore

/// A process owns the menu bar item; each editor owns its document and undo history.
@MainActor
final class EditorWorkspace {
    static let shared = EditorWorkspace()
    private(set) var documents: [AppController] = []
    private weak var lastActive: AppController?
    var onExplicitOpen: (() -> Void)?

    var activeController: AppController {
        if let document = controller(for: NSApp?.keyWindow) { return document }
        if let lastActive { return lastActive }
        return documents.first ?? makeDocument()
    }

    func controller(for window: NSWindow?) -> AppController? {
        guard let window else { return nil }
        return documents.first { $0.window === window }
    }

    func activate(_ document: AppController) {
        guard documents.contains(where: { $0 === document }) else { return }
        lastActive = document
    }

    @discardableResult
    func makeDocument() -> AppController {
        let document = AppController()
        document.workspace = self
        document.documentNumber = documents.count + 1
        documents.append(document)
        lastActive = document
        return document
    }

    @discardableResult
    func newDocument(show: Bool = true) -> AppController {
        let previousWindow = lastActive?.window
        let document = makeDocument()
        if show {
            document.showWindow()
            if let previousWindow {
                document.window?.cascadeTopLeft(from: CGPoint(x: previousWindow.frame.minX + 24,
                                                              y: previousWindow.frame.maxY - 24))
            }
        }
        return document
    }

    @discardableResult
    func openImage(_ image: NSImage, url: URL? = nil, unsaved: Bool = false, show: Bool = true) throws -> AppController {
        // Validate before registering a document, so failed imports leave all windows intact.
        let document: AppController
        if documents.count == 1, let first = documents.first,
           first.window == nil, first.fileURL == nil, !first.engine.isDirty {
            document = first
        } else {
            document = AppController()
        }
        try document.engine.loadImage(image)
        document.fileURL = url
        if unsaved { document.engine.markUnsaved() }
        if !documents.contains(where: { $0 === document }) {
            document.workspace = self
            document.documentNumber = documents.count + 1
            documents.append(document)
        }
        activate(document)
        if show { document.showWindow() }
        return document
    }

    func openURL(_ url: URL) {
        guard url.isFileURL, let image = NSImage(contentsOf: url), image.isValid else {
            activeController.showError(L10n.tr("This file could not be opened as an image.")); return
        }
        do { try openImage(image, url: url) }
        catch { activeController.showError(error.localizedDescription) }
    }

    func finishEditing() { documents.forEach { $0.engine.finishEditing() } }

    func confirmQuit(clearAutomatically: Bool, confirm: (AppController) -> Bool) -> Bool {
        finishEditing()
        // Quit releases documents; don't clear earlier windows if a later prompt is cancelled.
        if clearAutomatically { return true }
        return documents.filter { $0.engine.isDirty }.allSatisfy(confirm)
    }
}
