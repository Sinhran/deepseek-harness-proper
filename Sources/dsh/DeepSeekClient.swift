import Foundation
import Darwin

struct SSELineReader {
    private var buffer: [UInt8] = []

    mutating func append(_ byte: UInt8) -> String? {
        guard byte == 0x0A else { buffer.append(byte); return nil }
        if buffer.last == 0x0D { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }

    /// Feed a whole network chunk at once; returns every line completed by it.
    /// Scanning bytes in bulk avoids per-byte async suspension on the stream.
    mutating func append(_ chunk: Data) -> [String] {
        var lines: [String] = []
        var start = chunk.startIndex
        while let nl = chunk[start...].firstIndex(of: 0x0A) {
            buffer.append(contentsOf: chunk[start..<nl])
            if buffer.last == 0x0D { buffer.removeLast() }
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll(keepingCapacity: true)
            start = chunk.index(after: nl)
        }
        buffer.append(contentsOf: chunk[start...])
        return lines
    }

    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

enum StreamEvent {
    case text(String)
    case reasoning(String)
    case toolCall(index: Int, id: String?, name: String?, argsDelta: String?)
    case usage(prompt: Int, completion: Int)
    case done
}

enum ClientError: LocalizedError, Equatable {
    case noAPIKey
    case http(Int, String)
    case invalidURL
    case emptyModels
    case insecureEndpoint
    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No DeepSeek API key. Set one in Settings."
        case .http(let c, let body): return "HTTP \(c): \(body.prefix(500))"
        case .invalidURL: return "Enter a valid HTTP or HTTPS API base URL in Settings."
        case .emptyModels: return "The API returned no models. Check your key and endpoint, then refresh."
        case .insecureEndpoint: return "Refusing to send the API key over plaintext HTTP to a non-localhost endpoint. Use HTTPS, or a localhost endpoint for a local proxy."
        }
    }
}

final class DeepSeekClient {
    struct Config {
        var baseURL = "https://api.deepseek.com"
        var apiKey = ""
        var model = ""
        var temperature: Double? = nil
        var maxTokens: Int? = nil
    }

