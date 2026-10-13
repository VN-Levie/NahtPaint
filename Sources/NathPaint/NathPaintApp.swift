import SwiftUI
import AppKit
import PaintCore
import Combine
import Carbon

@main
@MainActor
enum NathPaintApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // AppKit owns the lifecycle so no SwiftUI scene can open a window at login.
        // The editor and preferences are still SwiftUI views hosted by AppController.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var editorKeyMonitor: Any?
    private var preferencesObservation: AnyCancellable?
    private var backgroundLogin = true
    private var startupReady = false
    private var initialLoginLaunch: Bool?
    private var appMenu: AppMenu?
    private var languageObservation: AnyCancellable?
    private var localeObservation: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avoid appearing in the Dock until the launch reason is known.
        NSApp.setActivationPolicy(.accessory)
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(handleOpenApplication(_:withReplyEvent:)),
            forEventClass: kCoreEventClass, andEventID: kAEOpenApplication)
    }

    @objc func handleOpenApplication(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        // Apple-event descriptors are temporary; persist the value, not the descriptor.
        initialLoginLaunch = LaunchContext.isLoginLaunch(event)
        if startupReady { applyInitialOpenEvent() }
    }

    private func applyInitialOpenEvent() {
        guard let isLogin = initialLoginLaunch else { return }
        initialLoginLaunch = nil
        backgroundLogin = isLogin
        applyVisibility(AppPreferences.shared.visibility)
        if !backgroundLogin {
            AppController.shared.showWindow()
            DispatchQueue.main.async { AppController.shared.presentInitialCanvasChoiceIfNeeded() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishLaunching()
    }

    func finishLaunching() {
        AppController.shared.onExplicitOpen = { [weak self] in self?.leaveBackgroundLogin() }
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
        appMenu = AppMenu(controller: AppController.shared)
        languageObservation = AppPreferences.shared.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.appMenu?.rebuild() }
        }
        localeObservation = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.appMenu?.rebuild() }
            }
        applyVisibility(AppPreferences.shared.visibility)
        startupReady = true
        applyInitialOpenEvent()
    }

    private func applyVisibility(_ mode: AppVisibility) {
        let effectiveMode = backgroundLogin ? AppVisibility.menuBarOnly : mode
        NSApp.setActivationPolicy(effectiveMode.showsDock ? .regular : .accessory)
        if effectiveMode.showsMenuBar {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func leaveBackgroundLogin() {
        guard backgroundLogin else { return }
        backgroundLogin = false
        applyVisibility(AppPreferences.shared.visibility)
        DispatchQueue.main.async { AppController.shared.presentInitialCanvasChoiceIfNeeded() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        LoginItemController.shared.refresh()
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
        preferencesObservation = nil
        languageObservation = nil
        localeObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
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
