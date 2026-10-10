import CryptoKit
import Foundation
import JavaScriptCore

// 指令脚本里的 fetch。JavaScriptCore 没有浏览器网络 API，这里用 URLSession 补上 Fetch 标准的脚本表面：
// fetch、Headers、Request、Response、AbortController、AbortSignal、FormData、Blob、File、URLSearchParams、DOMException、ReadableStream。
// 这是本地特权脚本，不套用浏览器的 CORS 过滤；redirect: "manual" 返回 3xx 本身，方便读取 Location。
// 调用约定、错误类型和示例写在 Commands.swift 的「指令脚本宿主扩展」注释里，供写指令脚本时直接对照。
// execute 在 CommandExecute.swift，对齐 Node.js child_process.exec 的 Promise 形式。
final class CommandFetchBridge: NSObject, URLSessionTaskDelegate {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private weak var context: JSContext?
    private var invalidated = false
    private var sessionStorage: URLSession?
    private var jobs: [Int: Job] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimer = 1

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func install(into context: JSContext) {
        self.context = context
        let parse: @convention(block) (String) -> String = { raw in
            parseFetchURL(raw)?.absoluteString ?? ""
        }
        let encode: @convention(block) (String) -> JSValue = { [weak self] string in
            arrayBuffer(from: Data(string.utf8), in: self!.context!)
        }
        let decode: @convention(block) (JSValue, String) -> String = { value, charset in
            decodeFetchText(data(from: value) ?? Data(), charset: charset)
        }
        let start: @convention(block) (JSValue, JSValue) -> Int32 = { [weak self] request, callback in
            Int32(self?.start(request, callback: callback) ?? 0)
        }
        let abort: @convention(block) (Int32) -> Void = { [weak self] id in
            self?.abort(id: Int(id))
        }
        let setTimer: @convention(block) (Double, JSValue) -> Int32 = { [weak self] delay, callback in
            Int32(self?.setTimer(milliseconds: delay, callback: callback) ?? 0)
        }
        let clearTimer: @convention(block) (Int32) -> Void = { [weak self] id in
            self?.clearTimer(id: Int(id))
        }
        context.setObject(parse, forKeyedSubscript: "__holaParseURL" as NSString)
        context.setObject(encode, forKeyedSubscript: "__holaEncodeUTF8" as NSString)
        context.setObject(decode, forKeyedSubscript: "__holaDecodeText" as NSString)
        context.setObject(start, forKeyedSubscript: "__holaFetch" as NSString)
        context.setObject(abort, forKeyedSubscript: "__holaAbortFetch" as NSString)
        context.setObject(setTimer, forKeyedSubscript: "__holaSetTimer" as NSString)
        context.setObject(clearTimer, forKeyedSubscript: "__holaClearTimer" as NSString)
        context.evaluateScript(commandFetchSource)
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let running = jobs.values.map(\.task)
        jobs.removeAll()
        let pending = Array(timers.values)
        timers.removeAll()
        let session = sessionStorage
        sessionStorage = nil
        lock.unlock()
        pending.forEach { $0.cancel() }
        running.forEach { $0.cancel() }
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        guard let job = jobs[task.taskIdentifier] else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        job.redirectCount += 1
        let mode = job.redirectMode
        let count = job.redirectCount
        if mode == "follow", count <= 20 {
            job.redirected = true
            lock.unlock()
            completionHandler(request)
            return
        }
        lock.unlock()
        completionHandler(nil)
    }

    private func start(_ request: JSValue, callback: JSValue) -> Int {
        let urlString = request.forProperty("url")?.toString() ?? ""
        let method = request.forProperty("method")?.toString() ?? "GET"
        let redirect = request.forProperty("redirect")?.toString() ?? "follow"
        let cache = request.forProperty("cache")?.toString() ?? "default"
        let integrity = request.forProperty("integrity")?.toString() ?? ""
        let headers = stringPairs(from: request.forProperty("headers"))
        let body = request.forProperty("body").flatMap { data(from: $0) }
        guard let url = parseFetchURL(urlString) else {
            fail(callback, name: "TypeError", message: "Failed to parse URL from \(urlString)")
            return 0
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.cachePolicy = cachePolicy(cache)
        urlRequest.timeoutInterval = 30
        urlRequest.httpShouldHandleCookies = false
        let hasContentType = headers.contains { $0.0.lowercased() == "content-type" }
        for (name, value) in headers where !automaticHeaders.contains(name.lowercased()) {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        if let body {
            urlRequest.httpBody = body
            // URLSession 会给带 body 且未声明类型的请求补上表单类型。空值用来压住这个默认值，避免和 Fetch 不一致。
            if !hasContentType {
                urlRequest.setValue("", forHTTPHeaderField: "Content-Type")
            }
        }
        let box = IDBox()
        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            let id = box.id
            self?.queue.async {
                self?.complete(id: id, data: data, response: response, error: error)
            }
        }
        box.id = task.taskIdentifier
        let job = Job(callback: callback, task: task, method: method.uppercased(), redirectMode: redirect, integrity: integrity)
        lock.lock()
        jobs[task.taskIdentifier] = job
        lock.unlock()
        task.resume()
        return task.taskIdentifier
    }

    private func abort(id: Int) {
        lock.lock()
        let job = jobs[id]
        job?.aborted = true
        lock.unlock()
        job?.task.cancel()
    }

    private func complete(id: Int, data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        let job = jobs.removeValue(forKey: id)
        let dead = invalidated
        lock.unlock()
        guard let job, !dead else { return }
        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                if job.aborted {
                    fail(job.callback, name: "AbortError", message: "The operation was aborted.")
                }
                return
            }
            fail(job.callback, name: "TypeError", message: "Failed to fetch: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else {
            fail(job.callback, name: "TypeError", message: "Failed to fetch")
            return
        }
        let redirectFailed = job.redirectMode == "error" && (job.redirectCount > 0 || (300..<400).contains(http.statusCode))
        if redirectFailed {
            fail(job.callback, name: "TypeError", message: "Failed to fetch")
            return
        }
        if job.redirectMode == "follow", job.redirectCount > 20 {
            fail(job.callback, name: "TypeError", message: "Failed to fetch: too many redirects")
            return
        }
        let payload = data ?? Data()
        if !job.integrity.isEmpty, !integrityMatches(job.integrity, data: payload) {
            fail(job.callback, name: "TypeError", message: "Failed to fetch: integrity mismatch")
            return
        }
        let nullBody = job.method == "HEAD" || nullBodyStatuses.contains(http.statusCode)
        succeed(job, response: http, body: nullBody ? nil : payload)
    }

