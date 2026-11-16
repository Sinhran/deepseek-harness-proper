import Foundation

// MARK: - Config

/// One MCP server, in the `mcpServers` shape Claude Desktop and Claude Code
/// use, so a config can be pasted between them.
struct MCPServerConfig: Equatable {
    var name: String
    var command: String
    var args: [String] = []
    var env: [String: String] = [:]
    var enabled = true

    var json: [String: Any] {
        var o: [String: Any] = ["command": command, "args": args]
        if !env.isEmpty { o["env"] = env }
        if !enabled { o["disabled"] = true }
        return o
    }
    init(name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) {
        self.name = name; self.command = command; self.args = args; self.env = env; self.enabled = enabled
    }
    init?(name: String, json o: [String: Any]) {
        guard let command = o["command"] as? String, !command.isEmpty else { return nil }
        self.init(name: name, command: command,
                  args: o["args"] as? [String] ?? [],
                  env: o["env"] as? [String: String] ?? [:],
                  enabled: !(o["disabled"] as? Bool ?? false))
    }
}

struct MCPTool {
    var name: String
    var description: String
    var inputSchema: [String: Any]
    /// The server marked it read-only (`annotations.readOnlyHint`).
    var readOnly: Bool
}

enum MCPError: LocalizedError {
    case notRunning(String), timeout(String), server(String), protocolError(String)
    var errorDescription: String? {
        switch self {
        case .notRunning(let s): return "MCP server \(s) isn't running"
        case .timeout(let s): return "MCP request timed out: \(s)"
        case .server(let s): return s
        case .protocolError(let s): return "MCP protocol error: \(s)"
        }
    }
}

// MARK: - Connection

/// One stdio MCP server process: newline-delimited JSON-RPC 2.0.
final class MCPConnection: @unchecked Sendable { // all mutable state behind `lock`
    enum State: Equatable { case stopped, starting, ready, failed(String) }

    let config: MCPServerConfig
    private(set) var state: State = .stopped
    private(set) var tools: [MCPTool] = []
    private(set) var serverName = ""
    /// Last stderr lines, shown when the server fails.
    private(set) var stderrTail: [String] = []
    var onChange: () -> Void = {}

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var nextID = 1
    private let lock = NSLock()

    init(config: MCPServerConfig) { self.config = config }

