import XCTest
@testable import DSHCore

/// MCP client against a scripted stdio server (Python), so CI needs no
/// real MCP servers installed.
final class MCPTests: XCTestCase {
    static let fakeServer = #"""
    import sys, json
    def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    sys.stderr.write("fake server starting\n"); sys.stderr.flush()
    for line in sys.stdin:
        m = json.loads(line)
        mid, method = m.get("id"), m.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18",
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}})
        elif method == "tools/list":
            if (m.get("params") or {}).get("cursor") is None:
                send({"jsonrpc": "2.0", "id": mid, "result": {"nextCursor": "p2", "tools": [
                    {"name": "look", "description": "read only", "annotations": {"readOnlyHint": True},
                     "inputSchema": {"$schema": "x", "type": "object", "properties": {"q": {"type": "string"}}}}]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                    {"name": "poke", "description": "has effects", "inputSchema": {"type": "object"}},
                    {"name": "fail", "description": "errors"}, {"name": "hang", "description": "never answers"},
                    {"name": "die", "description": "exits"}]}})
        elif method == "tools/call":
            name, args = m["params"]["name"], m["params"].get("arguments", {})
            if name == "look":
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [
                    {"type": "text", "text": "saw " + args.get("q", "")},
                    {"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}]}})
            elif name == "poke":
                open(args["path"], "w").write("poked")
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "ok"}]}})
            elif name == "fail":
                send({"jsonrpc": "2.0", "id": mid, "result": {"isError": True, "content": [{"type": "text", "text": "boom"}]}})
            elif name == "die":
                sys.exit(3)
        elif mid is not None and method:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
    """#

    private var script: URL!
    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-mcp-\(UUID().uuidString).py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: script) }

    private func connect(_ name: String = "fake") async throws -> MCPConnection {
        let c = MCPConnection(config: MCPServerConfig(name: name, command: "/usr/bin/python3", args: ["-u", script.path]))
        await c.start()
        XCTAssertEqual(c.state, .ready, "stderr: \(c.stderrTail)")
        addTeardownBlock { c.stop() }
        return c
    }

    func testHandshakeAndPaginatedTools() async throws {
        let c = try await connect()
        XCTAssertEqual(c.serverName, "fake")
        XCTAssertEqual(c.tools.map(\.name), ["look", "poke", "fail", "hang", "die"], "both pages listed")
        XCTAssertTrue(c.tools[0].readOnly)
        XCTAssertNil(c.tools[0].inputSchema["$schema"], "$schema stripped for the API")
        XCTAssertEqual(c.tools[2].inputSchema["type"] as? String, "object", "missing schema defaulted")
        XCTAssertTrue(c.stderrTail.contains("fake server starting"))
    }

    func testCallRendersTextAndImages() async throws {
        let c = try await connect()
        let text = MCPHub.render(try await c.call(tool: "look", arguments: ["q": "it"]))
        XCTAssertTrue(text.hasPrefix("saw it\n[image saved to "), text)
        let path = String(text.split(separator: " ").last!.dropLast())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testTimeoutAndServerDeath() async throws {
        let c = try await connect()
        do { _ = try await c.call(tool: "hang", arguments: [:], timeout: 0.5); XCTFail("should time out") }
        catch { XCTAssertTrue("\(error.localizedDescription)".contains("timed out"), "\(error)") }
        do { _ = try await c.call(tool: "die", arguments: [:], timeout: 5); XCTFail("should fail") }
        catch { XCTAssertTrue(error is MCPError, "\(error)") }
        try await Task.sleep(nanoseconds: 200_000_000)
        if case .failed(let why) = c.state { XCTAssertTrue(why.contains("exited"), why) } else { XCTFail("\(c.state)") }
    }

    func testExposedNamesAreValidAndUnique() {
        let a = MCPHub.exposedName(server: "my server", tool: "do.thing")
        XCTAssertEqual(a, "mcp__my_server__do_thing")
        let long1 = MCPHub.exposedName(server: String(repeating: "s", count: 40), tool: String(repeating: "t", count: 40) + "1")
        let long2 = MCPHub.exposedName(server: String(repeating: "s", count: 40), tool: String(repeating: "t", count: 40) + "2")
        XCTAssertLessThanOrEqual(long1.count, 64); XCTAssertNotEqual(long1, long2)
    }

    func testCommandLineSplitting() {
        XCTAssertEqual(MCPHub.splitCommandLine("npx -y @scope/pkg"), ["npx", "-y", "@scope/pkg"])
        XCTAssertEqual(MCPHub.splitCommandLine(#"uvx "my server" --dir '/a b'  x"#), ["uvx", "my server", "--dir", "/a b", "x"])
        XCTAssertEqual(MCPHub.splitCommandLine(#"cmd """#), ["cmd", ""])
    }

    func testConfigRoundTripsInClaudeFormat() throws {
        let c = MCPServerConfig(name: "x", command: "npx", args: ["-y", "pkg"], env: ["K": "v"], enabled: false)
        let back = MCPServerConfig(name: "x", json: c.json)
        XCTAssertEqual(back, c)
        XCTAssertEqual(c.json["disabled"] as? Bool, true)
    }

    // MARK: through the hub and the agent loop

    private func waitReady(_ name: String) async throws {
        for _ in 0..<100 {
            if MCPHub.shared.connection(name)?.state == .ready, MCPHub.shared.owns("mcp__\(name)__look") { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("server \(name) not ready: \(String(describing: MCPHub.shared.connection(name)?.state))")
    }

    func testLargeServersAreDeferredBehindDescribeAndCall() async throws {
        let previous = MCPHub.directBudget
        MCPHub.directBudget = 10 // force the fake server over budget
        addTeardownBlock { MCPHub.directBudget = previous }
        let name = "big\(Int.random(in: 1000...9999))"
        MCPHub.shared.upsert(MCPServerConfig(name: name, command: "/usr/bin/python3", args: ["-u", script.path]))
        addTeardownBlock { MCPHub.shared.remove(name) }
        for _ in 0..<100 where !MCPHub.shared.owns("mcp__\(name)__describe") { try await Task.sleep(nanoseconds: 50_000_000) }

        let specs = MCPHub.shared.toolSpecs().filter { $0.name.hasPrefix("mcp__\(name)__") }
        XCTAssertEqual(specs.map(\.name).sorted(), ["mcp__\(name)__call", "mcp__\(name)__describe"], "only two tools sent")
        XCTAssertTrue(specs.first { $0.name.hasSuffix("describe") }!.description.contains("- poke: has effects"), "catalog lists tools")

        let schema = try await MCPHub.shared.call("mcp__\(name)__describe", arguments: ["tools": ["look"]])
        XCTAssertTrue(schema.contains("\"q\"") && !schema.contains("poke"), schema)
        let saw = try await MCPHub.shared.call("mcp__\(name)__call", arguments: ["tool": "look", "arguments": ["q": "x"]])
        XCTAssertTrue(saw.hasPrefix("saw x"), saw)

        // Approval follows the tool being called, not the generic wrapper.
        XCTAssertEqual(MCPHub.shared.category("mcp__\(name)__describe", arguments: [:]), .read)
        XCTAssertEqual(MCPHub.shared.category("mcp__\(name)__call", arguments: ["tool": "look"]), .read)
        XCTAssertEqual(MCPHub.shared.category("mcp__\(name)__call", arguments: ["tool": "poke"]), .shell)
        XCTAssertEqual(MCPHub.shared.displayName("mcp__\(name)__call", arguments: ["tool": "poke"]), "\(name) · poke")
        do { _ = try await MCPHub.shared.call("mcp__\(name)__call", arguments: ["tool": "nope"]); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("has no tool")) }
    }

    func testHubRoutesCallsAndApprovesByAnnotation() async throws {
        let name = "fake\(Int.random(in: 1000...9999))"
        MCPHub.shared.upsert(MCPServerConfig(name: name, command: "/usr/bin/python3", args: ["-u", script.path]))
        addTeardownBlock { MCPHub.shared.remove(name) }
        try await waitReady(name)

        XCTAssertTrue(MCPHub.shared.toolSpecs().contains { $0.name == "mcp__\(name)__poke" })
        XCTAssertEqual(MCPHub.shared.category("mcp__\(name)__look", arguments: [:]), .read)
        XCTAssertEqual(MCPHub.shared.category("mcp__\(name)__poke", arguments: [:]), .shell)
        do { _ = try await MCPHub.shared.call("mcp__\(name)__fail", arguments: [:]); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("boom")) }

        // Auto-approve reads: the effectful tool must ask; declined means not run.
        let previous = Settings.shared.autonomy
        Settings.shared.autonomy = .autoRead
        addTeardownBlock { Settings.shared.autonomy = previous }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("poked-\(UUID().uuidString)")
        ScriptedToolCallProtocol.reset(toolName: "mcp__\(name)__poke", arguments: ["path": marker.path])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedToolCallProtocol.self]
        let loop = AgentLoop()
        loop.client = DeepSeekClient(session: URLSession(configuration: config))
        loop.client.config = .init(baseURL: "https://scripted.invalid/v1", apiKey: "k", model: "m")
        var asked: [String] = []
        loop.approve = { title, _ in asked.append(title); return false }
        _ = try await loop.runHeadless(prompt: "go", ctx: ToolContext(workspace: NSTemporaryDirectory()), maxTurns: 3)
        XCTAssertEqual(asked, ["\(name) · poke"], "effectful MCP tool asked, with a readable name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "declined: not run")
    }
}
