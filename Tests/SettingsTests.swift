import AppKit
import CryptoKit
import Darwin
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
        precondition(targets[0].hijackScope == .all && targets[0].components.isEmpty)
        let legacyTargets = #"[{"name":"测试 App","bundleID":"test.app","path":"/Applications/Test.app"}]"#
        let legacyDecoded = try JSONDecoder().decode([TargetApplication].self, from: Data(legacyTargets.utf8))
        precondition(legacyDecoded == apps)
        _ = try decodeSettingsFile(encodeSettingsFile([SettingKey.targets: legacyTargets]))
        let permission = ComponentPermission(id: "composer", label: "输入消息", decision: .deny)
        let partial = TargetApplication(name: "测试 App", bundleID: "test.app", path: "/Applications/Test.app", hijackScope: .partial, components: [permission])
        let partialDecoded = try JSONDecoder().decode([TargetApplication].self, from: Data(targetSettingsValue([partial]).utf8))
        precondition(partialDecoded == [partial])
        let remembered = applyingComponentDecision(apps, bundleID: "test.app", permission: permission)
        precondition(remembered[0].components == [permission])
        let replaced = applyingComponentDecision(remembered, bundleID: "test.app", permission: ComponentPermission(id: "composer", label: "输入消息", decision: .allow))
        precondition(replaced[0].components == [ComponentPermission(id: "composer", label: "输入消息", decision: .allow)])
        precondition(applyingComponentDecision(apps, bundleID: "missing", permission: permission) == apps)
        let field = makeComponentSignature(role: "AXTextArea", subrole: "", identifier: "", title: "", placeholder: "输入消息", description: "", value: "hello", ancestorPath: "AXGroup")
        let sameField = makeComponentSignature(role: "AXTextArea", subrole: "", identifier: "", title: "", placeholder: "输入消息", description: "hello", value: "hello", ancestorPath: "AXGroup")
        precondition(field == sameField && field.label == "输入消息")
        let search = makeComponentSignature(role: "AXTextField", subrole: "AXSearchField", identifier: "", title: "", placeholder: "", description: "", value: "", ancestorPath: "")
        precondition(search.label == "搜索框" && search.id != field.id)
        let titled = makeComponentSignature(role: "AXTextField", subrole: "", identifier: "id", title: "标题", placeholder: "占位", description: "说明", value: "", ancestorPath: "AXSplitGroup/AXGroup")
        precondition(titled.label == "说明")
        precondition(titled.id != makeComponentSignature(role: "AXTextField", subrole: "", identifier: "id", title: "标题", placeholder: "占位", description: "说明", value: "", ancestorPath: "AXGroup").id)
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
        let commands = [CommandRule(pattern: "^#", script: "async (input) => ({interrupt: true, replacement: input.slice(1)})")]
        let commandRoundTrip = try decodeSettingsFile(encodeSettingsFile([SettingKey.commands: encodeCommands(commands)]))
        let decodedCommands = try decodeCommands(commandRoundTrip[SettingKey.commands]!)
        precondition(decodedCommands == commands)
        precondition(matchingCommand("#hello", rules: commands) == commands[0])
        precondition(matchingCommand("hello", rules: commands) == nil)
        let ranked = [
            CommandRule(pattern: "^#", script: "first"),
            CommandRule(pattern: "hello", script: "second"),
            CommandRule(pattern: "[", script: "invalid"),
            CommandRule(pattern: "", script: "empty")
        ]
        precondition(matchingCommand("#hello", rules: ranked)?.script == "first")
        var reordered = ranked
        reorder(&reordered, from: 0, to: 1)
        precondition(reordered.map(\.script) == ["second", "first", "invalid", "empty"])
        precondition(matchingCommand("#hello", rules: reordered)?.script == "second")
        precondition(matchingCommand("#hi", rules: reordered)?.script == "first")
        precondition(matchingCommand("plain", rules: [ranked[2], ranked[3], CommandRule(pattern: "plain", script: "later")])?.script == "later")
        precondition(matchingCommand("plain", rules: [ranked[2], ranked[3]]) == nil)
        var order = [0, 1, 2]
        reorder(&order, from: 2, to: 0)
        precondition(order == [2, 0, 1])
        reorder(&order, from: 0, to: 0)
        precondition(order == [2, 0, 1])
        precondition(formatCommandResult(CommandResult(interrupt: true, replacement: "hello")) == "{ interrupt: true, replacement: \"hello\" }")
        precondition(formatCommandResult(CommandResult(interrupt: false, replacement: nil)) == "{ interrupt: false }")
        precondition(formatCommandResult(CommandResult(interrupt: true, replacement: "a\"b\n")) == "{ interrupt: true, replacement: \"a\\\"b\\n\" }")
        let stack = NSStackView()
        stack.orientation = .vertical
        let labels = ["a", "b", "c"].map { NSTextField(labelWithString: $0) }
        labels.forEach { stack.addArrangedSubview($0) }
        stack.removeArrangedSubview(labels[0])
        stack.insertArrangedSubview(labels[0], at: 2)
        precondition(stack.arrangedSubviews.map { ($0 as? NSTextField)?.stringValue } == ["b", "c", "a"])
        stack.removeArrangedSubview(labels[0])
        stack.insertArrangedSubview(labels[0], at: 0)
        precondition(stack.arrangedSubviews.map { ($0 as? NSTextField)?.stringValue } == ["a", "b", "c"])
        func run(_ script: String, input: String = "#hello", wait: TimeInterval = 3) -> Result<CommandResult, ProbeError> {
            var output: Result<CommandResult, ProbeError>?
            var runner: CommandRunner? = CommandRunner(script: script, input: input) { output = $0 }
            let deadline = Date().addingTimeInterval(wait)
            while output == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            withExtendedLifetime(runner) {}
            runner = nil
            return output ?? .failure(ProbeError("Test timeout"))
        }
        switch run(commands[0].script) {
        case .success(let result): precondition(result.interrupt && result.replacement == "hello")
        case .failure(let error): fatalError(error.description)
        }
        switch run("(input) => ({interrupt: false, replacement: 'ignored'});") {
        case .success(let result): precondition(!result.interrupt && result.replacement == "ignored")
        case .failure(let error): fatalError(error.description)
        }
        switch run("async function (input) {\n  await Promise.resolve();\n  return {interrupt: true};\n}") {
        case .success(let result): precondition(result.interrupt && result.replacement == nil)
        case .failure(let error): fatalError(error.description)
        }
        switch run("(input) => Promise.resolve({interrupt: true, replacement: input.toUpperCase()})") {
        case .success(let result): precondition(result.interrupt && result.replacement == "#HELLO")
        case .failure(let error): fatalError(error.description)
        }
        if case .success = run("(input) => ({interrupt: 'wrong'})") { fatalError("Invalid result accepted") }
        if case .success = run("({interrupt: true})") { fatalError("Non-function script accepted") }
        if case .success = run("(input) => { throw new Error('boom'); }") { fatalError("Thrown error accepted") }
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
            [SettingKey.targets: #"[{"name":"A","bundleID":"a","path":"/A.app","hijackScope":"nope"}]"#],
            [SettingKey.targets: #"[{"name":"A","bundleID":"a","path":"/A.app","components":[{"id":"","label":"字段","decision":"allow"}]}]"#],
            [SettingKey.targets: #"[{"name":"A","bundleID":"a","path":"/A.app","components":[{"id":"a","label":"字段","decision":"allow"},{"id":"a","label":"字段","decision":"deny"}]}]"#],
            [SettingKey.targets: #"[{"name":"A","bundleID":"a","path":"/A.app","components":[{"id":"a","label":"字段","decision":"maybe"}]}]"#],
            [LanguagePreference.key: "fr"],
            [SettingKey.oaExtraParameters: "[1,2]"],
            [SettingKey.oaExtraParameters: #"{"model":"override"}"#],
            [SettingKey.oaExtraParameters: #"{"messages":[]}"#],
            [SettingKey.oaExtraParameters: #"{"stream":true}"#],
            [SettingKey.oaExtraParameters: #"{"stream":0}"#],
            [SettingKey.commands: "invalid"],
            [SettingKey.commands: encodeCommands([CommandRule(pattern: "[", script: "return 1")])]
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
        do {
            _ = try decodeSettingsFile(Data(#"{"kind":"hola-settings","version":1,"settings":{"commands":[]}}"#.utf8))
            fatalError("Wrong commands value type accepted")
        } catch is ProbeError { }
        try testFetch()
        print("Passed: settings round trips, extra request body, legacy compatibility, malformed settings rejection, fetch.")
    }

    static func testFetch() throws {
        func run(_ script: String, input: String = "#hello", wait: TimeInterval = 3) -> Result<CommandResult, ProbeError> {
            var output: Result<CommandResult, ProbeError>?
            var runner: CommandRunner? = CommandRunner(script: script, input: input) { output = $0 }
            let deadline = Date().addingTimeInterval(wait)
            while output == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            withExtendedLifetime(runner) {}
            runner = nil
            return output ?? .failure(ProbeError("Test timeout"))
        }
        func expect(_ script: String, _ replacement: String, input: String = "#hello", wait: TimeInterval = 3) {
            switch run(script, input: input, wait: wait) {
            case .success(let result):
                precondition(result.interrupt && result.replacement == replacement, "expected \(replacement), got \(String(describing: result.replacement))")
            case .failure(let error):
                fatalError(error.description)
            }
        }
        expect("""
        () => ({ interrupt: true, replacement: [typeof fetch, typeof Headers, typeof Request, typeof Response, typeof AbortController, typeof FormData, typeof URLSearchParams, typeof Blob, typeof __holaFetch].join(" ") })
        """, "function function function function function function function function undefined")
        expect("""
        () => {
          const headers = new Headers({ "X-Test": " a " });
          headers.append("X-Test", "b");
          return { interrupt: true, replacement: headers.get("x-test") };
        }
        """, "a, b")
        expect("""
        () => {
          const request = new Request("https://example.com/", { headers: { A: "1" } });
          request.headers.set("B", "2");
          return { interrupt: true, replacement: request.headers.get("a") + " " + request.headers.get("b") };
        }
        """, "1 2")
        expect("""
        () => {
          try {
            new Response("a").headers.set("x", "1");
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError")
        expect("""
        () => {
          try {
            new Request("https://example.com/", { method: "TRACE" });
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError")
        expect("""
        async () => {
          try {
            await fetch("http://127.0.0.1:1/", { method: "GET", body: "x" });
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.message }; }
        }
        """, "Request with GET/HEAD method cannot have body.")
        expect("""
        async () => {
          try {
            await fetch("/relative");
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError")
        expect("""
        async () => {
          const controller = new AbortController();
          controller.abort();
          try {
            await fetch("https://example.com/", { signal: controller.signal });
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "AbortError")
        expect("""
        async () => {
          const params = new URLSearchParams({ q: "a b" });
          const request = new Request("https://example.com/", { method: "POST", body: params });
          return { interrupt: true, replacement: request.headers.get("content-type") + " " + await request.text() };
        }
        """, "application/x-www-form-urlencoded;charset=UTF-8 q=a+b")
        expect("""
        async () => {
          const form = new FormData();
          form.append("a", "b c");
          const request = new Request("https://example.com/", { method: "POST", body: form });
          const type = request.headers.get("content-type");
          const response = new Response(await request.arrayBuffer(), { headers: { "content-type": type } });
          const parsed = await response.formData();
          return { interrupt: true, replacement: parsed.get("a") };
        }
        """, "b c")

        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        server.handler = { request in
            switch request.path {
            case "/text":
                return .text(200, "hello", headers: ["X-Test": "Hello"])
            case "/json":
                return .text(200, #"{"n":1}"#, headers: ["Content-Type": "application/json"])
            case "/bad":
                return .text(404, "nope")
            case "/bytes":
                return .bytes(200, Data([65, 66, 67]))
            case "/hi":
                return .text(200, "hi")
            case "/echo":
                let type = request.headers["content-type"] ?? ""
                let body = String(data: request.body, encoding: .utf8) ?? ""
                return .text(200, "\(request.method)|\(type)|\(body)")
            case "/start":
                return .text(302, "", headers: ["Location": "\(base)/done", "Content-Length": "0"])
            case "/done":
                return .text(200, "done")
            case "/hang":
                return nil
            default:
                return .text(404, request.path)
            }
        }
        expect("""
        async (input) => {
          const res = await fetch(input);
          return { interrupt: true, replacement: [res.ok, res.status, res.statusText, await res.text(), res.headers.get("x-test")].join(" ") };
        }
        """, "true 200 OK hello Hello", input: "\(base)/text")
        expect("""
        async (input) => {
          const res = await fetch(input);
          const data = await res.json();
          return { interrupt: true, replacement: res.ok + " " + data.n };
        }
        """, "true 1", input: "\(base)/json")
        expect("""
        async (input) => {
          const res = await fetch(input);
          try {
            await res.json();
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: res.ok + " " + res.status + " " + e.name }; }
        }
        """, "false 404 SyntaxError", input: "\(base)/bad")
        expect("""
        async (input) => {
          const res = await fetch(input);
          const bytes = new Uint8Array(await res.arrayBuffer());
          return { interrupt: true, replacement: bytes.length + ":" + bytes[0] + ":" + bytes[2] };
        }
        """, "3:65:67", input: "\(base)/bytes")
        expect("""
        async (input) => {
          const res = await fetch(input);
          const copy = res.clone();
          return { interrupt: true, replacement: (await res.text()) + (await copy.text()) };
        }
        """, "hellohello", input: "\(base)/text")
        expect("""
        async (input) => {
          const res = await fetch(input);
          await res.text();
          try {
            await res.json();
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError", input: "\(base)/text")
        expect("""
        async (input) => {
          const res = await fetch(input, { method: "post", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ a: 1 }) });
          return { interrupt: true, replacement: await res.text() };
        }
        """, #"POST|application/json|{"a":1}"#, input: "\(base)/echo")
        expect("""
        async (input) => {
          const request = new Request(input, { method: "POST", body: "hi" });
          const res = await fetch(request);
          return { interrupt: true, replacement: request.bodyUsed + " " + await res.text() };
        }
        """, "true POST||hi", input: "\(base)/echo")
        expect("""
        async (input) => {
          const res = await fetch(input);
          return { interrupt: true, replacement: res.status + " " + res.redirected + " " + res.url + " " + await res.text() };
        }
        """, "200 true \(base)/done done", input: "\(base)/start")
        expect("""
        async (input) => {
          const res = await fetch(input, { redirect: "manual" });
          return { interrupt: true, replacement: res.status + " " + res.redirected + " " + res.headers.get("location") };
        }
        """, "302 false \(base)/done", input: "\(base)/start")
        expect("""
        async (input) => {
          try {
            await fetch(input, { redirect: "error" });
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError", input: "\(base)/start")
        let good = Data(SHA256.hash(data: Data("hi".utf8))).base64EncodedString()
        let bad = Data(SHA256.hash(data: Data("no".utf8))).base64EncodedString()
        expect("""
        async (input) => {
          const res = await fetch(input, { integrity: "sha256-\(good)" });
          return { interrupt: true, replacement: await res.text() };
        }
        """, "hi", input: "\(base)/hi")
        expect("""
        async (input) => {
          try {
            await fetch(input, { integrity: "sha256-\(bad)" });
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError", input: "\(base)/hi")
        expect("""
        async (input) => {
          try {
            await fetch("http://127.0.0.1:1/");
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TypeError")
        expect("""
        async (input) => {
          try {
            await fetch(input, { signal: AbortSignal.timeout(200) });
            return { interrupt: true, replacement: "no" };
          } catch (e) { return { interrupt: true, replacement: e.name }; }
        }
        """, "TimeoutError", input: "\(base)/hang", wait: 5)
    }
}

private struct LoopbackHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

private struct LoopbackHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func text(_ status: Int, _ text: String, headers: [String: String] = [:]) -> LoopbackHTTPResponse {
        bytes(status, Data(text.utf8), headers: headers.merging(["Content-Type": "text/plain; charset=utf-8"]) { current, _ in current })
    }

    static func bytes(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> LoopbackHTTPResponse {
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        return LoopbackHTTPResponse(status: status, headers: fields, body: body)
    }
}

private final class LoopbackHTTPServer {
    let port: UInt16
    var handler: ((LoopbackHTTPRequest) -> LoopbackHTTPResponse?)?
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        if socketFD < 0 { throw ProbeError("socket failed") }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 || listen(socketFD, 16) != 0 {
            Darwin.close(socketFD)
            throw ProbeError("bind failed")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socketFD, $0, &length) }
        }
        if named != 0 {
            Darwin.close(socketFD)
            throw ProbeError("getsockname failed")
        }
        fd = socketFD
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in
            while !self.isStopped {
                var clientAddr = sockaddr_in()
                var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(self.fd, $0, &clientLength) }
                }
                if client < 0 { break }
                DispatchQueue.global().async {
                    self.handle(client)
                    Darwin.close(client)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func handle(_ client: Int32) {
        var nosig: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout.size(ofValue: nosig)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let headerData = readHeaders(client),
              let headerText = String(data: headerData, encoding: .utf8) else { return }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = length > 0 ? readExact(client, length) ?? Data() : Data()
        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let request = LoopbackHTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body)
        guard let response = handler?(request) else {
            while !isStopped { Thread.sleep(forTimeInterval: 0.05) }
            return
        }
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(client, base.advanced(by: sent), raw.count - sent)
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 302: return "Found"
        case 404: return "Not Found"
        default: return "OK"
        }
    }
}

private func readHeaders(_ fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 65536 {
        let count = Darwin.read(fd, &byte, 1)
        if count <= 0 { return nil }
        data.append(byte)
        if data.count >= 4, data.suffix(4) == Data([13, 10, 13, 10]) { return data }
    }
    return nil
}

private func readExact(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < count {
        let want = min(4096, count - data.count)
        let readCount = Darwin.read(fd, &buffer, want)
        if readCount <= 0 { return nil }
        data.append(buffer, count: readCount)
    }
    return data
}