    func start() async {
        let idle = locked { () -> Bool in
            switch state { case .stopped, .failed: return true; case .starting, .ready: return false }
        }
        guard idle else { return }
        setState(.starting)
        do {
            try launch()
            let info = try await request("initialize", [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "dsh-proper", "version": "0.2"],
            ], timeout: 30)
            serverName = (info["serverInfo"] as? [String: Any])?["name"] as? String ?? config.name
            notify("notifications/initialized")
            try await refreshTools()
            setState(.ready)
        } catch {
            let tail = locked { stderrTail.suffix(3).joined(separator: " ") }
            stop(state: .failed(error.localizedDescription + (tail.isEmpty ? "" : " — \(tail)")))
        }
    }

    func stop(state final: State = .stopped) {
        let (proc, waiting) = locked { () -> (Process?, [(Result<[String: Any], Error>) -> Void]) in
            let p = process, w = Array(pending.values)
            process = nil; input = nil; pending.removeAll(); tools = []
            return (p, w)
        }
        proc?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        proc?.standardError.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        if let proc, proc.isRunning { Shell.killTree(proc, after: 1) }
        waiting.forEach { $0(.failure(MCPError.notRunning(config.name))) }
        setState(final)
    }

    func call(tool: String, arguments: [String: Any], timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard locked({ state == .ready }) else { throw MCPError.notRunning(config.name) }
        return try await request("tools/call", ["name": tool, "arguments": arguments], timeout: timeout)
    }

    private func refreshTools() async throws {
        var all: [MCPTool] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let page = try await request("tools/list", params, timeout: 30)
            for t in page["tools"] as? [[String: Any]] ?? [] {
                guard let name = t["name"] as? String else { continue }
                var schema = t["inputSchema"] as? [String: Any] ?? [:]
                schema["$schema"] = nil
                if schema["type"] == nil { schema["type"] = "object" }
                if schema["properties"] == nil { schema["properties"] = [String: Any]() }
                let readOnly = ((t["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) ?? false
                all.append(MCPTool(name: name, description: t["description"] as? String ?? "",
                                   inputSchema: schema, readOnly: readOnly))
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil && all.count < 1000
        locked { tools = all }
        onChange()
    }

    // MARK: process

    private func launch() throws {
        guard let exe = MCPHub.resolveExecutable(config.command) else {
            throw MCPError.server("command not found: \(config.command)")
        }
        let p = Process(), inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.executableURL = exe
        p.arguments = config.args
        var env = Shell.sanitizedEnvironment()
        env["PATH"] = MCPHub.searchPath.joined(separator: ":")
        config.env.forEach { env[$0.key] = $0.value }
        p.environment = env
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { self?.receive(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { h.readabilityHandler = nil; return }
            let lines = String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            self.locked { self.stderrTail = Array((self.stderrTail + lines).suffix(20)) }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self, self.locked({ self.process === proc }) else { return }
            self.stop(state: .failed("server exited (\(proc.terminationStatus))"))
        }
        try p.run()
        locked { process = p; input = inPipe.fileHandleForWriting }
    }

    private func receive(_ data: Data) {
        var messages: [[String: Any]] = []
        locked {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(o) }
            }
        }
        messages.forEach(handle)
    }

    private func handle(_ m: [String: Any]) {
        if let method = m["method"] as? String {
            if let id = m["id"] {
                // Server-to-client request. We declare no client capabilities;
                // answer ping, refuse the rest per spec.
                if method == "ping" { send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()]) }
                else { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
            } else if method == "notifications/tools/list_changed" {
                Task { try? await self.refreshTools() }
            }
            return
        }
        guard let id = (m["id"] as? NSNumber)?.intValue else { return }
        let done = locked { pending.removeValue(forKey: id) }
        if let err = m["error"] as? [String: Any] {
            done?(.failure(MCPError.server(err["message"] as? String ?? "error \(err["code"] ?? "")")))
        } else {
            done?(.success(m["result"] as? [String: Any] ?? [:]))
        }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            let id: Int = locked {
                let id = nextID; nextID += 1
                var resumed = false
                pending[id] = { result in
                    // Exactly once: a reply, a timeout, or the server dying.
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(with: result)
                }
                return id
            }
            guard send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
                let done = locked { pending.removeValue(forKey: id) }
                done?(.failure(MCPError.notRunning(config.name)))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let done = self.locked { self.pending.removeValue(forKey: id) }
                if done != nil {
                    self.notify("notifications/cancelled", ["requestId": id, "reason": "timeout"])
                    done?(.failure(MCPError.timeout("\(self.config.name) \(method)")))
                }
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]? = nil) {
        var m: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { m["params"] = params }
        send(m)
    }

    @discardableResult
    private func send(_ message: [String: Any]) -> Bool {
        guard let h = locked({ input }),
              var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do { try h.write(contentsOf: data); return true } catch { return false }
    }

    private func setState(_ s: State) { locked { state = s }; onChange() }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

// MARK: - Hub

extension Notification.Name { static let mcpChanged = Notification.Name("dsh.mcpChanged") }

/// All configured MCP servers and their tools, exposed to the agent as
/// `mcp__<server>__<tool>`. Servers are programs the user chose to trust;
/// they run outside the shell sandbox (computer use needs Accessibility and
/// Screen Recording), and their tools go through the normal approvals.
final class MCPHub: @unchecked Sendable { // all mutable state behind `lock`
    static let shared = MCPHub()
    private let lock = NSLock()
    private var connections: [String: MCPConnection] = [:]
    private(set) var configs: [MCPServerConfig] = []

    static var configFile: URL { Settings.supportDir.appendingPathComponent("mcp.json") }

    init() { configs = Self.loadConfigs() }

    // MARK: config

    static func loadConfigs() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: configFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, v in (v as? [String: Any]).flatMap { MCPServerConfig(name: name, json: $0) } }
            .sorted { $0.name < $1.name }
    }

    private func saveConfigs() {
        let servers = Dictionary(uniqueKeysWithValues: configs.map { ($0.name, $0.json) })
        if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configFile, options: .atomic)
        }
    }

    func upsert(_ config: MCPServerConfig) {
        lock.lock()
        configs.removeAll { $0.name == config.name }
        configs.append(config); configs.sort { $0.name < $1.name }
        let old = connections.removeValue(forKey: config.name)
        lock.unlock()
        old?.stop()
        saveConfigs()
        if config.enabled { startServer(config) } else { changed() }
    }

    func remove(_ name: String) {
        lock.lock()
        configs.removeAll { $0.name == name }
        let old = connections.removeValue(forKey: name)
        lock.unlock()
        old?.stop(); saveConfigs(); changed()
    }

    // MARK: lifecycle

    func startEnabled() { configs.filter(\.enabled).forEach(startServer) }

    func stopAll() {
        lock.lock(); let all = Array(connections.values); connections.removeAll(); lock.unlock()
        all.forEach { $0.stop() }
    }

    func restart(_ name: String) {
        guard let c = configs.first(where: { $0.name == name }) else { return }
        upsert(c)
    }

    private func startServer(_ config: MCPServerConfig) {
        let conn = MCPConnection(config: config)
        conn.onChange = { [weak self] in self?.changed() }
        lock.lock(); connections[config.name] = conn; lock.unlock()
        Task { await conn.start() }
    }

    func connection(_ name: String) -> MCPConnection? {
        lock.lock(); defer { lock.unlock() }; return connections[name]
    }

    private func changed() {
        rebuildRoutes()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .mcpChanged, object: nil) }
    }

    // MARK: tools

    private enum Route { case tool(server: String, tool: String), describe(server: String), call(server: String) }
    /// Tool name the model sees → what it reaches.
    private var routes: [String: Route] = [:]

    /// Servers whose schemas exceed this (in characters) are deferred: the
    /// model gets `describe` + `call` instead of every schema on every
    /// request. cua-driver's 56 tools are ~94k characters (~23k tokens).
    static var directBudget = 20_000

    static func schemaSize(_ tools: [MCPTool]) -> Int {
        tools.reduce(0) { $0 + JSON.compact($1.inputSchema).count + $1.description.count + $1.name.count }
    }

    private func readyConnections() -> [(String, MCPConnection)] {
        lock.lock(); let conns = connections; lock.unlock()
        return conns.filter { $0.value.state == .ready }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func rebuildRoutes() {
        var r: [String: Route] = [:]
        for (server, c) in readyConnections() {
            if Self.schemaSize(c.tools) > Self.directBudget {
                r[Self.exposedName(server: server, tool: "describe")] = .describe(server: server)
                r[Self.exposedName(server: server, tool: "call")] = .call(server: server)
            } else {
                for t in c.tools { r[Self.exposedName(server: server, tool: t.name)] = .tool(server: server, tool: t.name) }
            }
        }
        lock.lock(); routes = r; lock.unlock()
    }

    func toolSpecs() -> [ToolSpec] {
        readyConnections().flatMap { server, c -> [ToolSpec] in
            guard Self.schemaSize(c.tools) > Self.directBudget else {
                return c.tools.map { t in
                    ToolSpec(name: Self.exposedName(server: server, tool: t.name),
                             description: "[\(server)] " + t.description, parameters: t.inputSchema)
                }
            }
            let catalog = c.tools.map { "- \($0.name): \(Self.summary($0.description))" }.joined(separator: "\n")
            return [
                ToolSpec(name: Self.exposedName(server: server, tool: "describe"),
                         description: "[\(server)] Get the full input schemas of \(server) tools before calling them. Available tools:\n\(catalog)",
                         parameters: ["type": "object", "properties": [
                             "tools": ["type": "array", "items": ["type": "string"], "description": "Tool names (up to 10)"]],
                                      "required": ["tools"]]),
                ToolSpec(name: Self.exposedName(server: server, tool: "call"),
                         description: "[\(server)] Call one \(server) tool. Use describe first to learn its arguments.",
                         parameters: ["type": "object", "properties": [
                             "tool": ["type": "string"], "arguments": ["type": "object"]], "required": ["tool"]]),
            ]
        }
    }

    /// First sentence, at most ~90 characters.
    static func summary(_ description: String) -> String {
        let line = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let sentence = line.split(separator: ".", maxSplits: 1).first.map(String.init) ?? line
        return sentence.count > 90 ? String(sentence.prefix(87)) + "…" : sentence
    }

    func owns(_ exposed: String) -> Bool { route(exposed) != nil }

    /// The server tool a call reaches (for `call`, the one named in its arguments).
    private func target(_ exposed: String, _ arguments: [String: Any]) -> (server: String, tool: String)? {
        switch route(exposed) {
        case .tool(let s, let t): return (s, t)
        case .call(let s): return (arguments["tool"] as? String).map { (s, $0) }
        case .describe, .none: return nil
        }
    }

    /// Read-only tools (and `describe`) approve like reads; anything else
    /// (clicks, typing, writes) approves like shell.
    func category(_ exposed: String, arguments: [String: Any]) -> ToolCategory {
        if case .describe = route(exposed) { return .read }
        guard let (server, tool) = target(exposed, arguments),
              let t = connection(server)?.tools.first(where: { $0.name == tool }) else { return .shell }
        return t.readOnly ? .read : .shell
    }

    func displayName(_ exposed: String, arguments: [String: Any]) -> String? {
        if case .describe(let s) = route(exposed) { return "\(s) · describe" }
        return target(exposed, arguments).map { "\($0.server) · \($0.tool)" }
    }

    func call(_ exposed: String, arguments: [String: Any]) async throws -> String {
        if case .describe(let server) = route(exposed) {
            let names = (arguments["tools"] as? [String] ?? []).prefix(10)
            let tools = connection(server)?.tools.filter { names.contains($0.name) } ?? []
            guard !tools.isEmpty else { throw ToolError.failed("no such \(server) tools: \(names.joined(separator: ", "))") }
            return JSON.compact(tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] })
        }
        guard let (server, tool) = target(exposed, arguments), let c = connection(server) else {
            throw ToolError.failed("MCP tool unavailable: \(exposed)")
        }
        guard c.tools.contains(where: { $0.name == tool }) else { throw ToolError.failed("\(server) has no tool \(tool)") }
        let args: [String: Any]
        if case .call = route(exposed) { args = arguments["arguments"] as? [String: Any] ?? [:] } else { args = arguments }
        let result = try await c.call(tool: tool, arguments: args)
        let text = Self.render(result)
        if result["isError"] as? Bool == true { throw ToolError.failed(text) }
        return text
    }

    private func route(_ exposed: String) -> Route? {
        lock.lock(); defer { lock.unlock() }; return routes[exposed]
    }

    /// Function names must match ^[a-zA-Z0-9_-]{1,64}$.
    static func exposedName(server: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        }
        let name = "mcp__\(clean(server))__\(clean(tool))"
        guard name.count > 64 else { return name }
        // Keep it unique when shortened: a stable hash of the full name.
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(name.prefix(55)) + "_" + String(format: "%08x", h)
    }

    /// Tool result → text for the model. Images are saved to temp files and
    /// referenced by path; long output is capped.
    static func render(_ result: [String: Any]) -> String {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "image":
                if let b64 = item["data"] as? String, let data = Data(base64Encoded: b64) {
                    let ext = (item["mimeType"] as? String)?.split(separator: "/").last.map(String.init) ?? "png"
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-mcp")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
                    if (try? data.write(to: url)) != nil { parts.append("[image saved to \(url.path)]") }
                }
            case "resource":
                let r = item["resource"] as? [String: Any] ?? [:]
                parts.append((r["text"] as? String) ?? "[resource \(r["uri"] as? String ?? "")]")
            case "resource_link": parts.append("[resource \(item["uri"] as? String ?? "")]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(JSON.compact(structured)) }
        var text = parts.joined(separator: "\n")
        if text.count > 60_000 { text = String(text.prefix(60_000)) + "\n(truncated)" }
        return text.isEmpty ? "(no output)" : text
    }

    // MARK: executables

    /// GUI apps launch with a minimal PATH. Search the login shell's PATH
    /// plus the usual install locations so `npx`, `uvx`, `cua-driver` work.
    static let searchPath: [String] = {
        var dirs: [String] = []
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            dirs += String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin",
                 "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    static func resolveExecutable(_ command: String) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for dir in searchPath {
            let path = (dir as NSString).appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Splits a command line on spaces, honoring "double" and 'single' quotes.
    static func splitCommandLine(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character? = nil, inWord = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; inWord = true
            } else if ch == " " || ch == "\t" {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// cua-driver's MCP server, if it's installed.
    static var computerUsePreset: MCPServerConfig? {
        resolveExecutable("cua-driver").map { MCPServerConfig(name: "computer", command: $0.path, args: ["mcp"]) }
    }
}
