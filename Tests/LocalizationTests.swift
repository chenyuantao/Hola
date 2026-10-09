import Foundation

@main
struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let appBundle = Bundle(url: root.appendingPathComponent("build/Hola.app")) else {
            fatalError("Build Hola.app before running localization tests.")
        }
        let cases: [([String], String)] = [
            (["en-US"], "en"), (["en-GB", "zh-Hans"], "en"),
            (["zh"], "zh-Hans"), (["zh-CN"], "zh-Hans"),
            (["zh-Hans-CN"], "zh-Hans"), (["zh-Hant-TW"], "zh-Hans"),
            (["zh_HK"], "zh-Hans"), (["fr-FR", "zh-Hans"], "en"), ([], "en")
        ]
        for (preferences, expected) in cases {
            let localization = AppLocalization(bundle: appBundle, preferredLanguages: preferences)
            precondition(localization.language == expected, "Wrong language for \(preferences)")
            precondition(localization.text("设置") == (expected == "en" ? "Settings" : "设置"))
        }
        for override in ["en", "zh-Hans"] {
            let localization = AppLocalization(bundle: appBundle, preferredLanguages: ["zh-TW"], languageOverride: override)
            precondition(localization.language == override)
        }
        for override in ["system", "invalid"] {
            precondition(AppLocalization(bundle: appBundle, preferredLanguages: ["en"], languageOverride: override).language == "en")
        }
        func catalog(_ url: URL) throws -> [String: String] {
            let data = try Data(contentsOf: url)
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        }
        let english = try catalog(root.appendingPathComponent("Resources/en.lproj/Localizable.strings"))
        let chinese = try catalog(root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"))
        precondition(Set(english.keys) == Set(chinese.keys), "Translation keys must match")
        let formatPattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?@"#)
        func placeholders(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return formatPattern.matches(in: text, range: range).map {
                String(text[Range($0.range, in: text)!])
            }.sorted()
        }
        let en = AppLocalization(bundle: appBundle, preferredLanguages: ["en"])
        let zh = AppLocalization(bundle: appBundle, preferredLanguages: ["zh-Hans"])
        for (key, value) in english {
            precondition(!value.isEmpty)
            precondition(value.range(of: #"\p{Han}"#, options: .regularExpression) == nil,
                         "Untranslated English value: \(key)")
            precondition(placeholders(value) == placeholders(chinese[key]!))
            precondition(en.text(key) == value, "English bundle resource missing or stale: \(key)")
            precondition(zh.text(key) == chinese[key], "Chinese bundle resource missing or stale: \(key)")
        }
        // Dynamic values must remain intact, including punctuation and user text containing %.
        precondition(en.text("共 %1$@ 条，进行中 %2$@ 条 · 已保存到本地", arguments: ["12", "3"])
                     == "Records: 12 · In progress: 3 · Saved locally")
        precondition(zh.text("共 %1$@ 条，进行中 %2$@ 条 · 已保存到本地", arguments: ["12", "3"])
                     == "共 12 条，进行中 3 条 · 已保存到本地")
        precondition(en.text("接口错误：%1$@", arguments: ["100% / 你好 / %@"])
                     == "API error: 100% / 你好 / %@")
        precondition(en.text("润色中（Jev %1$@）…", arguments: ["95%"])
                     == "Polishing (Jev 95%)…")
        precondition(en.text("unknown.key") == "unknown.key")
        // Every call site must have a resource entry, including nested messages.
        let source = try ["Sources/main.swift", "Sources/Settings.swift"].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        let calls = try NSRegularExpression(pattern: #"\bL\(("(?:\\.|[^"\\])*")"#)
        for match in calls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let literal = String(source[Range(match.range(at: 1), in: source)!])
            let key = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
            precondition(english[key] != nil, "Missing localization: \(key)")
        }
        print("Passed: \(cases.count) language selections, \(english.count) bilingual entries, bundled resources, dynamic formats, and call-site coverage.")
    }
}
