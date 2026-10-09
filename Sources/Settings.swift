import Foundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
// 配置项保存在 UserDefaults；导出配置时会包含接口 Token。
enum SettingKey {
    static let resumeRunning = "resumeRunning"
    static let targets = "targetApplications"
    static let jevEnabled = "jevEnabled"
    static let jevURL = "jevURL"
    static let jevToken = "jevToken"
    static let jevModel = "jevModel"
    static let jevPrompt = "jevPrompt"
    static let oaURL = "openAIURL"
    static let oaToken = "openAIToken"
    static let oaModel = "openAIModel"
    static let oaPrompt = "openAIPrompt"
}
func setting(_ key: String, _ fallback: String = "") -> String {
    let v = UserDefaults.standard.string(forKey: key) ?? ""
    return v.isEmpty ? fallback : v
}
func setSetting(_ key: String, _ value: String) { UserDefaults.standard.set(value, forKey: key) }

private let settingsFileKind = "hola-settings"
private let settingsFileVersion = 1
private let portableSettingKeys = [
    LanguagePreference.key, SettingKey.targets, SettingKey.jevEnabled, SettingKey.jevURL, SettingKey.jevToken, SettingKey.jevModel, SettingKey.jevPrompt,
    SettingKey.oaURL, SettingKey.oaToken, SettingKey.oaModel, SettingKey.oaPrompt
]

// 旧标识仅用于升级兼容；所有新配置与历史均使用 Hola 标识。
func migrateLegacyData() {
    let defaults = UserDefaults.standard
    let marker = "holaLegacySettingsMigrated"
    if !defaults.bool(forKey: marker) {
        let existing = defaults.persistentDomain(forName: "local.hola") ?? [:]
        let legacy = defaults.persistentDomain(forName: "local.happy-talk") ?? [:]
        for key in portableSettingKeys where existing[key] == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
    let manager = FileManager.default
    guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let source = base.appendingPathComponent("local.happy-talk/round-history.json")
    let folder = base.appendingPathComponent("local.hola", isDirectory: true)
    let destination = folder.appendingPathComponent("round-history.json")
    guard !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: source.path) else { return }
    do {
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.copyItem(at: source, to: destination)
    } catch {
        NSLog(L("Hola: 旧版调用历史迁移失败：%@"), error.localizedDescription)
    }
}

func encodeSettingsFile(_ values: [String: String]) throws -> Data {
    let payload: [String: Any] = [
        "kind": settingsFileKind,
        "version": settingsFileVersion,
        "settings": values
    ]
    return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
}

func decodeSettingsFile(_ data: Data) throws -> [String: String] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError(L("配置文件不是 JSON 对象"))
    }
    guard let kind = root["kind"] as? String,
          [settingsFileKind, "happy-talk-settings"].contains(kind) else {
        throw ProbeError(L("这不是 Hola 配置文件"))
    }
    guard let version = root["version"] as? Int, version >= 1, version <= settingsFileVersion else {
        throw ProbeError(L("不支持的配置文件版本"))
    }
    guard let settings = root["settings"] as? [String: Any] else {
        throw ProbeError(L("配置文件缺少 settings"))
    }
    for key in [SettingKey.targets, LanguagePreference.key] where settings[key] != nil {
        guard settings[key] is String else {
            throw ProbeError(L("配置文件中的设置格式无效"))
        }
    }
    var values: [String: String] = [:]
    for key in portableSettingKeys {
        if let value = settings[key] as? String { values[key] = value }
    }
    guard !values.isEmpty else { throw ProbeError(L("配置文件里没有可识别的配置项")) }
    if let language = values[LanguagePreference.key], !LanguagePreference.values.contains(language) {
        throw ProbeError(L("配置文件中的语言无效"))
    }
    if let rawTargets = values[SettingKey.targets] {
        guard let data = rawTargets.data(using: .utf8),
              let targets = try? JSONDecoder().decode([TargetApplication].self, from: data),
              targets.allSatisfy({ !$0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(targets.map(\.bundleID)).count == targets.count else {
            throw ProbeError(L("配置文件中的 Apps 列表无效"))
        }
    }
    return values
}

struct TargetApplication: Codable {
    let name: String
    let bundleID: String
    let path: String
}
func configuredTargets() -> [TargetApplication] {
    guard let data = setting(SettingKey.targets).data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([TargetApplication].self, from: data)) ?? []
}
func targetSettingsValue(_ targets: [TargetApplication]) -> String {
    guard let data = try? JSONEncoder().encode(targets) else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
}
func jevEnabled() -> Bool { setting(SettingKey.jevEnabled) == "true" }

