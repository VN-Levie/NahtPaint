import AppKit
import SwiftUI
import PaintCore

public enum AppVisibility: String, CaseIterable, Identifiable {
    case both, dockOnly, menuBarOnly
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return L10n.tr("Dock + menu bar")
        case .dockOnly: return L10n.tr("Dock only")
        case .menuBarOnly: return L10n.tr("Menu bar only")
        }
    }
    var showsDock: Bool { self != .menuBarOnly }
    var showsMenuBar: Bool { self != .dockOnly }
}

enum QuickOpenMode: String, CaseIterable, Identifiable {
    case menuOnly, singleClick
    var id: String { rawValue }
    var title: String {
        switch self {
        case .singleClick: return L10n.tr("Single-click")
        case .menuOnly: return L10n.tr("Menu only")
        }
    }
    var hint: String {
        switch self {
        case .singleClick: return L10n.tr("Click to open NathPaint. Right-click for the menu.")
        case .menuOnly: return L10n.tr("Click for the menu, then choose Open NathPaint.")
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.tr("System")
        case .light: return L10n.tr("Light")
        case .dark: return L10n.tr("Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
            NSApp.appearance = theme.appearance
        }
    }
    @Published var language: AppLanguage {
        willSet { if newValue != language { AppController.shared.engine.finishEditing() } }
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }
    @Published var visibility: AppVisibility {
        didSet { UserDefaults.standard.set(visibility.rawValue, forKey: "appVisibility") }
    }
    @Published var quickOpen: QuickOpenMode {
        didSet { UserDefaults.standard.set(quickOpen.rawValue, forKey: "quickOpen") }
    }
    @Published var imagePasteMode: ImagePasteMode {
        didSet { UserDefaults.standard.set(imagePasteMode.rawValue, forKey: "imagePasteMode") }
    }
    @Published var fitViewAfterPasting: Bool {
        didSet { UserDefaults.standard.set(fitViewAfterPasting, forKey: "fitViewAfterPasting") }
    }
    @Published var clearCanvasOnCloseOrQuit: Bool {
        didSet {
            UserDefaults.standard.set(clearCanvasOnCloseOrQuit, forKey: "clearCanvasOnCloseOrQuit")
            UserDefaults.standard.set(true, forKey: "didChooseCanvasCloseBehavior")
        }
    }
    var needsInitialCanvasChoice: Bool {
        !UserDefaults.standard.bool(forKey: "didChooseCanvasCloseBehavior")
    }
    private init() {
        clearCanvasOnCloseOrQuit = UserDefaults.standard.bool(forKey: "clearCanvasOnCloseOrQuit")
        imagePasteMode = ImagePasteMode(rawValue: UserDefaults.standard.string(forKey: "imagePasteMode") ?? "") ?? .automatic
        fitViewAfterPasting = UserDefaults.standard.object(forKey: "fitViewAfterPasting") as? Bool ?? true
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .system
        language = AppLanguage.current
        quickOpen = QuickOpenMode(rawValue: UserDefaults.standard.string(forKey: "quickOpen") ?? "") ?? .menuOnly
        if UserDefaults.standard.string(forKey: "quickOpen") == "doubleClick" {
            UserDefaults.standard.set(QuickOpenMode.menuOnly.rawValue, forKey: "quickOpen")
        }
        visibility = AppVisibility(rawValue: UserDefaults.standard.string(forKey: "appVisibility") ?? "") ?? .both
    }
}

struct PreferencesView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        Form {
            Picker(L10n.tr("Language"), selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { language in Text(language.nativeName).tag(language) }
            }
            Picker(L10n.tr("Appearance"), selection: $preferences.theme) {
                ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme) }
            }.pickerStyle(.segmented)
            Divider().padding(.vertical, 4)
            Picker(L10n.tr("Pasting large images"), selection: $preferences.imagePasteMode) {
                ForEach(ImagePasteMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            if preferences.imagePasteMode == .automatic {
                Text(L10n.tr("Automatic fits moderately larger images and expands the canvas for much larger images."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L10n.tr("Fit view after pasting"), isOn: $preferences.fitViewAfterPasting)
            Text(L10n.tr("New empty canvases match the first pasted image."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle(L10n.tr("Clear canvas on close or quit"), isOn: $preferences.clearCanvasOnCloseOrQuit)
            Text(L10n.tr("Discard unsaved changes without asking."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Picker(L10n.tr("Show NathPaint in"), selection: $preferences.visibility) {
                ForEach(AppVisibility.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.radioGroup)
            if preferences.visibility.showsMenuBar {
                Picker(L10n.tr("Quick Open"), selection: $preferences.quickOpen) {
                    ForEach(QuickOpenMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.radioGroup)
                Text(preferences.quickOpen.hint)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24).frame(width: 420)
        .environment(\.locale, preferences.language.locale)
        .preferredColorScheme(preferences.theme.colorScheme)
    }
}
