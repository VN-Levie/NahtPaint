import SwiftUI
import AppKit
import PaintCore
import Combine
import Carbon

@main
@MainActor
enum NahtPaintApp {
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
    private(set) var statusItem: NSStatusItem?
    private var editorKeyMonitor: Any?
    private var preferencesObservation: AnyCancellable?
    private var backgroundLogin = true
    private var startupReady = false
    private var initialLoginLaunch: Bool?
    private var appMenu: AppMenu?
    private var languageObservation: AnyCancellable?
    private var localeObservation: AnyCancellable?
    private var instanceCoordinator: SingleInstanceCoordinating?
    private var startupError: Error?
    private var pendingOpenURLs: [URL] = []
    private var forwardingLaunch = false
    private var secondaryFinished = false
    // Injected only by lifecycle tests; normal launches terminate the empty secondary process.
    var finishSecondaryLaunch: () -> Void = { NSApp.terminate(nil) }

    init(instanceCoordinator: SingleInstanceCoordinating? = nil) {
        self.instanceCoordinator = instanceCoordinator
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avoid appearing in the Dock until the launch reason is known.
        NSApp.setActivationPolicy(.accessory)
        if instanceCoordinator == nil { instanceCoordinator = SingleInstanceCoordinator() }
        do { _ = try instanceCoordinator?.start() }
        catch { startupError = error }
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
        guard !startupReady else { return }
        if let startupError {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Could not start NahtPaint")
            alert.informativeText = startupError.localizedDescription
            alert.runModal()
            completeSecondaryLaunch()
            return
        }
        if instanceCoordinator?.isPrimary == false {
            // Finder file-open events are delivered during startup. Drain them before
            // forwarding, without ever constructing a second status item or editor.
            DispatchQueue.main.async { [weak self] in self?.forwardSecondaryLaunch() }
            return
        }
        EditorWorkspace.shared.onExplicitOpen = { [weak self] in self?.leaveBackgroundLogin() }
        NSApp.appearance = AppPreferences.shared.theme.appearance
        editorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let controller = AppController.shared
            guard let window = controller.window, NSApp.keyWindow === window,
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
        appMenu = AppMenu()
        languageObservation = AppPreferences.shared.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.appMenu?.rebuild() }
        }
        localeObservation = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.appMenu?.rebuild() }
            }
        applyVisibility(AppPreferences.shared.visibility)
        startupReady = true
        if pendingOpenURLs.isEmpty {
            applyInitialOpenEvent()
        } else {
            initialLoginLaunch = nil
            let urls = pendingOpenURLs; pendingOpenURLs.removeAll()
            urls.forEach { EditorWorkspace.shared.openURL($0) }
        }
        instanceCoordinator?.onRequest = { request in
            switch request {
            case .showWindow: AppController.shared.showWindow()
            case .openURLs(let urls): urls.forEach { EditorWorkspace.shared.openURL($0) }
            }
        }
    }

    func forwardSecondaryLaunch() {
        guard let coordinator = instanceCoordinator, !coordinator.isPrimary,
              !forwardingLaunch, !secondaryFinished else { return }
        if initialLoginLaunch == true && pendingOpenURLs.isEmpty {
            completeSecondaryLaunch(); return
        }
        let urls = pendingOpenURLs; pendingOpenURLs.removeAll()
        let request: SingleInstanceCoordinator.Request = urls.isEmpty ? .showWindow : .openURLs(urls)
        forwardingLaunch = true
        coordinator.forward(request) { [weak self] accepted in
            guard let self else { return }
            self.forwardingLaunch = false
            if accepted {
                if self.pendingOpenURLs.isEmpty { self.completeSecondaryLaunch() }
                else { self.forwardSecondaryLaunch() }
                return
            }
            // The owner can exit between discovery and delivery. Reacquire ownership
            // before declaring failure; never kill or replace the existing process.
            coordinator.invalidate()
            do {
                if try coordinator.start() {
                    self.pendingOpenURLs = urls + self.pendingOpenURLs
                    self.initialLoginLaunch = urls.isEmpty ? false : nil
                    self.finishLaunching()
                    return
                }
            } catch { self.startupError = error }
            let alert = NSAlert()
            alert.messageText = L10n.tr("Could not open the request in the running NahtPaint")
            alert.informativeText = L10n.tr("Try again from its menu bar.")
            alert.runModal()
            self.completeSecondaryLaunch()
        }
    }
    private func completeSecondaryLaunch() {
        guard !secondaryFinished else { return }
        secondaryFinished = true
        finishSecondaryLaunch()
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
                ?? NSImage(systemSymbolName: "n.square", accessibilityDescription: "NahtPaint")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.toolTip = "NahtPaint"
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
        let open = menu.addItem(withTitle: L10n.tr("Open NahtPaint"), action: #selector(openEditor), keyEquivalent: "")
        open.target = self
        let newWindow = menu.addItem(withTitle: L10n.tr("New Window"), action: #selector(newEditor), keyEquivalent: "")
        newWindow.target = self
        let paste = menu.addItem(withTitle: L10n.tr("New from Clipboard"), action: #selector(clipboardDocument), keyEquivalent: "")
        paste.target = self
        let documents = EditorWorkspace.shared.documents
        if !documents.isEmpty {
            menu.addItem(.separator())
            for (index, document) in documents.enumerated() {
                let title = document.displayName + (document.engine.isDirty ? " •" : "")
                let entry = menu.addItem(withTitle: title, action: #selector(showDocument(_:)), keyEquivalent: "")
                entry.target = self; entry.tag = index
                entry.state = document.window?.isVisible == true ? .on : .off
            }
        }
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
        let quit = menu.addItem(withTitle: L10n.tr("Quit NahtPaint"), action: #selector(quitApp), keyEquivalent: "")
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
    @objc private func newEditor() { EditorWorkspace.shared.newDocument() }
    @objc private func showDocument(_ sender: NSMenuItem) {
        let documents = EditorWorkspace.shared.documents
        guard documents.indices.contains(sender.tag) else { return }
        documents[sender.tag].showWindow()
    }
    @objc private func clipboardDocument() { AppController.shared.newFromClipboard() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinator?.invalidate()
        if let editorKeyMonitor { NSEvent.removeMonitor(editorKeyMonitor) }
        preferencesObservation = nil
        languageObservation = nil
        localeObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if instanceCoordinator?.isPrimary == false || startupError != nil { return .terminateNow }
        let canQuit = EditorWorkspace.shared.confirmQuit(clearAutomatically: AppPreferences.shared.clearCanvasOnCloseOrQuit) { document in
            document.showWindow()
            return document.confirmDiscard()
        }
        return canQuit ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if instanceCoordinator?.isPrimary == false {
            initialLoginLaunch = false
            forwardSecondaryLaunch()
            return false
        }
        guard startupReady else { initialLoginLaunch = false; return false }
        AppController.shared.showWindow(); return false
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard startupReady else { pendingOpenURLs.append(contentsOf: urls); return }
        urls.forEach { EditorWorkspace.shared.openURL($0) }
    }
}