    var config = Config()
    private let session: URLSession
    /// Non-streaming session with a redirect guard, built from the base
    /// session's configuration so Preview's URLProtocol injection applies.
    private lazy var guardedSession: URLSession =
        URLSession(configuration: session.configuration,
                   delegate: RedirectGuard(), delegateQueue: nil)
    /// Lazily built streaming session shared by every SSE request this
    /// client makes: connections pool instead of paying TLS setup and
    /// queue allocation per turn. Guarded by streamLock for concurrent
    /// streams (a parent loop and its subagents share one client).
    private var streamSession: URLSession?
    private var streamDelegate: ChunkDelegate?
    private let streamLock = NSLock()
    init(session: URLSession? = nil) { self.session = session ?? (Preview.enabled ? Preview.session : .shared) }
    deinit { streamSession?.invalidateAndCancel(); guardedSession.invalidateAndCancel() }

    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        // Literal addresses only: a DNS name that merely starts with "127."
        // (e.g. 127.0.0.1.attacker.com) is not loopback and must never be
        // treated as a safe plaintext-HTTP destination for the API key.
        var v4 = in_addr()
        if h.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) } // network order: b[0] is the first octet
            return b[0] == 127
        }
        var v6 = in6_addr()
        if h.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }          // ::1
            return b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff
                && b[12] == 127                                                       // ::ffff:127.x.x.x
        }
        return false
    }

    func endpoint(_ path: String) throws -> URL {
        guard let base = URL(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""), let host = base.host else {
            throw ClientError.invalidURL
        }
        // The API key travels as a Bearer header: never send it in cleartext
        // beyond loopback (a local proxy is the legitimate HTTP use case).
        if base.scheme?.lowercased() == "http", !Self.isLoopbackHost(host) {
            throw ClientError.insecureEndpoint
        }
        return base.appendingPathComponent(path)
    }

    /// Fetches the model list from GET {base}/models (OpenAI-compatible).
    func models() async throws -> [String] {
        let cfg = config
        guard !cfg.apiKey.isEmpty else { throw ClientError.noAPIKey }
        let url = try endpoint("models")
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await guardedSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                   String(data: data, encoding: .utf8) ?? "")
        }
        struct ModelsResp: Decodable { struct M: Decodable { var id: String }; var data: [M] }
        let ids = (try JSONDecoder().decode(ModelsResp.self, from: data)).data.map { $0.id }.sorted()
        guard !ids.isEmpty else { throw ClientError.emptyModels }
        return Array(Set(ids)).sorted()
    }

    /// Streams a chat completion. Yields deltas; caller assembles.
    func stream(messages: [WireMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<StreamEvent, Error> {
        let cfg = config
        let url: URL
        do { url = try endpoint("chat/completions") }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !cfg.apiKey.isEmpty else { throw ClientError.noAPIKey }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 600

                    var body: [String: Any] = [
                        "model": cfg.model,
                        "messages": try Self.encodeMessages(messages),
                        "stream": true,
                    ]
                    if let tools, !tools.isEmpty { body["tools"] = tools.map { $0.wire } }
                    if let t = cfg.temperature { body["temperature"] = t }
                    if let m = cfg.maxTokens { body["max_tokens"] = m }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let chunks = self.chunkedData(for: req)
                    var http: HTTPURLResponse?
                    var errText = ""
                    var reader = SSELineReader()
                    var sawDone = false
                    for try await event in chunks {
                        if Task.isCancelled { break }
                        switch event {
                        case .response(let response): http = response
                        case .data(let data):
                            guard let response = http else { continue }
                            if !(200..<300).contains(response.statusCode) {
                                errText += String(decoding: data, as: UTF8.self)
                                if errText.count > 4000 { errText = String(errText.prefix(4000)) }
                                continue
                            }
                            for line in reader.append(data) {
                                if try Self.handleSSELine(line, statusCode: response.statusCode, continuation: continuation) { sawDone = true; break }
                            }
                            if sawDone { break }
                        }
                    }
                    guard let response = http else { throw ClientError.http(-1, "no response") }
                    guard (200..<300).contains(response.statusCode) else {
                        throw ClientError.http(response.statusCode, errText)
                    }
                    if !Task.isCancelled, !sawDone, let line = reader.finish() {
                        _ = try Self.handleSSELine(line, statusCode: response.statusCode, continuation: continuation)
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Redirect policy for requests carrying the API key: the target must
    /// satisfy the same rules as the base endpoint (http(s) only, never
    /// plaintext beyond loopback) and the Bearer header is stripped when
    /// the redirect crosses hosts. Returns nil to refuse the redirect.
    ///
    /// URLSession drops Authorization from the redirect request before the
    /// delegate sees it (verified: the header is absent even for a same-host
    /// 302), so a same-host redirect has to be re-authorized explicitly or
    /// every canonicalizing endpoint answers 401.
    static func validatedRedirect(task: URLSessionTask, newRequest: URLRequest) -> URLRequest? {
        guard let url = newRequest.url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host else { return nil }
        if scheme == "http", !isLoopbackHost(host) { return nil }
        var req = newRequest
        let sameHost = host.lowercased() == task.originalRequest?.url?.host?.lowercased()
        if sameHost {
            if req.value(forHTTPHeaderField: "Authorization") == nil,
               let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
                req.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        } else {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Redirect-only delegate for the non-streaming session.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(DeepSeekClient.validatedRedirect(task: task, newRequest: request))
        }
    }

    // MARK: Chunked transport (delegate-based, so SSE consumes network
    // buffers whole instead of suspending once per byte)

    enum ChunkEvent {
        case response(HTTPURLResponse)
        case data(Data)
    }

    /// One streaming URLSession per client, built from the base session's
    /// configuration so Preview's URLProtocol injection still applies.
    private func streamingSession() -> (URLSession, ChunkDelegate) {
        streamLock.lock(); defer { streamLock.unlock() }
        if let streamSession, let streamDelegate { return (streamSession, streamDelegate) }
        let delegate = ChunkDelegate()
        let created = URLSession(configuration: session.configuration,
                                 delegate: delegate, delegateQueue: nil)
        streamSession = created; streamDelegate = delegate
        return (created, delegate)
    }

    /// Demultiplexes data-delegate callbacks for every task on the shared
    /// streaming session, keyed by task identifier so concurrent streams
    /// (turn loop plus subagents) never cross wires.
    private final class ChunkDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        struct Handlers {
            var onResponse: (HTTPURLResponse) -> Void
            var onData: (Data) -> Void
            var onFinish: (Error?) -> Void
        }
        private let lock = NSLock()
        private var handlers: [Int: Handlers] = [:]

        func register(_ task: URLSessionTask,
                      onResponse: @escaping (HTTPURLResponse) -> Void,
                      onData: @escaping (Data) -> Void,
                      onFinish: @escaping (Error?) -> Void) {
            lock.lock()
            handlers[task.taskIdentifier] = Handlers(onResponse: onResponse,
                                                     onData: onData, onFinish: onFinish)
            lock.unlock()
        }
        @discardableResult
        func unregister(_ id: Int) -> Handlers? {
            lock.lock(); defer { lock.unlock() }
            return handlers.removeValue(forKey: id)
        }
        private func handlers(for id: Int) -> Handlers? {
            lock.lock(); defer { lock.unlock() }
            return handlers[id]
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse { handlers(for: dataTask.taskIdentifier)?.onResponse(http) }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            handlers(for: dataTask.taskIdentifier)?.onData(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            unregister(task.taskIdentifier)?.onFinish(error)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(DeepSeekClient.validatedRedirect(task: task, newRequest: request))
        }
    }

    private func chunkedData(for request: URLRequest) -> AsyncThrowingStream<ChunkEvent, Error> {
        let (urlSession, delegate) = streamingSession()
        return AsyncThrowingStream { continuation in
            let task = urlSession.dataTask(with: request)
            delegate.register(task,
                              onResponse: { continuation.yield(.response($0)) },
                              onData: { continuation.yield(.data($0)) },
                              onFinish: { error in
                                  if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                              })
            continuation.onTermination = { _ in
                // Drop the handlers first: the cancelled task's
                // didCompleteWithError must not finish the stream twice.
                delegate.unregister(task.taskIdentifier)
                task.cancel()
            }
            task.resume()
        }
    }

    private static func handleSSELine(_ line: String, statusCode: Int,
                                      continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return true }
        guard let data = payload.data(using: .utf8),
              let chunk = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let error = chunk["error"] {
            throw ClientError.http(statusCode, JSON.compact(error))
        }
        handle(chunk: chunk, continuation: continuation)
        return false
    }

    private static func handle(chunk: [String: Any], continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) {
        if let usage = chunk["usage"] as? [String: Any],
           let p = usage["prompt_tokens"] as? Int, let c = usage["completion_tokens"] as? Int {
            continuation.yield(.usage(prompt: p, completion: c))
        }
        guard let choices = chunk["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return }

        if let r = delta["reasoning_content"] as? String, !r.isEmpty {
            continuation.yield(.reasoning(r))
        }
        if let c = delta["content"] as? String, !c.isEmpty {
            continuation.yield(.text(c))
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let idx = call["index"] as? Int ?? 0
                let f = call["function"] as? [String: Any]
                // Some providers (e.g. via compatibility proxies) send
                // `"name": ""` on continuation chunks instead of omitting the
                // key. An empty delta must not wipe the accumulated value.
                func nonEmpty(_ v: Any?) -> String? {
                    guard let s = v as? String, !s.isEmpty else { return nil }
                    return s
                }
                continuation.yield(.toolCall(
                    index: idx,
                    id: nonEmpty(call["id"]),
                    name: nonEmpty(f?["name"]),
                    argsDelta: nonEmpty(f?["arguments"])))
            }
        }
    }

    static func encodeMessages(_ msgs: [WireMessage]) throws -> [[String: Any]] {
        msgs.map { m in
            var o: [String: Any] = ["role": m.role.rawValue]
            if let c = m.content {
                o["content"] = (c.isEmpty && m.role == .tool) ? "(no output)" : c
            } else if m.role == .tool {
                o["content"] = "(no output)"
            }
            if m.role == .assistant && m.content == nil { o["content"] = "" }
            // reasoning_content is display-only: DeepSeek rejects requests
            // that echo it back, so it never goes on the wire.
            if let tc = m.tool_calls, !tc.isEmpty {
                o["tool_calls"] = tc.map {
                    ["id": $0.id, "type": $0.type,
                     "function": ["name": $0.function.name, "arguments": $0.function.arguments]]
                }
            }
            if let id = m.tool_call_id { o["tool_call_id"] = id }
            if let n = m.name { o["name"] = n }
            return o
        }
    }
}
