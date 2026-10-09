import Foundation

/// Follow the user's primary system (or per-app) language. All Chinese variants
/// use Simplified Chinese; other languages fall back to English.
struct AppLocalization {
    let language: String
    private let localizedBundle: Bundle

    init(bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages, languageOverride: String? = nil) {
        let primary = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "en"
        language = ["en", "zh-Hans"].contains(languageOverride ?? "")
            ? languageOverride!
            : (primary == "zh" || primary.hasPrefix("zh-") ? "zh-Hans" : "en")
        let path = bundle.path(forResource: language, ofType: "lproj")
            ?? bundle.path(forResource: "en", ofType: "lproj")
        localizedBundle = path.flatMap(Bundle.init(path:)) ?? bundle
    }

    func text(_ key: String, arguments: [String] = []) -> String {
        let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments.map { $0 as CVarArg })
    }
}

enum LanguagePreference {
    static let key = "interfaceLanguage"
    static let values = ["system", "zh-Hans", "en"]
}

private var appLocalization = AppLocalization(languageOverride: UserDefaults.standard.string(forKey: LanguagePreference.key))

func reloadLocalization() {
    appLocalization = AppLocalization(languageOverride: UserDefaults.standard.string(forKey: LanguagePreference.key))
}

func L(_ key: String, _ arguments: Any...) -> String {
    appLocalization.text(key, arguments: arguments.map { String(describing: $0) })
}