    private func succeed(_ job: Job, response: HTTPURLResponse, body: Data?) {
        guard let context = job.callback.context else { return }
        let meta = JSValue(newObjectIn: context)!
        meta.setObject(response.url?.absoluteString ?? "", forKeyedSubscript: "url" as NSString)
        meta.setObject(NSNumber(value: response.statusCode), forKeyedSubscript: "status" as NSString)
        meta.setObject(reasonPhrase(response.statusCode), forKeyedSubscript: "statusText" as NSString)
        meta.setObject(JSValue(bool: job.redirected, in: context), forKeyedSubscript: "redirected" as NSString)
        meta.setObject("basic", forKeyedSubscript: "type" as NSString)
        meta.setObject(headerArray(response, in: context), forKeyedSubscript: "headers" as NSString)
        let bodyValue = body.map { arrayBuffer(from: $0, in: context) } ?? JSValue(nullIn: context)!
        _ = job.callback.call(withArguments: [JSValue(nullIn: context)!, meta, bodyValue])
    }

    private func fail(_ callback: JSValue, name: String, message: String) {
        guard let context = callback.context else { return }
        let error = JSValue(newObjectIn: context)!
        error.setObject(name, forKeyedSubscript: "name" as NSString)
        error.setObject(message, forKeyedSubscript: "message" as NSString)
        _ = callback.call(withArguments: [error, JSValue(nullIn: context)!, JSValue(nullIn: context)!])
    }

    private var session: URLSession {
        if let sessionStorage { return sessionStorage }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionStorage = created
        return created
    }

    private func setTimer(milliseconds: Double, callback: JSValue) -> Int {
        let id = nextTimer
        nextTimer += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pending = self.timers.removeValue(forKey: id)
            let dead = self.invalidated
            self.lock.unlock()
            guard pending != nil, !dead else { return }
            self.queue.async {
                guard !self.invalidated else { return }
                _ = callback.call(withArguments: [])
            }
        }
        lock.lock()
        timers[id] = work
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: work)
        return id
    }

    private func clearTimer(id: Int) {
        lock.lock()
        let work = timers.removeValue(forKey: id)
        lock.unlock()
        work?.cancel()
    }
}

private final class Job {
    let callback: JSValue
    let task: URLSessionTask
    let method: String
    let redirectMode: String
    let integrity: String
    var redirectCount = 0
    var redirected = false
    var aborted = false

    init(callback: JSValue, task: URLSessionTask, method: String, redirectMode: String, integrity: String) {
        self.callback = callback
        self.task = task
        self.method = method
        self.redirectMode = redirectMode
        self.integrity = integrity
    }
}

private final class IDBox {
    var id = 0
}

private let automaticHeaders: Set<String> = ["content-length", "transfer-encoding", "host", "connection"]
private let nullBodyStatuses: Set<Int> = [101, 204, 205, 304]

private func parseFetchURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil else { return nil }
    return url
}

private func cachePolicy(_ cache: String) -> URLRequest.CachePolicy {
    switch cache {
    case "no-store", "reload":
        return .reloadIgnoringLocalAndRemoteCacheData
    case "no-cache":
        return .reloadRevalidatingCacheData
    case "force-cache":
        return .returnCacheDataElseLoad
    case "only-if-cached":
        return .returnCacheDataDontLoad
    default:
        return .useProtocolCachePolicy
    }
}

private func stringPairs(from value: JSValue?) -> [(String, String)] {
    guard let value, value.isObject, let length = value.forProperty("length")?.toInt32(), length > 0 else { return [] }
    var pairs: [(String, String)] = []
    for index in 0..<length {
        guard let pair = value.objectAtIndexedSubscript(Int(index)) else { continue }
        let name = pair.objectAtIndexedSubscript(0).toString() ?? ""
        let headerValue = pair.objectAtIndexedSubscript(1).toString() ?? ""
        if !name.isEmpty { pairs.append((name, headerValue)) }
    }
    return pairs
}

