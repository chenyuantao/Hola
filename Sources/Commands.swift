import Foundation
import JavaScriptCore

struct CommandRule: Codable, Equatable {
    var pattern: String
    var script: String
}

func decodeCommands(_ raw: String) throws -> [CommandRule] {
    guard let data = raw.data(using: .utf8),
          let rules = try? JSONDecoder().decode([CommandRule].self, from: data) else {
        throw ProbeError(L("指令配置格式无效"))
    }
    for rule in rules {
        guard !rule.pattern.isEmpty, !rule.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? NSRegularExpression(pattern: rule.pattern)) != nil else {
            throw ProbeError(L("指令规则或脚本无效"))
        }
    }
    return rules
}

func encodeCommands(_ rules: [CommandRule]) -> String {
    guard let data = try? JSONEncoder().encode(rules) else { return "[]" }
    return String(data: data, encoding: .utf8) ?? "[]"
}

func matchingCommand(_ input: String, rules: [CommandRule]) -> CommandRule? {
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return rules.first { rule in
        guard !rule.pattern.isEmpty, let expression = try? NSRegularExpression(pattern: rule.pattern) else { return false }
        return expression.firstMatch(in: input, range: range) != nil
    }
}

func reorder<T>(_ items: inout [T], from: Int, to: Int) {
    guard from != to, items.indices.contains(from), items.indices.contains(to) else { return }
    let item = items.remove(at: from)
    items.insert(item, at: to)
}

func formatCommandResult(_ result: CommandResult) -> String {
    guard let replacement = result.replacement else { return "{ interrupt: \(result.interrupt) }" }
    return "{ interrupt: \(result.interrupt), replacement: \(quotedJSONString(replacement)) }"
}

private func quotedJSONString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          var text = String(data: data, encoding: .utf8), text.count >= 2 else { return "\"\"" }
    text.removeFirst()
    text.removeLast()
    return text
}

struct CommandResult {
    let interrupt: Bool
    let replacement: String?
}

// 指令脚本宿主扩展。每次运行使用独立的 JSContext。脚本是函数表达式，以原始草稿 input 调用，
// 可返回结果对象或 Promise。同一条串行队列访问 JSContext，避免和网络、进程回调并发。
// 整段脚本须在 10 秒内返回。下面两个全局函数是 JavaScriptCore 没有、由言好注入的宿主能力：
//
// fetch(input, init?) → Promise<Response>
//   对齐 Fetch 标准。同时提供 Headers、Request、Response、AbortController、AbortSignal、
//   FormData、Blob、File、URLSearchParams、DOMException、ReadableStream。
//   本地特权脚本，不套用 CORS。redirect 默认 "follow"；"manual" 返回 3xx 本身，可读取 Location。
//   HTTP 4xx/5xx 不拒绝 Promise，先看 response.ok。
//   URL 不合法、连不上、integrity 不匹配 → TypeError。
//   AbortSignal 中止 → AbortError。AbortSignal.timeout(ms) → TimeoutError。
//   例：const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text: input }) });
//
// execute(command, options?) → Promise<{ stdout, stderr }>
//   对齐 Node.js child_process.exec 的 Promise 形式（child_process/promises 的 exec）。
//   command 是字符串，在当前用户权限下交给 shell 执行，默认 /bin/sh -c。
//   成功时 stdout、stderr 为字符串。
//   options.cwd：工作目录，默认进程当前目录。
//   options.env：完整环境变量表，值必须是字符串；不传则沿用当前进程环境。
//   options.encoding：utf8（默认）、utf-8、buffer、hex、base64、latin1、binary、ascii。
//     buffer 时 stdout、stderr 为 Uint8Array。
//   options.shell：shell 可执行文件路径，默认 "/bin/sh"。
//   options.timeout：毫秒。超时后按 killSignal 结束进程并拒绝；0 表示不另设超时。
//   options.maxBuffer：stdout 或 stderr 各自的字节上限，默认 1048576。超出则拒绝。
//   options.killSignal：超时、超出 maxBuffer 或 AbortSignal 中止时发送的信号，默认 "SIGTERM"。
//   options.signal：AbortSignal。中止时拒绝 AbortError。
//   非 0 退出：拒绝 Error，error.code 为退出码数字，error.killed 为 false，error.signal 为 null，
//     error.message 以 "Command failed: " 开头，error.cmd、error.stdout、error.stderr 可用。
//   超时：error.killed 为 true，error.signal 为 killSignal，error.code 为 null。
//   超出 maxBuffer：error.code 为 "ERR_CHILD_PROCESS_STDIO_MAXBUFFER"，
//     error.message 为 "stdout maxBuffer length exceeded" 或 stderr 对应文案。
//   shell 不存在或 cwd 不存在：error.code 为 "ENOENT"。
//   例：const { stdout } = await execute("printf %s " + JSON.stringify(input));
final class CommandRunner {
    private let queue = DispatchQueue(label: "local.hola.command", qos: .userInitiated)
    private var context: JSContext?
    private var fetchBridge: CommandFetchBridge?
    private var executeBridge: CommandExecuteBridge?
    private var completed = false
    private let completion: (Result<CommandResult, ProbeError>) -> Void

