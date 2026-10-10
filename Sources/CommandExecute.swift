import Darwin
import Foundation
import JavaScriptCore

// 指令脚本里的 execute。JavaScriptCore 没有 child_process，这里用 Process 补上
// Node.js child_process.exec 的 Promise 形式。用法见 Commands.swift 里「指令脚本宿主扩展」。
final class CommandExecuteBridge {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var invalidated = false
    private var jobs: [Int: ExecJob] = [:]
    private var nextID = 1

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func install(into context: JSContext) {
        let start: @convention(block) (JSValue, JSValue) -> Int32 = { [weak self] request, callback in
            Int32(self?.start(request, callback: callback) ?? 0)
        }
        let abort: @convention(block) (Int32) -> Void = { [weak self] id in
            self?.abort(id: Int(id))
        }
        context.setObject(start, forKeyedSubscript: "__holaExecute" as NSString)
        context.setObject(abort, forKeyedSubscript: "__holaAbortExecute" as NSString)
        context.evaluateScript(commandExecuteSource)
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let running = Array(jobs.values)
        jobs.removeAll()
        lock.unlock()
        for job in running {
            job.timeoutItem?.cancel()
            signal(job, sig: SIGKILL)
        }
    }

    private func start(_ request: JSValue, callback: JSValue) -> Int {
        let command = request.forProperty("command")?.toString() ?? ""
        let cwd = request.forProperty("cwd")?.toString() ?? ""
        let shell = request.forProperty("shell")?.toString() ?? "/bin/sh"
        let encoding = request.forProperty("encoding")?.toString() ?? "utf8"
        let killSignalName = request.forProperty("killSignal")?.toString() ?? "SIGTERM"
        let timeout = request.forProperty("timeout")?.toDouble() ?? 0
        let maxBufferRaw = request.forProperty("maxBuffer")?.toDouble() ?? Double(1024 * 1024)
        let maxBuffer = Int(min(max(0, maxBufferRaw), Double(Int.max / 4)))
        let env = environment(from: request.forProperty("env"))
        lock.lock()
        let id = nextID
        nextID += 1
        let dead = invalidated
        lock.unlock()
        guard !dead else { return 0 }
        let job = ExecJob(id: id, callback: callback, command: command, shell: shell, encoding: encoding, killSignalName: killSignalName, killSignal: signalNumbers[killSignalName] ?? SIGTERM, maxBuffer: maxBuffer)
        if !cwd.isEmpty {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) || !isDirectory.boolValue {
                failEarly(job, .spawn(message: "ENOENT: no such file or directory, uv_chdir '\(cwd)'", code: "ENOENT", syscall: "uv_chdir", path: cwd))
                return id
            }
            job.process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        if !FileManager.default.isExecutableFile(atPath: shell) {
            failEarly(job, .spawn(message: "spawn \(shell) ENOENT", code: "ENOENT", syscall: "spawn", path: shell))
            return id
        }
        job.process.executableURL = URL(fileURLWithPath: shell)
        job.process.arguments = ["-c", command]
        if let env { job.process.environment = env }
        job.process.standardInput = FileHandle.nullDevice
        job.process.standardOutput = job.stdoutPipe
        job.process.standardError = job.stderrPipe
        job.process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            self?.queue.async {
                self?.noteTerminated(id: id, status: status, reason: reason)
            }
        }
        lock.lock()
        jobs[id] = job
        lock.unlock()
        do {
            try job.process.run()
        } catch {
            lock.lock()
            jobs.removeValue(forKey: id)
            lock.unlock()
            failEarly(job, .spawn(message: "spawn \(shell) ENOENT", code: "ENOENT", syscall: "spawn", path: shell))
            return id
        }
        pump(job.stdoutPipe.fileHandleForReading, id: id, stdout: true)
        pump(job.stderrPipe.fileHandleForReading, id: id, stdout: false)
        if timeout > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.onTimeout(id: id)
            }
            job.timeoutItem = work
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout / 1000, execute: work)
        }
        return id
    }

    private func abort(id: Int) {
        lock.lock()
        let job = jobs[id]
        if let job, job.failure == nil, !job.settled {
            job.failure = .abort
        }
        lock.unlock()
        guard let job else { return }
        job.timeoutItem?.cancel()
        signal(job, sig: job.killSignal)
    }

    private func onTimeout(id: Int) {
        lock.lock()
        let job = jobs[id]
        if let job, job.failure == nil, !job.settled {
            job.failure = .timeout
        }
        lock.unlock()
        guard let job, job.failure == .timeout else { return }
        signal(job, sig: job.killSignal)
    }

    private func noteTerminated(id: Int, status: Int32, reason: Process.TerminationReason) {
        lock.lock()
        guard let job = jobs[id] else { lock.unlock(); return }
        job.processClosed = true
        job.terminationStatus = status
        job.terminationReason = reason
        let ready = job.stdoutClosed && job.stderrClosed && !job.settled
        lock.unlock()
        if ready { complete(id: id) }
    }

    private func pump(_ handle: FileHandle, id: Int, stdout: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                self?.consume(id: id, stdout: stdout, chunk: chunk)
            }
            self?.markPipeClosed(id: id, stdout: stdout)
        }
    }

    private func consume(id: Int, stdout: Bool, chunk: Data) {
        lock.lock()
        guard let job = jobs[id] else { lock.unlock(); return }
        let exceeded = job.append(stdout: stdout, chunk: chunk)
        let shouldKill = exceeded && job.failure == nil
        if shouldKill { job.failure = .maxBuffer(stdout ? "stdout" : "stderr") }
        lock.unlock()
        if shouldKill { signal(job, sig: job.killSignal) }
    }

    private func markPipeClosed(id: Int, stdout: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let job = self.jobs[id] else { self.lock.unlock(); return }
            if stdout { job.stdoutClosed = true } else { job.stderrClosed = true }
            let ready = job.processClosed && job.stdoutClosed && job.stderrClosed && !job.settled
            self.lock.unlock()
            if ready { self.complete(id: id) }
        }
    }

    private func complete(id: Int) {
        lock.lock()
        guard !invalidated, let job = jobs[id], job.processClosed, job.stdoutClosed, job.stderrClosed, !job.settled else {
            lock.unlock()
            return
        }
        job.settled = true
        jobs.removeValue(forKey: id)
        let failure = job.failure
        let status = job.terminationStatus
        let reason = job.terminationReason
        let stdout = job.stdout
        let stderr = job.stderr
        lock.unlock()
        job.timeoutItem?.cancel()
        emit(job: job, failure: failure, status: status, reason: reason, stdout: stdout, stderr: stderr)
    }

    private func failEarly(_ job: ExecJob, _ failure: ExecFailure) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let dead = self.invalidated
            self.lock.unlock()
            guard !dead else { return }
            self.emit(job: job, failure: failure, status: 0, reason: .exit, stdout: Data(), stderr: Data())
        }
    }

    private func emit(job: ExecJob, failure: ExecFailure?, status: Int32, reason: Process.TerminationReason, stdout: Data, stderr: Data) {
        guard let context = job.callback.context else { return }
        let out = encoded(stdout, encoding: job.encoding, in: context)
        let err = encoded(stderr, encoding: job.encoding, in: context)
        guard let failure else {
            if reason == .uncaughtSignal || status != 0 {
                let meta = JSValue(newObjectIn: context)!
                if reason == .uncaughtSignal {
                    meta.setObject("signal", forKeyedSubscript: "kind" as NSString)
                    meta.setObject(NSNull(), forKeyedSubscript: "code" as NSString)
                    meta.setObject(JSValue(bool: true, in: context), forKeyedSubscript: "killed" as NSString)
                    meta.setObject(signalNames[status] ?? "SIG\(status)", forKeyedSubscript: "signal" as NSString)
                } else {
                    meta.setObject("exit", forKeyedSubscript: "kind" as NSString)
                    meta.setObject(NSNumber(value: status), forKeyedSubscript: "code" as NSString)
                    meta.setObject(JSValue(bool: false, in: context), forKeyedSubscript: "killed" as NSString)
                    meta.setObject(NSNull(), forKeyedSubscript: "signal" as NSString)
                }
                meta.setObject(String(decoding: stderr, as: UTF8.self), forKeyedSubscript: "stderrText" as NSString)
                _ = job.callback.call(withArguments: [meta, out, err])
                return
            }
            _ = job.callback.call(withArguments: [JSValue(nullIn: context)!, out, err])
            return
        }
        let meta = JSValue(newObjectIn: context)!
        meta.setObject(String(decoding: stderr, as: UTF8.self), forKeyedSubscript: "stderrText" as NSString)
        switch failure {
        case .abort:
            meta.setObject("abort", forKeyedSubscript: "kind" as NSString)
        case .timeout:
            meta.setObject("timeout", forKeyedSubscript: "kind" as NSString)
            meta.setObject(NSNull(), forKeyedSubscript: "code" as NSString)
            meta.setObject(JSValue(bool: true, in: context), forKeyedSubscript: "killed" as NSString)
            meta.setObject(job.killSignalName, forKeyedSubscript: "signal" as NSString)
        case .maxBuffer(let stream):
            meta.setObject("maxbuffer", forKeyedSubscript: "kind" as NSString)
            meta.setObject(stream, forKeyedSubscript: "stream" as NSString)
            meta.setObject("ERR_CHILD_PROCESS_STDIO_MAXBUFFER", forKeyedSubscript: "code" as NSString)
            meta.setObject(JSValue(bool: true, in: context), forKeyedSubscript: "killed" as NSString)
            meta.setObject(job.killSignalName, forKeyedSubscript: "signal" as NSString)
        case .spawn(let message, let code, let syscall, let path):
            meta.setObject("spawn", forKeyedSubscript: "kind" as NSString)
            meta.setObject(message, forKeyedSubscript: "message" as NSString)
            meta.setObject(code, forKeyedSubscript: "code" as NSString)
            meta.setObject(syscall, forKeyedSubscript: "syscall" as NSString)
            meta.setObject(path, forKeyedSubscript: "path" as NSString)
        }
        _ = job.callback.call(withArguments: [meta, out, err])
    }

    private func signal(_ job: ExecJob, sig: Int32) {
        guard job.process.isRunning else { return }
        let pid = job.process.processIdentifier
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, sig)
    }

    private func environment(from value: JSValue?) -> [String: String]? {
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        var env: [String: String] = [:]
        guard value.isObject, let length = value.forProperty("length")?.toInt32(), length > 0 else { return env }
        for index in 0..<length {
            guard let pair = value.objectAtIndexedSubscript(Int(index)) else { continue }
            let name = pair.objectAtIndexedSubscript(0).toString() ?? ""
            let item = pair.objectAtIndexedSubscript(1).toString() ?? ""
            if !name.isEmpty { env[name] = item }
        }
        return env
    }

    private func encoded(_ data: Data, encoding: String, in context: JSContext) -> JSValue {
        switch encoding {
        case "buffer":
            let buffer = arrayBuffer(from: data, in: context)
            return context.objectForKeyedSubscript("Uint8Array").construct(withArguments: [buffer])
        case "hex":
            return JSValue(object: data.map { String(format: "%02x", $0) }.joined(), in: context)
        case "base64":
            return JSValue(object: data.base64EncodedString(), in: context)
        case "latin1", "binary":
            return JSValue(object: String(data: data, encoding: .isoLatin1) ?? "", in: context)
        case "ascii":
            let masked = Data(data.map { $0 & 0x7F })
            return JSValue(object: String(data: masked, encoding: .ascii) ?? "", in: context)
        default:
            return JSValue(object: String(decoding: data, as: UTF8.self), in: context)
        }
    }

    private func arrayBuffer(from data: Data, in context: JSContext) -> JSValue {
        if data.isEmpty { return context.evaluateScript("new ArrayBuffer(0)")! }
        let pointer = malloc(data.count)!
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        var exception: JSValueRef?
        guard let ref = JSObjectMakeArrayBufferWithBytesNoCopy(context.jsGlobalContextRef, pointer, data.count, { _, bytes in
            free(bytes)
        }, nil, &exception), exception == nil else {
            free(pointer)
            return context.evaluateScript("new ArrayBuffer(0)")!
        }
        return JSValue(jsValueRef: ref, in: context)
    }
}