private func data(from value: JSValue) -> Data? {
    if value.isNull || value.isUndefined { return nil }
    let context = value.context!
    let global = context.jsGlobalContextRef
    var exception: JSValueRef?
    if value.isInstance(of: context.objectForKeyedSubscript("ArrayBuffer")) {
        let length = JSObjectGetArrayBufferByteLength(global, value.jsValueRef, &exception)
        guard exception == nil, let bytes = JSObjectGetArrayBufferBytesPtr(global, value.jsValueRef, &exception), exception == nil else { return nil }
        return length == 0 ? Data() : Data(bytes: bytes, count: length)
    }
    guard let buffer = value.forProperty("buffer"), buffer.isInstance(of: context.objectForKeyedSubscript("ArrayBuffer")) else { return nil }
    exception = nil
    let offset = Int(value.forProperty("byteOffset")?.toInt32() ?? 0)
    let viewLength = Int(value.forProperty("byteLength")?.toInt32() ?? 0)
    let bufferLength = JSObjectGetArrayBufferByteLength(global, buffer.jsValueRef, &exception)
    guard exception == nil, let bytes = JSObjectGetArrayBufferBytesPtr(global, buffer.jsValueRef, &exception), exception == nil else { return nil }
    let start = min(max(0, offset), bufferLength)
    let count = min(max(0, viewLength), bufferLength - start)
    return count == 0 ? Data() : Data(bytes: bytes.advanced(by: start), count: count)
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

private func decodeFetchText(_ data: Data, charset: String) -> String {
    let name = charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let encoding: String.Encoding
    switch name {
    case "utf-8", "utf8", "unicode-1-1-utf-8":
        encoding = .utf8
    case "utf-16le", "utf-16":
        encoding = .utf16LittleEndian
    case "utf-16be":
        encoding = .utf16BigEndian
    case "iso-8859-1", "latin1", "latin-1":
        encoding = .isoLatin1
    case "us-ascii", "ascii":
        encoding = .ascii
    case "windows-1252", "cp1252":
        encoding = .windowsCP1252
    default:
        encoding = .utf8
    }
    var bytes = data
    if encoding == .utf8, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    if encoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
    return String(data: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
}

private func headerArray(_ response: HTTPURLResponse, in context: JSContext) -> JSValue {
    let array = JSValue(newArrayIn: context)!
    var index = 0
    for (key, value) in response.allHeaderFields {
        let pair = JSValue(newArrayIn: context)!
        pair.setObject(String(describing: key), atIndexedSubscript: 0)
        pair.setObject(String(describing: value), atIndexedSubscript: 1)
        array.setObject(pair, atIndexedSubscript: index)
        index += 1
    }
    return array
}

private func integrityMatches(_ metadata: String, data: Data) -> Bool {
    let tokens = metadata.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }.map(String.init)
    if tokens.isEmpty { return true }
    let rank = ["sha256": 1, "sha384": 2, "sha512": 3]
    struct Item { let algorithm: String; let digest: Data }
    var items: [Item] = []
    for token in tokens {
        let pieces = token.split(separator: "-", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { continue }
        let hash = pieces[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? pieces[1]
        guard let digest = Data(base64Encoded: hash) else { continue }
        items.append(Item(algorithm: pieces[0].lowercased(), digest: digest))
    }
    let supported = items.filter { rank[$0.algorithm] != nil }
    guard let best = supported.compactMap({ rank[$0.algorithm] }).max() else { return false }
    let chosen = supported.filter { rank[$0.algorithm] == best }
    guard let actual = digest(algorithm: chosen[0].algorithm, data: data) else { return false }
    return chosen.contains { $0.digest == actual }
}

private func digest(algorithm: String, data: Data) -> Data? {
    switch algorithm {
    case "sha256":
        return Data(SHA256.hash(data: data))
    case "sha384":
        return Data(SHA384.hash(data: data))
    case "sha512":
        return Data(SHA512.hash(data: data))
    default:
        return nil
    }
}

private func reasonPhrase(_ status: Int) -> String {
    let phrases = [
        100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted",
        204: "No Content", 205: "Reset Content", 206: "Partial Content", 301: "Moved Permanently", 302: "Found",
        303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        408: "Request Timeout", 409: "Conflict", 410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type",
        422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
        502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"
    ]
    return phrases[status] ?? ""
}

private let commandFetchSource = #"""
(() => {
  const nativeParseURL = globalThis.__holaParseURL;
  const nativeEncode = globalThis.__holaEncodeUTF8;
  const nativeDecode = globalThis.__holaDecodeText;
  const nativeFetch = globalThis.__holaFetch;
  const nativeAbort = globalThis.__holaAbortFetch;
  const nativeSetTimer = globalThis.__holaSetTimer;
  const nativeClearTimer = globalThis.__holaClearTimer;
  ["__holaParseURL", "__holaEncodeUTF8", "__holaDecodeText", "__holaFetch", "__holaAbortFetch", "__holaSetTimer", "__holaClearTimer"].forEach((name) => {
    delete globalThis[name];
  });

  function utf8(value) {
    return nativeEncode(String(value));
  }
  function decode(bytes, charset) {
    if (!bytes) return "";
    return nativeDecode(bytes, charset || "utf-8");
  }
  function concatBytes(buffers) {
    let total = 0;
    buffers.forEach((buffer) => { total += buffer.byteLength; });
    const out = new Uint8Array(total);
    let offset = 0;
    buffers.forEach((buffer) => {
      out.set(new Uint8Array(buffer), offset);
      offset += buffer.byteLength;
    });
    return out.buffer;
  }
  function indexOfBytes(haystack, needle, start) {
    if (!needle.length) return start;
    outer: for (let i = start; i <= haystack.length - needle.length; i += 1) {
      for (let j = 0; j < needle.length; j += 1) if (haystack[i + j] !== needle[j]) continue outer;
      return i;
    }
    return -1;
  }
  function parseURL(input) {
    const absolute = nativeParseURL(String(input));
    if (!absolute) throw new TypeError("Failed to parse URL from " + input);
    return absolute;
  }
  function normalizeHeaderName(name) {
    const text = String(name);
    if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(text)) throw new TypeError("Invalid header name");
    return text.toLowerCase();
  }
  function normalizeHeaderValue(value) {
    const text = String(value);
    if (/[\0\r\n]/.test(text)) throw new TypeError("Invalid header value");
    return text.replace(/^[\t ]+|[\t ]+$/g, "");
  }
  function normalizeMethod(method) {
    const text = String(method);
    if (/^(CONNECT|TRACE|TRACK)$/i.test(text)) throw new TypeError("'" + text + "' HTTP method is unsupported.");
    if (/^(DELETE|GET|HEAD|OPTIONS|POST|PUT)$/i.test(text)) return text.toUpperCase();
    if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(text)) throw new TypeError("Invalid method");
    return text;
  }
  function oneOf(value, allowed, fallback, message) {
    if (value === undefined) return fallback;
    const text = String(value);
    if (allowed.indexOf(text) < 0) throw new TypeError(message);
    return text;
  }
  function readBytes(owner) {
    if (owner._bodyUsed) return Promise.reject(new TypeError("Body is unusable: body stream already read"));
    owner._bodyUsed = true;
    return Promise.resolve(owner._bytes || null);
  }

  class DOMException extends Error {
    constructor(message = "", name = "Error") {
      super(message);
      this.name = name;
      this.code = DOMException.codes[name] || 0;
    }
  }
  DOMException.codes = { IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5, NoModificationAllowedError: 7, NotFoundError: 8, NotSupportedError: 9, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13, NamespaceError: 14, InvalidAccessError: 15, TypeMismatchError: 17, SecurityError: 18, NetworkError: 19, AbortError: 20, URLMismatchError: 21, QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25 };

  class AbortSignal {
    constructor() {
      this.aborted = false;
      this.reason = undefined;
      this.onabort = null;
      this._listeners = [];
    }
    addEventListener(type, listener) {
      if (type === "abort" && typeof listener === "function") this._listeners.push(listener);
    }
    removeEventListener(type, listener) {
      if (type !== "abort") return;
      this._listeners = this._listeners.filter((item) => item !== listener);
    }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    _abort(reason) {
      if (this.aborted) return;
      this.aborted = true;
      this.reason = reason === undefined ? new DOMException("The operation was aborted.", "AbortError") : reason;
      const event = { type: "abort", target: this };
      if (typeof this.onabort === "function") this.onabort.call(this, event);
      this._listeners.slice().forEach((listener) => listener.call(this, event));
    }
    static abort(reason) {
      const signal = new AbortSignal();
      signal._abort(reason === undefined ? new DOMException("The operation was aborted.", "AbortError") : reason);
      return signal;
    }
    static timeout(milliseconds) {
      const signal = new AbortSignal();
      const reason = new DOMException("The operation was aborted due to timeout", "TimeoutError");
      const id = nativeSetTimer(Number(milliseconds), () => {
        nativeClearTimer(id);
        signal._abort(reason);
      });
      return signal;
    }
  }

  class AbortController {
    constructor() { this.signal = new AbortSignal(); }
    abort(reason) {
      this.signal._abort(reason === undefined ? new DOMException("The operation was aborted.", "AbortError") : reason);
    }
  }

  class Headers {
    constructor(init) {
      this._list = [];
      this._guard = "none";
      if (init == null) return;
      if (init instanceof Headers) {
        this._list = init._list.map((pair) => pair.slice());
        return;
      }
      if (typeof init !== "object") throw new TypeError("Invalid headers");
      if (typeof init[Symbol.iterator] === "function") {
        for (const pair of init) {
          const values = Array.from(pair);
          if (values.length !== 2) throw new TypeError("Invalid header");
          this.append(values[0], values[1]);
        }
        return;
      }
      Object.keys(init).forEach((name) => this.append(name, init[name]));
    }
    _mutable() {
      if (this._guard === "immutable" || this._guard === "response") throw new TypeError("Headers are immutable");
    }
    append(name, value) {
      this._mutable();
      this._list.push([normalizeHeaderName(name), normalizeHeaderValue(value)]);
    }
    delete(name) {
      this._mutable();
      const normalized = normalizeHeaderName(name);
      this._list = this._list.filter((pair) => pair[0] !== normalized);
    }
    get(name) {
      const normalized = normalizeHeaderName(name);
      const values = this._list.filter((pair) => pair[0] === normalized).map((pair) => pair[1]);
      return values.length ? values.join(", ") : null;
    }
    getSetCookie() {
      return this._list.filter((pair) => pair[0] === "set-cookie").map((pair) => pair[1]);
    }
    has(name) { return this.get(name) !== null; }
    set(name, value) {
      this.delete(name);
      this.append(name, value);
    }
    forEach(callback, thisArg) {
      if (typeof callback !== "function") throw new TypeError("Invalid callback");
      this._list.slice().forEach((pair) => callback.call(thisArg, pair[1], pair[0], this));
    }
    *entries() { for (const pair of this._list) yield pair.slice(); }
    *keys() { for (const [name] of this.entries()) yield name; }
    *values() { for (const [, value] of this.entries()) yield value; }
    [Symbol.iterator]() { return this.entries(); }
  }

  class Blob {
    constructor(parts = [], options = {}) {
      const buffers = Array.from(parts).map((part) => {
        if (typeof part === "string") return utf8(part);
        if (part instanceof Blob) return part._bytes;
        if (part instanceof ArrayBuffer) return part;
        if (ArrayBuffer.isView(part)) return part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength);
        throw new TypeError("Invalid Blob part");
      });
      this._bytes = concatBytes(buffers);
      this._type = String((options && options.type) || "").toLowerCase();
    }
    get size() { return this._bytes.byteLength; }
    get type() { return this._type; }
    slice(start, end, type) {
      const view = new Uint8Array(this._bytes);
      return new Blob([view.slice(start, end)], { type: type === undefined ? this._type : type });
    }
    arrayBuffer() { return Promise.resolve(this._bytes.slice(0)); }
    text() { return Promise.resolve(decode(this._bytes, "utf-8")); }
  }

  class File extends Blob {
    constructor(parts, name, options = {}) {
      super(parts, options);
      this._name = String(name);
      this._lastModified = options.lastModified === undefined ? Date.now() : Number(options.lastModified);
    }
    get name() { return this._name; }
    get lastModified() { return this._lastModified; }
  }

  function urlEncode(value) {
    const bytes = new Uint8Array(utf8(value));
    let out = "";
    bytes.forEach((byte) => {
      const plain = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte === 0x2A || byte === 0x2D || byte === 0x2E || byte === 0x5F;
      if (byte === 0x20) out += "+";
      else if (plain) out += String.fromCharCode(byte);
      else out += "%" + byte.toString(16).toUpperCase().padStart(2, "0");
    });
    return out;
  }
  function urlDecode(value) {
    try { return decodeURIComponent(String(value).replace(/\+/g, " ")); }
    catch (error) { return String(value).replace(/\+/g, " "); }
  }

  class URLSearchParams {
    constructor(init) {
      this._list = [];
      if (init == null) return;
      if (typeof init === "string") {
        const text = init.charAt(0) === "?" ? init.slice(1) : init;
        if (!text) return;
        text.split("&").forEach((pair) => {
          const index = pair.indexOf("=");
          const name = index < 0 ? pair : pair.slice(0, index);
          const value = index < 0 ? "" : pair.slice(index + 1);
          this.append(urlDecode(name), urlDecode(value));
        });
        return;
      }
      if (init instanceof URLSearchParams) {
        this._list = init._list.map((pair) => pair.slice());
        return;
      }
      if (typeof init === "object" && typeof init[Symbol.iterator] === "function") {
        for (const pair of init) {
          const values = Array.from(pair);
          this.append(values[0], values[1]);
        }
        return;
      }
      if (typeof init === "object") Object.keys(init).forEach((name) => this.append(name, init[name]));
    }
    append(name, value) { this._list.push([String(name), String(value)]); }
    delete(name) { this._list = this._list.filter((pair) => pair[0] !== String(name)); }
    get(name) {
      const found = this._list.find((pair) => pair[0] === String(name));
      return found ? found[1] : null;
    }
    getAll(name) { return this._list.filter((pair) => pair[0] === String(name)).map((pair) => pair[1]); }
    has(name) { return this.get(name) !== null; }
    set(name, value) { this.delete(name); this.append(name, value); }
    sort() { this._list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)); }
    toString() { return this._list.map((pair) => urlEncode(pair[0]) + "=" + urlEncode(pair[1])).join("&"); }
    forEach(callback, thisArg) { this._list.slice().forEach((pair) => callback.call(thisArg, pair[1], pair[0], this)); }
    *entries() { for (const pair of this._list) yield pair.slice(); }
    *keys() { for (const [name] of this.entries()) yield name; }
    *values() { for (const [, value] of this.entries()) yield value; }
    [Symbol.iterator]() { return this.entries(); }
  }

  function escapeQuoted(value) {
    return String(value).replace(/[\r\n"]/g, "");
  }
  class FormData {
    constructor() { this._entries = []; }
    _entry(name, value, filename) {
      const field = String(name);
      if (value instanceof Blob) {
        return {
          name: field,
          filename: filename === undefined ? (value instanceof File ? value.name : "blob") : String(filename),
          type: value.type,
          bytes: value._bytes
        };
      }
      return { name: field, filename: null, type: "", bytes: utf8(value) };
    }
    append(name, value, filename) { this._entries.push(this._entry(name, value, filename)); }
    set(name, value, filename) {
      const entry = this._entry(name, value, filename);
      this._entries = this._entries.filter((item) => item.name !== entry.name);
      this._entries.push(entry);
    }
    delete(name) { this._entries = this._entries.filter((item) => item.name !== String(name)); }
    get(name) {
      const found = this._entries.find((item) => item.name === String(name));
      if (!found) return null;
      return found.filename == null ? decode(found.bytes, "utf-8") : new File([found.bytes], found.filename, { type: found.type });
    }
    getAll(name) { return this._entries.filter((item) => item.name === String(name)).map((item) => this._value(item)); }
    has(name) { return this._entries.some((item) => item.name === String(name)); }
    _value(entry) {
      return entry.filename == null ? decode(entry.bytes, "utf-8") : new File([entry.bytes], entry.filename, { type: entry.type });
    }
    forEach(callback, thisArg) { this._entries.slice().forEach((entry) => callback.call(thisArg, this._value(entry), entry.name, this)); }
    *entries() { for (const entry of this._entries) yield [entry.name, this._value(entry)]; }
    *keys() { for (const [name] of this.entries()) yield name; }
    *values() { for (const [, value] of this.entries()) yield value; }
    [Symbol.iterator]() { return this.entries(); }
    _encode() {
      const boundary = "----HolaFormBoundary" + Math.random().toString(36).slice(2) + Date.now().toString(36);
      const chunks = [];
      this._entries.forEach((entry) => {
        let disposition = 'Content-Disposition: form-data; name="' + escapeQuoted(entry.name) + '"';
        if (entry.filename != null) disposition += '; filename="' + escapeQuoted(entry.filename) + '"';
        let head = "--" + boundary + "\r\n" + disposition + "\r\n";
        if (entry.filename != null && entry.type) head += "Content-Type: " + entry.type + "\r\n";
        head += "\r\n";
        chunks.push(utf8(head));
        chunks.push(entry.bytes);
        chunks.push(utf8("\r\n"));
      });
      chunks.push(utf8("--" + boundary + "--\r\n"));
      return { bytes: concatBytes(chunks), boundary };
    }
  }

  function fillMultipart(form, bytes, contentType) {
    const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
    if (!match) throw new TypeError("Missing multipart boundary");
    const marker = new Uint8Array(utf8("--" + (match[1] || match[2]).trim()));
    const source = new Uint8Array(bytes);
    let cursor = indexOfBytes(source, marker, 0);
    if (cursor < 0) throw new TypeError("Invalid multipart body");
    while (cursor >= 0) {
      cursor += marker.length;
      if (source[cursor] === 0x2D && source[cursor + 1] === 0x2D) break;
      if (source[cursor] === 0x0D && source[cursor + 1] === 0x0A) cursor += 2;
      const next = indexOfBytes(source, marker, cursor);
      if (next < 0) break;
      let partEnd = next;
      if (partEnd >= 2 && source[partEnd - 2] === 0x0D && source[partEnd - 1] === 0x0A) partEnd -= 2;
      const part = source.slice(cursor, partEnd);
      const headerEnd = indexOfBytes(part, new Uint8Array([13, 10, 13, 10]), 0);
      if (headerEnd < 0) throw new TypeError("Invalid multipart part");
      const headerText = decode(part.slice(0, headerEnd).buffer, "utf-8");
      const body = part.slice(headerEnd + 4).buffer;
      const nameMatch = /name="([^"]*)"/.exec(headerText) || /name=([^;\s]+)/.exec(headerText);
      if (!nameMatch) throw new TypeError("Missing multipart name");
      const fileMatch = /filename="([^"]*)"/.exec(headerText);
      const typeMatch = /content-type:\s*([^\r\n]+)/i.exec(headerText);
      if (fileMatch) form.append(nameMatch[1], new File([body], fileMatch[1], { type: typeMatch ? typeMatch[1].trim() : "" }));
      else form.append(nameMatch[1], decode(body, "utf-8"));
      cursor = next;
    }
  }

  function extractBody(body) {
    if (typeof body === "string") return { bytes: utf8(body), type: null };
    if (body instanceof URLSearchParams) return { bytes: utf8(body.toString()), type: "application/x-www-form-urlencoded;charset=UTF-8" };
    if (body instanceof FormData) {
      const encoded = body._encode();
      return { bytes: encoded.bytes, type: "multipart/form-data; boundary=" + encoded.boundary };
    }
    if (body instanceof Blob) return { bytes: body._bytes, type: body.type || null };
    if (body instanceof ArrayBuffer) return { bytes: body, type: null };
    if (ArrayBuffer.isView(body)) return { bytes: body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength), type: null };
    if (typeof ReadableStream === "function" && body instanceof ReadableStream) throw new TypeError("ReadableStream bodies are not supported");
    throw new TypeError("Unsupported BodyInit");
  }
  function charsetOf(headers, bytes) {
    const view = new Uint8Array(bytes);
    if (view.length >= 3 && view[0] === 0xEF && view[1] === 0xBB && view[2] === 0xBF) return "utf-8";
    if (view.length >= 2 && view[0] === 0xFF && view[1] === 0xFE) return "utf-16le";
    if (view.length >= 2 && view[0] === 0xFE && view[1] === 0xFF) return "utf-16be";
    const match = /charset\s*=\s*"?([^";]+)/i.exec(headers.get("content-type") || "");
    return match ? match[1].trim() : "utf-8";
  }

  class ReadableStream {
    constructor(owner) { this._owner = owner; this._locked = false; }
    getReader() {
      if (this._locked) throw new TypeError("ReadableStream is locked");
      this._locked = true;
      const owner = this._owner;
      if (owner._bodyUsed) throw new TypeError("Body is unusable: body stream already read");
      owner._bodyUsed = true;
      const bytes = owner._bytes ? owner._bytes.slice(0) : new ArrayBuffer(0);
      let done = false;
      return {
        read() {
          if (done) return Promise.resolve({ done: true, value: undefined });
          done = true;
          return Promise.resolve({ done: false, value: new Uint8Array(bytes) });
        },
        cancel() { return Promise.resolve(); },
        releaseLock() { this._locked = false; }
      };
    }
  }

  const bodyMethods = {
    async text() {
      const bytes = await readBytes(this);
      return bytes ? decode(bytes, charsetOf(this.headers, bytes)) : "";
    },
    async json() { return JSON.parse(await this.text()); },
    async arrayBuffer() {
      const bytes = await readBytes(this);
      return bytes ? bytes.slice(0) : new ArrayBuffer(0);
    },
    async blob() {
      const bytes = await readBytes(this);
      const type = (this.headers.get("content-type") || "").split(";")[0].trim();
      return new Blob([bytes || new ArrayBuffer(0)], { type });
    },
    async formData() {
      const bytes = await readBytes(this);
      const type = this.headers.get("content-type") || "";
      const form = new FormData();
      if (/multipart\/form-data/i.test(type)) {
        fillMultipart(form, bytes || new ArrayBuffer(0), type);
        return form;
      }
      if (/application\/x-www-form-urlencoded/i.test(type)) {
        const params = new URLSearchParams(decode(bytes || new ArrayBuffer(0), "utf-8"));
        params.forEach((value, name) => form.append(name, value));
        return form;
      }
      throw new TypeError("Could not parse form data");
    }
  };

  function followSignal(target, source) {
    if (!source) return;
    if (!(source instanceof AbortSignal)) throw new TypeError("Invalid signal");
    if (source.aborted) target._abort(source.reason);
    else source.addEventListener("abort", () => target._abort(source.reason));
  }

  class Response {
    constructor(body = null, init = {}) {
      if (init == null || typeof init !== "object") throw new TypeError("Invalid init");
      const status = init.status === undefined ? 200 : Number(init.status);
      if (!Number.isInteger(status) || status < 200 || status > 599) throw new RangeError("Invalid status code");
      const statusText = init.statusText === undefined ? "" : String(init.statusText);
      if (/[\r\n]/.test(statusText)) throw new TypeError("Invalid status text");
      const headers = new Headers(init.headers);
      let bytes = null;
      if (body != null) {
        const extracted = extractBody(body);
        if ([101, 204, 205, 304].indexOf(status) >= 0) throw new TypeError("Response with null body status cannot have body");
        if (extracted.type && !headers.has("content-type")) headers.set("content-type", extracted.type);
        bytes = extracted.bytes;
      }
      headers._guard = "response";
      this._setup({ status, statusText, headers, url: "", redirected: false, type: "default", bytes });
    }
    _setup(fields) {
      this._status = fields.status;
      this._statusText = fields.statusText;
      this._headers = fields.headers;
      this._url = fields.url || "";
      this._redirected = !!fields.redirected;
      this._type = fields.type || "default";
      this._bytes = fields.bytes || null;
      this._bodyUsed = false;
      this._stream = null;
    }
    get status() { return this._status; }
    get statusText() { return this._statusText; }
    get ok() { return this._status >= 200 && this._status <= 299; }
    get headers() { return this._headers; }
    get url() { return this._url; }
    get redirected() { return this._redirected; }
    get type() { return this._type; }
    get bodyUsed() { return this._bodyUsed; }
    get body() {
      if (this._bytes == null) return null;
      if (!this._stream) this._stream = new ReadableStream(this);
      return this._stream;
    }
    clone() {
      if (this._bodyUsed) throw new TypeError("Body is unusable: body stream already read");
      const headers = new Headers(this._headers);
      headers._guard = "response";
      const copy = Object.create(Response.prototype);
      copy._setup({
        status: this._status,
        statusText: this._statusText,
        headers,
        url: this._url,
        redirected: this._redirected,
        type: this._type,
        bytes: this._bytes ? this._bytes.slice(0) : null
      });
      return copy;
    }
    static error() {
      const headers = new Headers();
      headers._guard = "immutable";
      const response = Object.create(Response.prototype);
      response._setup({ status: 0, statusText: "", headers, url: "", redirected: false, type: "error", bytes: null });
      return response;
    }
    static redirect(url, status = 302) {
      const code = Number(status);
      if ([301, 302, 303, 307, 308].indexOf(code) < 0) throw new RangeError("Invalid redirect status");
      const parsed = parseURL(url);
      const response = new Response(null, { status: code, headers: { location: parsed } });
      response._url = parsed;
      return response;
    }
    static _fromNetwork(meta, body) {
      const headers = new Headers(meta.headers || []);
      headers._guard = "response";
      const response = Object.create(Response.prototype);
      response._setup({
        status: Number(meta.status),
        statusText: meta.statusText || "",
        headers,
        url: meta.url || "",
        redirected: meta.redirected,
        type: meta.type || "basic",
        bytes: body || null
      });
      return response;
    }
  }
  Object.assign(Response.prototype, bodyMethods);

  class Request {
    constructor(input, init) {
      if (init != null && typeof init !== "object") throw new TypeError("Invalid init");
      init = init || {};
      let method = "GET";
      let url = "";
      let headersInit;
      let body;
      let mode = "cors";
      let credentials = "same-origin";
      let cache = "default";
      let redirect = "follow";
      let referrer = "about:client";
      let referrerPolicy = "";
      let integrity = "";
      let keepalive = false;
      const signals = [];
      if (typeof input === "string") url = parseURL(input);
      else if (input instanceof Request) {
        if (input._bodyUsed) throw new TypeError("Body is unusable: body stream already read");
        method = input.method;
        url = input.url;
        headersInit = input.headers;
        body = input._bytes == null ? undefined : input._bytes;
        mode = input.mode;
        credentials = input.credentials;
        cache = input.cache;
        redirect = input.redirect;
        referrer = input.referrer;
        referrerPolicy = input.referrerPolicy;
        integrity = input.integrity;
        keepalive = input.keepalive;
        signals.push(input.signal);
        if (input._bytes != null) input._bodyUsed = true;
      } else throw new TypeError("Failed to parse URL from " + input);
      if (init.method !== undefined) method = normalizeMethod(init.method);
      else method = normalizeMethod(method);
      if (init.mode !== undefined) {
        mode = oneOf(init.mode, ["cors", "no-cors", "same-origin", "navigate"], "cors", "Invalid mode");
        if (mode === "navigate") throw new TypeError("Navigate mode is unsupported");
      }
      credentials = oneOf(init.credentials, ["omit", "same-origin", "include"], credentials, "Invalid credentials");
      cache = oneOf(init.cache, ["default", "no-store", "reload", "no-cache", "force-cache", "only-if-cached"], cache, "Invalid cache");
      redirect = oneOf(init.redirect, ["follow", "error", "manual"], redirect, "Invalid redirect");
      referrerPolicy = oneOf(init.referrerPolicy, ["", "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin", "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url"], referrerPolicy, "Invalid referrer policy");
      if (init.referrer !== undefined) referrer = init.referrer === "" ? "" : String(init.referrer);
      if (init.integrity !== undefined) integrity = String(init.integrity);
      if (init.keepalive !== undefined) {
        if (typeof init.keepalive !== "boolean") throw new TypeError("Invalid keepalive");
        keepalive = init.keepalive;
      }
      if (init.signal) signals.push(init.signal);
      const headers = new Headers(init.headers === undefined ? headersInit : init.headers);
      if (init.body !== undefined && init.body !== null) body = init.body;
      else if (init.body === null) body = undefined;
      let bytes = null;
      if (body !== undefined) {
        if (method === "GET" || method === "HEAD") throw new TypeError("Request with GET/HEAD method cannot have body.");
        const extracted = extractBody(body);
        if (extracted.type && !headers.has("content-type")) headers.set("content-type", extracted.type);
        bytes = extracted.bytes;
      }
      headers._guard = "request";
      this._method = method;
      this._url = url;
      this._headers = headers;
      this._mode = mode;
      this._credentials = credentials;
      this._cache = cache;
      this._redirect = redirect;
      this._referrer = referrer;
      this._referrerPolicy = referrerPolicy;
      this._integrity = integrity;
      this._keepalive = keepalive;
      this._bytes = bytes;
      this._bodyUsed = false;
      this._stream = null;
      this._signal = new AbortSignal();
      signals.forEach((signal) => followSignal(this._signal, signal));
    }
    get method() { return this._method; }
    get url() { return this._url; }
    get headers() { return this._headers; }
    get destination() { return ""; }
    get referrer() { return this._referrer; }
    get referrerPolicy() { return this._referrerPolicy; }
    get mode() { return this._mode; }
    get credentials() { return this._credentials; }
    get cache() { return this._cache; }
    get redirect() { return this._redirect; }
    get integrity() { return this._integrity; }
    get keepalive() { return this._keepalive; }
    get signal() { return this._signal; }
    get bodyUsed() { return this._bodyUsed; }
    get duplex() { return "half"; }
    get body() {
      if (this._bytes == null) return null;
      if (!this._stream) this._stream = new ReadableStream(this);
      return this._stream;
    }
    clone() {
      if (this._bodyUsed) throw new TypeError("Body is unusable: body stream already read");
      return new Request(this.url, {
        method: this.method,
        headers: new Headers(this.headers),
        body: this._bytes == null ? undefined : this._bytes.slice(0),
        mode: this.mode,
        credentials: this.credentials,
        cache: this.cache,
        redirect: this.redirect,
        referrer: this.referrer,
        referrerPolicy: this.referrerPolicy,
        integrity: this.integrity,
        keepalive: this.keepalive,
        signal: this.signal
      });
    }
  }
  Object.assign(Request.prototype, bodyMethods);

  function toError(error) {
    if (!error || !error.name) return new TypeError("Failed to fetch");
    if (error.name === "AbortError" || error.name === "TimeoutError") return new DOMException(error.message, error.name);
    if (error.name === "SyntaxError") return new SyntaxError(error.message);
    return new TypeError(error.message || "Failed to fetch");
  }

  function fetch(input, init) {
    let request;
    try { request = new Request(input, init); }
    catch (error) { return Promise.reject(error); }
    if (request.signal.aborted) return Promise.reject(request.signal.reason);
    return new Promise((resolve, reject) => {
      let settled = false;
      const rejectOnce = (error) => { if (!settled) { settled = true; reject(error); } };
      const resolveOnce = (value) => { if (!settled) { settled = true; resolve(value); } };
      const signal = request.signal;
      const handle = { id: 0 };
      const onAbort = () => {
        signal.removeEventListener("abort", onAbort);
        if (handle.id) nativeAbort(handle.id);
        rejectOnce(signal.reason);
      };
      signal.addEventListener("abort", onAbort);
      try {
        const headers = [];
        request.headers.forEach((value, name) => headers.push([name, value]));
        handle.id = nativeFetch({
          url: request.url,
          method: request.method,
          redirect: request.redirect,
          cache: request.cache,
          integrity: request.integrity,
          headers,
          body: request._bytes
        }, (error, meta, body) => {
          signal.removeEventListener("abort", onAbort);
          if (error) rejectOnce(toError(error));
          else {
            try { resolveOnce(Response._fromNetwork(meta, body)); }
            catch (caught) { rejectOnce(caught); }
          }
        });
      } catch (error) {
        rejectOnce(error);
      }
      if (signal.aborted) onAbort();
    });
  }

  Object.assign(globalThis, {
    fetch, Headers, Request, Response, FormData, Blob, File, URLSearchParams, AbortController, AbortSignal, DOMException, ReadableStream
  });
})();
"""#
