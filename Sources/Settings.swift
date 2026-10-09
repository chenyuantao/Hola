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
    static let oaExtraParameters = "openAIExtraParameters"
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
    SettingKey.oaURL, SettingKey.oaToken, SettingKey.oaModel, SettingKey.oaPrompt, SettingKey.oaExtraParameters
]

func extraRequestParameters(_ raw: String) throws -> [String: Any] {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeError(L("额外请求参数必须是 JSON 对象"))
    }
    guard object["model"] == nil, object["messages"] == nil else {
        throw ProbeError(L("额外请求参数不能包含 model 或 messages"))
    }
    if let stream = object["stream"] {
        guard let flag = stream as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else {
            throw ProbeError(L("当前仅支持 stream: false"))
        }
    }
    return object
}

private func usesDefaultReasoningEffort(_ model: String) -> Bool {
    let name = model.lowercased()
    return ["gpt-5", "gpt-6", "o3", "o4"].contains { family in
        name == family || name.hasPrefix(family + "-") || name.hasPrefix(family + ".")
    } && !name.contains("-chat-")
}

func chatCompletionBody(model: String, system: String, user: String, extraParameters: String) throws -> [String: Any] {
    var body = try extraRequestParameters(extraParameters)
    if usesDefaultReasoningEffort(model), body["reasoning_effort"] == nil {
        body["reasoning_effort"] = "low"
    }
    if body["stream"] == nil { body["stream"] = false }
    body["messages"] = [["role": "system", "content": system], ["role": "user", "content": user]]
    if !model.isEmpty { body["model"] = model }
    return body
}

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
    if let raw = values[SettingKey.oaExtraParameters] {
        _ = try extraRequestParameters(raw)
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
