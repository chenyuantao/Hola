import Foundation

@main
struct SettingsTests {
    static func main() throws {
        let apps = [TargetApplication(name: "测试 App", bundleID: "test.app", path: "/Applications/Test.app")]
        let values = [SettingKey.targets: targetSettingsValue(apps), LanguagePreference.key: "en", SettingKey.oaToken: "test-token"]
        let decoded = try decodeSettingsFile(encodeSettingsFile(values))
        precondition(decoded == values)
        let targets = try JSONDecoder().decode([TargetApplication].self, from: Data(decoded[SettingKey.targets]!.utf8))
        precondition(targets.count == 1 && targets[0].name == apps[0].name && targets[0].bundleID == apps[0].bundleID && targets[0].path == apps[0].path)
        let empty = try decodeSettingsFile(encodeSettingsFile([SettingKey.targets: "[]"]))
        precondition(empty[SettingKey.targets] == "[]")
        let legacy = Data(#"{"kind":"happy-talk-settings","version":1,"settings":{"openAIModel":"legacy"}}"#.utf8)
        let old = try decodeSettingsFile(legacy)
        precondition(old[SettingKey.targets] == nil && old[LanguagePreference.key] == nil)
        for language in LanguagePreference.values {
            let result = try decodeSettingsFile(encodeSettingsFile([LanguagePreference.key: language]))
            precondition(result[LanguagePreference.key] == language)
        }
        let extras = #"{"reasoning_effort":"high","stream":false}"#
        let extraRoundTrip = try decodeSettingsFile(encodeSettingsFile([SettingKey.oaExtraParameters: extras]))
        precondition(extraRoundTrip[SettingKey.oaExtraParameters] == extras)
        let body = try chatCompletionBody(model: "gpt-5.4", system: "rules", user: "draft", extraParameters: extras)
        precondition(body["model"] as? String == "gpt-5.4")
        precondition(body["reasoning_effort"] as? String == "high")
        precondition((body["stream"] as? Bool) == false)
        let messages = body["messages"] as? [[String: String]]
        precondition(messages?.count == 2 && messages?[0]["content"] == "rules" && messages?[1]["content"] == "draft")
        let reasoningDefault = try chatCompletionBody(model: "gpt-5.4", system: "rules", user: "draft", extraParameters: "")
        precondition(reasoningDefault["reasoning_effort"] as? String == "low")
        precondition(reasoningDefault["thinking"] == nil && (reasoningDefault["stream"] as? Bool) == false)
        let nonReasoning = try chatCompletionBody(model: "gpt-4.1", system: "rules", user: "draft", extraParameters: "")
        precondition(nonReasoning["reasoning_effort"] == nil)
        let unknownModel = try chatCompletionBody(model: "other-model", system: "rules", user: "draft", extraParameters: "")
        precondition(unknownModel["reasoning_effort"] == nil && unknownModel["thinking"] == nil)
        let emptyExtras = try extraRequestParameters(" ")
        precondition(emptyExtras.isEmpty)
        let invalid: [[String: String]] = [
            [SettingKey.targets: "invalid"],
            [SettingKey.targets: #"[{"name":"bad","path":"/tmp"}]"#],
            [SettingKey.targets: targetSettingsValue([TargetApplication(name: "bad", bundleID: " ", path: "")])],
            [SettingKey.targets: targetSettingsValue(apps + apps)],
            [LanguagePreference.key: "fr"],
            [SettingKey.oaExtraParameters: "[1,2]"],
            [SettingKey.oaExtraParameters: #"{"model":"override"}"#],
            [SettingKey.oaExtraParameters: #"{"messages":[]}"#],
            [SettingKey.oaExtraParameters: #"{"stream":true}"#],
            [SettingKey.oaExtraParameters: #"{"stream":0}"#]
        ]
        for values in invalid {
            do {
                _ = try decodeSettingsFile(encodeSettingsFile(values))
                fatalError("Invalid settings accepted")
            } catch is ProbeError { }
        }
        do {
            _ = try decodeSettingsFile(Data(#"{"kind":"hola-settings","version":1,"settings":{"targetApplications":[],"openAIModel":"test"}}"#.utf8))
            fatalError("Wrong Apps value type accepted")
        } catch is ProbeError { }
        print("Passed: settings round trips, extra request body, legacy compatibility, malformed settings rejection.")
    }
}