private enum ExecFailure: Equatable {
    case abort
    case timeout
    case maxBuffer(String)
    case spawn(message: String, code: String, syscall: String, path: String)
}

private final class ExecJob {
    let id: Int
    let callback: JSValue
    let command: String
    let shell: String
    let encoding: String
    let killSignalName: String
    let killSignal: Int32
    let maxBuffer: Int
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    var stdout = Data()
    var stderr = Data()
    var stdoutClosed = false
    var stderrClosed = false
    var processClosed = false
    var terminationStatus: Int32 = 0
    var terminationReason: Process.TerminationReason = .exit
    var failure: ExecFailure?
    var timeoutItem: DispatchWorkItem?
    var settled = false

    init(id: Int, callback: JSValue, command: String, shell: String, encoding: String, killSignalName: String, killSignal: Int32, maxBuffer: Int) {
        self.id = id
        self.callback = callback
        self.command = command
        self.shell = shell
        self.encoding = encoding
        self.killSignalName = killSignalName
        self.killSignal = killSignal
        self.maxBuffer = maxBuffer
    }

    func append(stdout isStdout: Bool, chunk: Data) -> Bool {
        let count = isStdout ? stdout.count : stderr.count
        let room = max(0, maxBuffer - count)
        let exceeded = chunk.count > room
        let piece = chunk.prefix(room)
        if !piece.isEmpty {
            if isStdout { stdout.append(piece) } else { stderr.append(piece) }
        }
        return exceeded
    }
}

