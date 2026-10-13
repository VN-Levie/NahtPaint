import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    public var id: String { rawValue }
    public var nativeName: String {
        switch self {
        case .system: return L10n.tr("System")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        for preferred in Locale.preferredLanguages {
            let code = preferred.lowercased()
            if code.hasPrefix("en") { return .english }
            if code.hasPrefix("vi") { return .vietnamese }
            if code.hasPrefix("zh") { return .simplifiedChinese }
            if code.hasPrefix("ja") { return .japanese }
        }
        return .english
    }
    public var locale: Locale { Locale(identifier: resolved.rawValue) }
    public static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .english
    }
}

public enum L10n {
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return (language, bundle)
    })

    /// English source strings are stable keys, and English is the explicit first-launch default.
    public static func tr(_ source: String, _ arguments: CVarArg...) -> String {
        let language = AppLanguage.current.resolved
        let translated = bundles[language]?.localizedString(forKey: source, value: source, table: nil) ?? source
        guard !arguments.isEmpty else { return translated }
        return String(format: translated, locale: language.locale, arguments: arguments)
    }
}
