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
        (try? NSRegularExpression(pattern: rule.pattern).firstMatch(in: input, range: range)) != nil
    }
}

struct CommandResult {
    let interrupt: Bool
    let replacement: String?
}

// 每次运行独立的 JSContext。脚本是一个函数表达式，以 input 调用，可返回结果对象或 Promise。
final class CommandRunner {
    private var context: JSContext?
    private var completed = false
    private let completion: (Result<CommandResult, ProbeError>) -> Void

    init(script: String, input: String, completion: @escaping (Result<CommandResult, ProbeError>) -> Void) {
        self.completion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(.failure(ProbeError(L("指令执行超时"))))
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let context = JSContext()!
            self.context = context
            context.exceptionHandler = { [weak self] _, exception in
                if let exception = exception { self?.finish(.failure(ProbeError(exception.toString()))) }
            }
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
            completion(result)
            context = nil
        }
    }
}