private let signalNumbers: [String: Int32] = [
    "SIGHUP": SIGHUP, "SIGINT": SIGINT, "SIGQUIT": SIGQUIT, "SIGABRT": SIGABRT, "SIGKILL": SIGKILL,
    "SIGUSR1": SIGUSR1, "SIGUSR2": SIGUSR2, "SIGPIPE": SIGPIPE, "SIGALRM": SIGALRM, "SIGTERM": SIGTERM
]

private let signalNames: [Int32: String] = [
    SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGABRT: "SIGABRT", SIGKILL: "SIGKILL",
    SIGUSR1: "SIGUSR1", SIGUSR2: "SIGUSR2", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM"
]

private let commandExecuteSource = #"""
(() => {
  const nativeExecute = globalThis.__holaExecute;
  const nativeAbort = globalThis.__holaAbortExecute;
  delete globalThis.__holaExecute;
  delete globalThis.__holaAbortExecute;

  const encodings = ["utf8", "utf-8", "buffer", "hex", "base64", "latin1", "binary", "ascii"];
  const signalNames = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGABRT: 6, SIGKILL: 9, SIGUSR1: 10, SIGUSR2: 12, SIGPIPE: 13, SIGALRM: 14, SIGTERM: 15 };
  const signalNumbers = { 1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 6: "SIGABRT", 9: "SIGKILL", 10: "SIGUSR1", 12: "SIGUSR2", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM" };

  function normalizeSignal(value) {
    if (value === undefined) return "SIGTERM";
    if (typeof value === "number" && signalNumbers[value]) return signalNumbers[value];
    if (typeof value === "string" && signalNames[value]) return value;
    throw new TypeError("Unknown signal: " + value);
  }

  function parseExecute(command, options) {
    if (typeof command !== "string") {
      throw new TypeError("The \"command\" argument must be of type string. Received " + typeof command);
    }
    const opts = options === undefined ? {} : options;
    if (opts === null || typeof opts !== "object") throw new TypeError("The \"options\" argument must be of type object.");
    let cwd = "";
    if (opts.cwd !== undefined) {
      if (typeof opts.cwd !== "string") throw new TypeError("The \"options.cwd\" property must be of type string.");
      cwd = opts.cwd;
    }
    let shell = "/bin/sh";
    if (opts.shell !== undefined) {
      if (typeof opts.shell !== "string" || opts.shell.length === 0) throw new TypeError("The \"options.shell\" property must be a non-empty string.");
      shell = opts.shell;
    }
    let encoding = "utf8";
    if (opts.encoding !== undefined) {
      if (typeof opts.encoding !== "string") throw new TypeError("The \"options.encoding\" property must be of type string.");
      encoding = opts.encoding.toLowerCase();
      if (encodings.indexOf(encoding) < 0) throw new TypeError("Unknown encoding: " + opts.encoding);
    }
    let timeout = 0;
    if (opts.timeout !== undefined) {
      timeout = Number(opts.timeout);
      if (!Number.isFinite(timeout) || timeout < 0) throw new RangeError("Invalid timeout");
    }
    let maxBuffer = 1024 * 1024;
    if (opts.maxBuffer !== undefined) {
      maxBuffer = Number(opts.maxBuffer);
      if (!Number.isFinite(maxBuffer) || maxBuffer < 0) throw new RangeError("Invalid maxBuffer");
    }
    const killSignal = normalizeSignal(opts.killSignal);
    let env = null;
    if (opts.env !== undefined) {
      if (opts.env === null || typeof opts.env !== "object") throw new TypeError("The \"options.env\" property must be of type object.");
      env = [];
      Object.keys(opts.env).forEach((key) => {
        const value = opts.env[key];
        if (typeof value !== "string") throw new TypeError("The \"options.env." + key + "\" property must be of type string.");
        env.push([String(key), value]);
      });
    }
    let signal = null;
    if (opts.signal !== undefined && opts.signal !== null) {
      if (!(opts.signal instanceof AbortSignal)) throw new TypeError("The \"options.signal\" property must be an instance of AbortSignal.");
      signal = opts.signal;
    }
    return { command, cwd, shell, encoding, timeout, maxBuffer, killSignal, env, signal };
  }

  function toExecError(meta, stdout, stderr, command) {
    if (meta.kind === "abort") {
      const error = new DOMException("The operation was aborted.", "AbortError");
      error.stdout = stdout;
      error.stderr = stderr;
      error.cmd = command;
      return error;
    }
    let message = meta.message || "";
    if (meta.kind === "maxbuffer") message = meta.stream + " maxBuffer length exceeded";
    if (meta.kind === "exit" || meta.kind === "timeout" || meta.kind === "signal") {
      message = "Command failed: " + command + "\n" + (meta.stderrText || "");
    }
    const error = new Error(message);
    error.code = meta.code === undefined ? null : meta.code;
    error.killed = !!meta.killed;
    error.signal = meta.signal || null;
    error.cmd = command;
    if (meta.syscall) error.syscall = meta.syscall;
    if (meta.path) error.path = meta.path;
    error.stdout = stdout;
    error.stderr = stderr;
    return error;
  }

  function execute(command, options) {
    let parsed;
    try { parsed = parseExecute(command, options); }
    catch (error) { return Promise.reject(error); }
    if (parsed.signal && parsed.signal.aborted) {
      return Promise.reject(parsed.signal.reason || new DOMException("The operation was aborted.", "AbortError"));
    }
    return new Promise((resolve, reject) => {
      let settled = false;
      const rejectOnce = (error) => { if (!settled) { settled = true; reject(error); } };
      const resolveOnce = (value) => { if (!settled) { settled = true; resolve(value); } };
      const handle = { id: 0 };
      const signal = parsed.signal;
      const onAbort = () => {
        if (signal) signal.removeEventListener("abort", onAbort);
        if (handle.id) nativeAbort(handle.id);
        rejectOnce(signal && signal.reason ? signal.reason : new DOMException("The operation was aborted.", "AbortError"));
      };
      if (signal) signal.addEventListener("abort", onAbort);
      try {
        handle.id = nativeExecute({
          command: parsed.command,
          cwd: parsed.cwd,
          shell: parsed.shell,
          encoding: parsed.encoding,
          timeout: parsed.timeout,
          maxBuffer: parsed.maxBuffer,
          killSignal: parsed.killSignal,
          env: parsed.env
        }, (meta, stdout, stderr) => {
          if (signal) signal.removeEventListener("abort", onAbort);
          if (settled) return;
          if (meta) rejectOnce(toExecError(meta, stdout, stderr, parsed.command));
          else resolveOnce({ stdout: stdout, stderr: stderr });
        });
      } catch (error) {
        rejectOnce(error);
      }
      if (signal && signal.aborted) onAbort();
    });
  }

  Object.assign(globalThis, { execute });
})();
"""#
