import Foundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
// 配置项保存在 UserDefaults；导出配置时会包含接口 Token。
enum SettingKey {
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
    static let commands = "commands"
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
    SettingKey.oaURL, SettingKey.oaToken, SettingKey.oaModel, SettingKey.oaPrompt, SettingKey.oaExtraParameters,
    SettingKey.commands
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

// 发布版保留旧品牌迁移；开发版首次复制现有配置，之后独立保存。
func migrateLegacyData() {
    let defaults = UserDefaults.standard
    if Bundle.main.bundleIdentifier == "local.holadev" {
        let marker = "holaDevSettingsMigrated"
        if !defaults.bool(forKey: marker) {
            let existing = defaults.persistentDomain(forName: "local.holadev") ?? [:]
            let source = defaults.persistentDomain(forName: "local.hola") ?? [:]
            for key in portableSettingKeys where existing[key] == nil {
                if let value = source[key] { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: marker)
        }
        return
    }
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
    for key in [SettingKey.targets, LanguagePreference.key, SettingKey.commands] where settings[key] != nil {
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
              validTargetApplications(targets) else {
            throw ProbeError(L("配置文件中的 Apps 列表无效"))
        }
    }
    if let raw = values[SettingKey.oaExtraParameters] {
        _ = try extraRequestParameters(raw)
    }
    if let raw = values[SettingKey.commands] { _ = try decodeCommands(raw) }
    return values
}

enum HijackScope: String, Codable {
    case all
    case partial
}

enum ComponentHijackDecision: String, Codable {
    case allow
    case deny
}

struct ComponentPermission: Codable, Equatable {
    var id: String
    var label: String
    var decision: ComponentHijackDecision
}

struct ComponentSignature: Equatable {
    let id: String
    let label: String
}

struct TargetApplication: Codable, Equatable {
    let name: String
    let bundleID: String
    let path: String
    var hijackScope: HijackScope
    var components: [ComponentPermission]

    init(name: String, bundleID: String, path: String, hijackScope: HijackScope = .all, components: [ComponentPermission] = []) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.hijackScope = hijackScope
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case name, bundleID, path, hijackScope, components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        path = try container.decode(String.self, forKey: .path)
        hijackScope = try container.decodeIfPresent(HijackScope.self, forKey: .hijackScope) ?? .all
        components = try container.decodeIfPresent([ComponentPermission].self, forKey: .components) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(path, forKey: .path)
        try container.encode(hijackScope, forKey: .hijackScope)
        try container.encode(components, forKey: .components)
    }
}

private func validTargetApplications(_ targets: [TargetApplication]) -> Bool {
    let ids = targets.map { $0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { return false }
    return targets.allSatisfy { app in
        let componentIDs = app.components.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
        return componentIDs.allSatisfy { !$0.isEmpty } && Set(componentIDs).count == componentIDs.count
    }
}

private func stableComponentToken(_ raw: String, limit: Int, dropIfTooLong: Bool) -> String {
    let flattened = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.count <= limit { return trimmed }
    return dropIfTooLong ? "" : String(trimmed.prefix(limit))
}

func makeComponentSignature(
    role: String,
    subrole: String,
    identifier: String,
    title: String,
    placeholder: String,
    description: String,
    value: String,
    treePosition: String
) -> ComponentSignature {
    let ident = stableComponentToken(identifier, limit: 80, dropIfTooLong: true)
    let place = stableComponentToken(placeholder, limit: 80, dropIfTooLong: true)
    let current = stableComponentToken(value, limit: 500, dropIfTooLong: false)
    let desc = stableComponentToken(description, limit: 80, dropIfTooLong: true)
    let heading = stableComponentToken(title, limit: 80, dropIfTooLong: true)
    let stableDescription = desc == current ? "" : desc
    let stableTitle = heading == current ? "" : heading
    // 唯一 ID 只用组件在窗口里的树位置。标题、占位符、标识和当前文本都会变，不能拿来对上次的选择。
    let position = treePosition.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = [role, subrole].filter { !$0.isEmpty }.joined(separator: "#")
    let id = position.isEmpty ? (fallback.isEmpty ? "AXTextField" : fallback) : position
    return ComponentSignature(id: id, label: componentFieldLabel(
        role: role, subrole: subrole, identifier: ident, title: stableTitle, placeholder: place, description: stableDescription
    ))
}

func componentFieldLabel(role: String, subrole: String, identifier: String, title: String, placeholder: String, description: String) -> String {
    if !description.isEmpty { return description }
    if !title.isEmpty { return title }
    if !placeholder.isEmpty { return placeholder }
    if !identifier.isEmpty { return identifier }
    if subrole.lowercased().contains("search") { return L("搜索框") }
    if role == "AXTextArea" { return L("文本区域") }
    if role == "AXTextField" { return L("文本框") }
    return role.isEmpty ? L("文本框") : role
}

func componentPermissionDisplay(_ permission: ComponentPermission) -> (tree: String, detail: String) {
    let parts = permission.id.components(separatedBy: "\u{1e}")
    if !permission.id.contains("\u{1e}") {
        let tree = permission.id.replacingOccurrences(of: "/", with: " / ")
        let detail = permission.label == permission.id || permission.label.isEmpty ? "" : permission.label
        return (tree, detail)
    }
    guard parts.count == 7 else {
        return (permission.id, permission.label == permission.id ? "" : permission.label)
    }
    let role = parts[0]
    let subrole = parts[1]
    let identifier = parts[2]
    let title = parts[3]
    let placeholder = parts[4]
    let description = parts[5]
    let path = parts[6]
    let leaf: String
    if role.isEmpty {
        leaf = subrole
    } else if subrole.isEmpty || subrole == role {
        leaf = role
    } else {
        leaf = "\(role) (\(subrole))"
    }
    var nodes = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if !leaf.isEmpty { nodes.append(leaf) }
    let tree = nodes.isEmpty ? permission.id : nodes.joined(separator: " / ")
    var details = [identifier, title, placeholder, description].filter { !$0.isEmpty }
    if details.isEmpty, !permission.label.isEmpty, permission.label != leaf {
        details = [permission.label]
    }
    return (tree, details.joined(separator: " · "))
}

func applyingComponentDecision(_ targets: [TargetApplication], bundleID: String, permission: ComponentPermission) -> [TargetApplication] {
    guard !permission.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let index = targets.firstIndex(where: { $0.bundleID == bundleID }) else { return targets }
    var updated = targets
    if let existing = updated[index].components.firstIndex(where: { $0.id == permission.id }) {
        updated[index].components[existing] = permission
    } else {
        updated[index].components.append(permission)
    }
    return updated
}

func saveComponentDecision(bundleID: String, permission: ComponentPermission) {
    let updated = applyingComponentDecision(configuredTargets(), bundleID: bundleID, permission: permission)
    setSetting(SettingKey.targets, targetSettingsValue(updated))
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

func openAIConfigurationReady(url: String, token: String, model: String, extraParameters: String) -> Bool {
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmedURL),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          !trimmedToken.isEmpty, !trimmedModel.isEmpty else { return false }
    return (try? extraRequestParameters(extraParameters)) != nil
}

func savedOpenAIConfigurationReady() -> Bool {
    openAIConfigurationReady(
        url: setting(SettingKey.oaURL),
        token: setting(SettingKey.oaToken),
        model: setting(SettingKey.oaModel),
        extraParameters: setting(SettingKey.oaExtraParameters)
    )
}

enum HistoryDraftKind: Equatable {
    case original
    case adjusted
    case unused
}

struct HistoryDraftChoice: Equatable {
    let kind: HistoryDraftKind
    let text: String
}

/// 调用方按从新到旧传入。同一段文字只保留最新一次出现时的角色。
func historyDraftChoices(_ records: [(original: String, adjusted: String, unused: String)]) -> [HistoryDraftChoice] {
    var seen = Set<String>()
    var choices: [HistoryDraftChoice] = []
    func add(_ raw: String, kind: HistoryDraftKind) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, seen.insert(key).inserted else { return }
        choices.append(HistoryDraftChoice(kind: kind, text: raw))
    }
    for record in records {
        add(record.original, kind: .original)
        add(record.adjusted, kind: .adjusted)
        add(record.unused, kind: .unused)
    }
    return choices
}
