import XCTest
@testable import DSHCore

/// Shell commands run under Seatbelt. These tests run real commands under
/// real profiles: approval decides whether a command runs, the sandbox
/// decides what it can touch.
final class SandboxTests: XCTestCase {
    private func workspace() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    /// A folder outside the workspace and the temp areas.
    private func outside() throws -> URL {
        let u = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/dsh-sbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    private func run(_ cmd: String, in ws: URL, _ mode: SandboxMode = .workspaceWrite) async throws -> String {
        try await Shell.run(cmd, cwd: ws.path, timeout: 20,
                            sandbox: SandboxPolicy(mode: mode, writableRoots: [ws.path]))
    }

    func testSandboxIsAvailable() {
        XCTAssertTrue(SandboxPolicy.isAvailable, "sandbox-exec works on this Mac")
    }

    func testWorkspaceWriteConfinesWrites() async throws {
        let ws = try workspace(), out = try outside()
        _ = try await run("echo hi > inside.txt && mkdir -p sub && echo x > sub/f", in: ws)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("inside.txt"), encoding: .utf8), "hi\n")

        let target = out.appendingPathComponent("escaped.txt")
        let result = try await run("echo x > '\(target.path)'", in: ws)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "write outside the workspace is blocked")
        XCTAssertTrue(result.contains("[sandbox]"), "the model is told why: \(result)")

        let child = out.appendingPathComponent("child.txt")
        _ = try await run("/bin/sh -c \"echo y > '\(child.path)'\"", in: ws)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.path), "child processes inherit the sandbox")
    }

    func testReadOnlyBlocksWorkspaceWrites() async throws {
        let ws = try workspace()
        try "keep".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let out = try await run("cat a.txt; echo changed > a.txt", in: ws, .readOnly)
        XCTAssertTrue(out.hasPrefix("keep"), "reads still work")
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("a.txt"), encoding: .utf8), "keep")
    }

    func testCredentialsAreUnreadable() async throws {
        let ws = try workspace()
        let keychains = NSHomeDirectory() + "/Library/Keychains"
        let out = try await run("ls '\(keychains)'", in: ws)
        XCTAssertTrue(out.lowercased().contains("operation not permitted"), out)
        let ok = try await run("ls '\(NSHomeDirectory())/Library' >/dev/null && echo readable", in: ws)
        XCTAssertTrue(ok.hasPrefix("readable"), "the rest of home stays readable")
    }

    func testFullAccessIsUnconfined() async throws {
        let ws = try workspace(), out = try outside()
        let target = out.appendingPathComponent("allowed.txt")
        _ = try await run("echo x > '\(target.path)'", in: ws, .fullAccess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testProfileRules() {
        var p = SandboxPolicy(mode: .workspaceWrite, writableRoots: ["/tmp/ws \"q\""], network: false)
        let sb = p.profile(home: "/Users/x")
        XCTAssertTrue(sb.contains("(subpath \"/private/tmp/ws \\\"q\\\"\")"), "canonical, escaped root: \(sb)")
        XCTAssertTrue(sb.contains("(deny network-outbound (remote ip))"))
        XCTAssertTrue(sb.contains("(subpath \"/Users/x/.ssh\")") && sb.contains("(literal \"/Users/x/.netrc\")"))
        p.protectSecrets = false; p.network = true; p.mode = .readOnly
        let ro = p.profile(home: "/Users/x")
        XCTAssertFalse(ro.contains(".ssh") || ro.contains("network") || ro.contains("/private/tmp"),
                       "read-only grants no writable roots: \(ro)")
    }

    // MARK: escalation through the agent loop

    private func loopRun(_ cmd: String, escape: Bool, approve: @escaping (String, String) async -> Bool,
                         ws: URL) async throws {
        ScriptedToolCallProtocol.reset(command: cmd, unsandboxed: escape)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedToolCallProtocol.self]
        let loop = AgentLoop()
        loop.client = DeepSeekClient(session: URLSession(configuration: config))
        loop.client.config = .init(baseURL: "https://scripted.invalid/v1", apiKey: "k", model: "m")
        loop.allowedTools = ["bash"]
        loop.approve = approve
        _ = try await loop.runHeadless(prompt: "go", ctx: ToolContext(workspace: ws.path), maxTurns: 3)
    }

    func testEscalationAlwaysAsksEvenAtFullAutonomy() async throws {
        let previous = Settings.shared.autonomy
        Settings.shared.autonomy = .full
        addTeardownBlock { Settings.shared.autonomy = previous }
        let ws = try workspace(), out = try outside()

        // At Full autonomy: still sandboxed, never asked.
        var asked: [String] = []
        let plain = out.appendingPathComponent("plain")
        try await loopRun("touch '\(plain.path)'", escape: false, approve: { _, s in asked.append(s); return true }, ws: ws)
        XCTAssertTrue(asked.isEmpty, "Full autonomy doesn't ask for normal commands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path), "but they stay sandboxed")

        // Escalation declined: asked, and not run outside.
        let declined = out.appendingPathComponent("declined")
        try await loopRun("touch '\(declined.path)'", escape: true, approve: { _, s in asked.append(s); return false }, ws: ws)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].hasPrefix("Outside the sandbox: "), asked[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: declined.path))

        // Escalation approved: this one command runs unconfined.
        let approved = out.appendingPathComponent("approved")
        try await loopRun("touch '\(approved.path)'", escape: true, approve: { _, _ in true }, ws: ws)
        XCTAssertTrue(FileManager.default.fileExists(atPath: approved.path))
    }
}
