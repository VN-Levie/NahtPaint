import SwiftUI
import AppKit
import PaintCore
import Combine

@main
struct NathPaintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = AppController.shared
    @ObservedObject private var preferences = AppPreferences.shared

    var body: some Scene {
        Window("NathPaint", id: "editor") {
            EditorView(controller: controller, engine: controller.engine)
                .frame(minWidth: 760, minHeight: 540)
                .background(WindowReader(controller: controller))
                .preferredColorScheme(preferences.theme.colorScheme)
                .environment(\.locale, preferences.language.locale)
        }
        .defaultSize(width: 1160, height: 820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("Settings…")) { controller.showPreferences() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("New")) { controller.newDocument() }.keyboardShortcut("n")
                Button(L10n.tr("Open…")) { controller.openDocument() }.keyboardShortcut("o")
                Button(L10n.tr("New from Clipboard")) { controller.newFromClipboard() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.tr("Save")) { controller.save() }.keyboardShortcut("s")
                Button(L10n.tr("Save As…")) { controller.save(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L10n.tr("Undo")) { controller.undo() }.keyboardShortcut("z")
                Button(L10n.tr("Redo")) { controller.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button(L10n.tr("Cut")) { controller.cut() }.keyboardShortcut("x")
                Button(L10n.tr("Copy")) { controller.copy() }.keyboardShortcut("c")
                Button(L10n.tr("Paste")) { controller.paste() }.keyboardShortcut("v")
                Button(L10n.tr("Copy Entire Image")) { controller.copyAll() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button(L10n.tr("Select All")) { controller.selectAll() }.keyboardShortcut("a")
                Button(L10n.tr("Deselect")) { controller.engine.commitSelection() }.keyboardShortcut("d")
            }
            CommandMenu(L10n.tr("Image")) {
                Button(L10n.tr("Crop to Selection")) { controller.engine.cropToSelection() }
                    .keyboardShortcut("k").disabled(!controller.engine.hasSelection)
                Button(L10n.tr("Resize Image…")) { controller.presentResize(scale: true) }
                Button(L10n.tr("Canvas Size…")) { controller.presentResize(scale: false) }
            }
            CommandGroup(after: .toolbar) {
                Button(L10n.tr("Zoom In")) { controller.zoomIn() }.keyboardShortcut("+")
                Button(L10n.tr("Zoom Out")) { controller.zoomOut() }.keyboardShortcut("-")
                Button(L10n.tr("Actual Pixels")) { controller.engine.zoom = 1 }.keyboardShortcut("0")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var editorKeyMonitor: Any?
    private var preferencesObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppPreferences.shared.theme.appearance
        editorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let controller = AppController.shared
            guard NSApp.keyWindow === controller.window,
                  !event.modifierFlags.contains(.option) else { return event }
            let command = event.modifierFlags.contains(.command)
            let control = event.modifierFlags.contains(.control)
            if !command && !control && [51, 117].contains(event.keyCode) {
                return controller.deleteCanvasSelection() ? nil : event
            }
            let controlSelectAll = control && !command &&
                (event.charactersIgnoringModifiers?.lowercased() == "a" || event.keyCode == 0)
            guard (command && !control) || controlSelectAll else { return event }
            // Route editor shortcuts before SwiftUI/AppKit responder handoff. Some
            // input sources produce non-Latin characters while Command is held.
            let hardwareKeys: [UInt16: String] = [0: "a", 8: "c", 9: "v", 7: "x", 6: "z", 16: "y", 2: "d", 45: "n", 31: "o", 1: "s", 40: "k", 43: ","]
            let supported = Set(["a", "c", "v", "x", "z", "y", "d", "n", "o", "s", "k", ","])
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let key = controlSelectAll ? "a" : (supported.contains(characters) ? characters : (hardwareKeys[event.keyCode] ?? characters))
            let shift = event.modifierFlags.contains(.shift)
            switch key {
            case "a": controller.selectAll()
            case "c": shift ? controller.copyAll() : controller.copy()
            case "v": controller.paste()
            case "x": controller.cut()
            case "z": shift ? controller.redo() : controller.undo()
            case "y": controller.redo()
            case "d": controller.engine.commitSelection()
            case "n": shift ? controller.newFromClipboard() : controller.newDocument()
            case "o": controller.openDocument()
            case "s": controller.save(asNew: shift)
            case "k": controller.engine.cropToSelection()
            case ",": controller.showPreferences()
            default: return event
            }
            return nil
        }
        preferencesObservation = AppPreferences.shared.$visibility.sink { [weak self] mode in
            DispatchQueue.main.async { self?.applyVisibility(mode) }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { AppController.shared.presentInitialCanvasChoiceIfNeeded() }
    }

    private func applyVisibility(_ mode: AppVisibility) {
        NSApp.setActivationPolicy(mode.showsDock ? .regular : .accessory)
        if mode.showsMenuBar {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "n.square", accessibilityDescription: "NathPaint")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.toolTip = "NathPaint"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showMenu(); return }
        switch AppPreferences.shared.quickOpen {
        case .singleClick: AppController.shared.showWindow(); return
        case .menuOnly: showMenu(); return
        }
    }

    private func showMenu() {
        guard let item = statusItem, let button = item.button else { return }
        let menu = NSMenu()
        let open = menu.addItem(withTitle: L10n.tr("Open NathPaint"), action: #selector(openEditor), keyEquivalent: "")
        open.target = self
        let paste = menu.addItem(withTitle: L10n.tr("New from Clipboard"), action: #selector(clipboardDocument), keyEquivalent: "")
        paste.target = self
        menu.addItem(.separator())
        let visibility = NSMenuItem(title: L10n.tr("Show App In"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, mode) in AppVisibility.allCases.enumerated() {
            let option = submenu.addItem(withTitle: mode.title, action: #selector(changeVisibility(_:)), keyEquivalent: "")
            option.target = self; option.tag = index
            option.state = AppPreferences.shared.visibility == mode ? .on : .off
        }
        visibility.submenu = submenu; menu.addItem(visibility)
        let quickOpen = NSMenuItem(title: L10n.tr("Quick Open"), action: nil, keyEquivalent: "")
        let quickMenu = NSMenu()
        for (index, mode) in QuickOpenMode.allCases.enumerated() {
            let option = quickMenu.addItem(withTitle: mode.title, action: #selector(changeQuickOpen(_:)), keyEquivalent: "")
            option.target = self; option.tag = index
            option.state = AppPreferences.shared.quickOpen == mode ? .on : .off
        }
        quickOpen.submenu = quickMenu; menu.addItem(quickOpen)
        let settings = menu.addItem(withTitle: L10n.tr("Settings…"), action: #selector(openPreferences), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.tr("Quit NathPaint"), action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    @objc private func changeVisibility(_ sender: NSMenuItem) {
        AppPreferences.shared.visibility = AppVisibility.allCases[sender.tag]
    }
    @objc private func changeQuickOpen(_ sender: NSMenuItem) {
        AppPreferences.shared.quickOpen = QuickOpenMode.allCases[sender.tag]
    }
    @objc private func openPreferences() { AppController.shared.showPreferences() }
    @objc private func openEditor() { AppController.shared.showWindow() }
    @objc private func clipboardDocument() { AppController.shared.showWindow(); AppController.shared.newFromClipboard() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let editorKeyMonitor { NSEvent.removeMonitor(editorKeyMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppPreferences.shared.clearCanvasOnCloseOrQuit {
            AppController.shared.clearCanvas()
            return .terminateNow
        }
        return AppController.shared.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.showWindow(); return false
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppController.shared.openURL(url) }
    }
}

struct WindowReader: NSViewRepresentable {
    let controller: AppController
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { controller.attach(window) } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
