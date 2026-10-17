import AppKit
import PaintCore

/// Native menus keep the existing commands available without an automatic SwiftUI window scene.
@MainActor
final class AppMenu {
    private let controller: AppController
    private var actions: [MenuAction] = []

    init(controller: AppController) {
        self.controller = controller
        rebuild()
    }

    func rebuild() {
        actions.removeAll()
        let controller = self.controller
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: L10n.tr(title), action: nil, keyEquivalent: "")
            let menu = NSMenu(title: L10n.tr(title))
            item.submenu = menu; main.addItem(item)
            return menu
        }
        let app = submenu("NahtPaint")
        add("About NahtPaint", to: app) { NSApp.orderFrontStandardAboutPanel(nil) }
        app.addItem(.separator())
        add("Settings…", key: ",", to: app) { controller.showPreferences() }
        app.addItem(.separator())
        let services = NSMenu(title: L10n.tr("Services"))
        let serviceItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        serviceItem.submenu = services; app.addItem(serviceItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        add("Hide NahtPaint", key: "h", to: app) { NSApp.hide(nil) }
        add("Hide Others", key: "h", modifiers: [.command, .option], to: app) { NSApp.hideOtherApplications(nil) }
        add("Show All", to: app) { NSApp.unhideAllApplications(nil) }
        app.addItem(.separator())
        add("Quit NahtPaint", key: "q", to: app) { NSApp.terminate(nil) }

        let file = submenu("File")
        add("New", key: "n", to: file) { controller.newDocument() }
        add("Open…", key: "o", to: file) { controller.openDocument() }
        add("New from Clipboard", key: "n", modifiers: [.command, .shift], to: file) { controller.newFromClipboard() }
        file.addItem(.separator())
        add("Close", key: "w", to: file, enabled: { NSApp.keyWindow != nil }) { NSApp.keyWindow?.performClose(nil) }
        add("Save", key: "s", to: file) { controller.save() }
        add("Save As…", key: "s", modifiers: [.command, .shift], to: file) { controller.save(asNew: true) }

        let edit = submenu("Edit")
        add("Undo", key: "z", to: edit) { controller.undo() }
        add("Redo", key: "z", modifiers: [.command, .shift], to: edit) { controller.redo() }
        edit.addItem(.separator())
        add("Cut", key: "x", to: edit) { controller.cut() }
        add("Copy", key: "c", to: edit) { controller.copy() }
        add("Paste", key: "v", to: edit) { controller.paste() }
        add("Copy Entire Image", key: "c", modifiers: [.command, .shift], to: edit) { controller.copyAll() }
        edit.addItem(.separator())
        add("Select All", key: "a", to: edit) { controller.selectAll() }
        add("Deselect", key: "d", to: edit) { controller.engine.commitSelection() }

        let view = submenu("View")
        add("Zoom In", key: "+", to: view) { controller.zoomIn() }
        add("Zoom Out", key: "-", to: view) { controller.zoomOut() }
        add("Actual Pixels", key: "0", to: view) { controller.engine.zoom = 1 }

        let image = submenu("Image")
        add("Flip Horizontal", to: image, enabled: { controller.engine.canFlipSelection }) { controller.engine.flipSelectionHorizontally() }
        add("Flip Vertical", to: image, enabled: { controller.engine.canFlipSelection }) { controller.engine.flipSelectionVertically() }
        image.addItem(.separator())
        add("Crop to Selection", key: "k", to: image, enabled: { controller.engine.hasSelection }) { controller.engine.cropToSelection() }
        add("Resize Image…", to: image) { controller.presentResize(scale: true) }
        add("Canvas Size…", to: image) { controller.presentResize(scale: false) }

        let windows = submenu("Window")
        add("Minimize", key: "m", to: windows, enabled: { NSApp.keyWindow?.isMiniaturizable == true }) { NSApp.keyWindow?.miniaturize(nil) }
        add("Zoom", to: windows, enabled: { NSApp.keyWindow?.isZoomable == true }) { NSApp.keyWindow?.zoom(nil) }
        windows.addItem(.separator())
        add("Bring All to Front", to: windows) { NSApp.arrangeInFront(nil) }
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                     to menu: NSMenu, enabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        let target = MenuAction(enabled: enabled, action: action)
        actions.append(target)
        let item = NSMenuItem(title: L10n.tr(title), action: #selector(MenuAction.invoke(_:)), keyEquivalent: key)
        item.target = target
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}

@MainActor
private final class MenuAction: NSObject, NSMenuItemValidation {
    let enabled: () -> Bool
    let action: () -> Void
    init(enabled: @escaping () -> Bool, action: @escaping () -> Void) {
        self.enabled = enabled; self.action = action
    }
    @objc func invoke(_ sender: NSMenuItem) { action() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled() }
}