    init(script: String, input: String, completion: @escaping (Result<CommandResult, ProbeError>) -> Void) {
        self.completion = completion
        let bridge = CommandFetchBridge(queue: queue)
        let execute = CommandExecuteBridge(queue: queue)
        fetchBridge = bridge
        executeBridge = execute
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(.failure(ProbeError(L("指令执行超时"))))
        }
        queue.async { [self] in
            let context = JSContext()!
            self.context = context
            context.exceptionHandler = { [weak self] _, exception in
                if let exception = exception { self?.finish(.failure(ProbeError(exception.toString()))) }
            }
            bridge.install(into: context)
            execute.install(into: context)
            guard context.exception == nil else { return }
            var source = script.trimmingCharacters(in: .whitespacesAndNewlines)
            while source.hasSuffix(";") { source = String(source.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let function = context.evaluateScript("(\n" + source + "\n)"), context.exception == nil else { return }
            guard function.isObject, function.isInstance(of: context.objectForKeyedSubscript("Function")) else {
                self.finish(.failure(ProbeError(L("指令脚本必须是函数，例如 (input) => ({ interrupt: false })"))))
                return
            }
            let invoke = context.evaluateScript("(fn, input) => Promise.resolve().then(() => fn(input))")
            guard let promise = invoke?.call(withArguments: [function, input]) else { return }
            let resolve: @convention(block) (JSValue) -> Void = { [weak self] value in
                guard let self = self else { return }
                let interrupt = value.forProperty("interrupt")
                let replacement = value.forProperty("replacement")
                guard let interrupt = interrupt, interrupt.isBoolean,
                      replacement == nil || replacement!.isUndefined || replacement!.isNull || replacement!.isString else {
                    self.finish(.failure(ProbeError(L("指令返回值必须包含布尔型 interrupt，replacement 必须是字符串"))))
                    return
                }
                self.finish(.success(CommandResult(interrupt: interrupt.toBool(), replacement: replacement?.isString == true ? replacement?.toString() : nil)))
            }
            let reject: @convention(block) (JSValue) -> Void = { [weak self] error in
                self?.finish(.failure(ProbeError(error.toString())))
            }
            let onResolve = JSValue(object: resolve, in: context)!
            let onReject = JSValue(object: reject, in: context)!
            _ = promise.invokeMethod("then", withArguments: [onResolve, onReject])
        }
    }

    private func finish(_ result: Result<CommandResult, ProbeError>) {
        DispatchQueue.main.async { [self] in
            guard !completed else { return }
            completed = true
            fetchBridge?.invalidate()
            executeBridge?.invalidate()
            completion(result)
            fetchBridge = nil
            executeBridge = nil
            context = nil
        }
    }
}
