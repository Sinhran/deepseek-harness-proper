import XCTest
@testable import DSHCore

/// Focused unit tests for the audit fixes (granular cases alongside Smoke).
final class UnitTests: XCTestCase {

    // Plaintext HTTP must never carry the API key beyond loopback.
    func testInsecureEndpointRejected() {
        let client = DeepSeekClient()
        client.config.baseURL = "http://api.example.com"
        XCTAssertThrowsError(try client.endpoint("models")) { error in
            XCTAssertEqual(error as? ClientError, .insecureEndpoint)
        }
    }

    func testLoopbackHTTPEndpointAllowed() throws {
        let client = DeepSeekClient()
        client.config.baseURL = "http://127.0.0.1:8080/v1"
        XCTAssertEqual(try client.endpoint("models").host, "127.0.0.1")
        client.config.baseURL = "http://localhost:11434"
        XCTAssertEqual(try client.endpoint("models").host, "localhost")
    }

    func testHTTPSEndpointAllowed() throws {
        let client = DeepSeekClient()
        client.config.baseURL = "https://api.deepseek.com"
        XCTAssertEqual(try client.endpoint("models").host, "api.deepseek.com")
    }

    // Chunked SSE feeding: lines split across chunks, CRLF, U+2028 preserved.
    func testSSEChunkedAppend() {
        var reader = SSELineReader()
        var lines = reader.append(Data("data: {\"text\":\"a\u{2028}b\"}\r".utf8))
        XCTAssertTrue(lines.isEmpty)
        lines += reader.append(Data("\ndata: [DONE]\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, "data: [DONE]")
        XCTAssertNil(reader.finish())
    }

    // Approval matrix for tool categories.
    func testToolCategoryApprovals() {
        XCTAssertFalse(Tools.category(.shell, needsApproval: .full))
        XCTAssertTrue(Tools.category(.read, needsApproval: .ask))
        XCTAssertFalse(Tools.category(.read, needsApproval: .autoRead))
        XCTAssertTrue(Tools.category(.write, needsApproval: .autoRead))
        XCTAssertFalse(Tools.category(.write, needsApproval: .autoWrite))
        XCTAssertTrue(Tools.category(.shell, needsApproval: .autoWrite))
        XCTAssertTrue(Tools.category(.meta, needsApproval: .autoWrite))
    }

    // ApprovalView must initialize without throwing: it activates
    // constraints between its header strip and itself during init.
    func testApprovalViewInitializes() {
        let view = ApprovalView(tool: "bash", summary: "ls") { _ in }
        XCTAssertFalse(view.subviews.isEmpty)
    }

    // Plugin shell gating reuses the same rule: shell needs approval unless
    // autonomy is .full, which is what JSRuntime's __exec bridge checks.
    func testPluginShellGateFollowsAutonomy() {
        XCTAssertTrue(Tools.category(.shell, needsApproval: .autoRead))
        XCTAssertFalse(Tools.category(.shell, needsApproval: .full))
    }

    // Scheduler add/remove roundtrip on the shared instance, isolated to a
    // temp support dir: the XCTest environment probe is not set by every
    // runner, and without the override these writes land in the real
    // automations.json. flush() drains the async persist queue so a fast
    // exit cannot leave the removal unpersisted.
    func testSchedulerAddRemove() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            Settings.supportDirOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        Settings.supportDirOverride = dir
        let task = try Scheduler.shared.add(title: "unit", prompt: "hi", workspace: "/tmp",
                                            schedule: .interval(seconds: 3600))
        XCTAssertTrue(Scheduler.shared.tasks.contains { $0.id == task.id })
        Scheduler.shared.flush()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        func persisted() -> [AutomationTask]? {
            (try? Data(contentsOf: dir.appendingPathComponent("automations.json"))).flatMap {
                try? dec.decode([AutomationTask].self, from: $0)
            }
        }
        XCTAssertTrue(persisted()?.contains { $0.id == task.id } == true)
        XCTAssertTrue(Scheduler.shared.remove(id: task.id))
        Scheduler.shared.flush()
        XCTAssertFalse(Scheduler.shared.tasks.contains { $0.id == task.id })
        XCTAssertFalse(Scheduler.shared.remove(id: task.id))
        XCTAssertFalse(persisted()?.contains { $0.id == task.id } == true)
    }

    // Every automation row exposes a delete control that reports its own
    // task: tapping it must delete exactly that task, not a neighbor.
    func testAutomationRowsExposeDelete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-sched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            Settings.supportDirOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        Settings.supportDirOverride = dir
        let task = try Scheduler.shared.add(title: "row-unit", prompt: "hi", workspace: "/tmp",
                                            schedule: .interval(seconds: 3600))
        defer { _ = Scheduler.shared.remove(id: task.id); Scheduler.shared.flush() }
        var deleted: [UUID] = []
        let rows = PluginAutomationRows.automations(intro: "x", onToggle: { _ in }, onDelete: { deleted.append($0.id) })
        let host = vertical(rows)
        let buttons = collectButtons(in: host)
        guard let del = buttons.first(where: { $0.accessibilityLabel() == "Delete automation row-unit" }) else {
            return XCTFail("automation row must expose a delete control")
        }
        del.performClick(nil)
        XCTAssertEqual(deleted, [task.id])
    }

    // A corrupt session file is quarantined, not silently loaded.
    func testCorruptSessionQuarantined() throws {
        let id = UUID()
        let file = Settings.sessionsDir.appendingPathComponent("\(id.uuidString).json")
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(SessionStore.shared.load(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // An empty old_string matches between every character; replace_all
    // would inject the replacement through the whole file.
    func testEditRejectsEmptyOldString() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello world".write(to: dir.appendingPathComponent("f.txt"),
                                atomically: true, encoding: .utf8)
        let ctx = ToolContext(workspace: dir.path)
        do {
            _ = try await Tools.edit.run(["file_path": "f.txt", "old_string": "",
                                          "new_string": "x", "replace_all": true], ctx)
            XCTFail("empty old_string must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("old_string"),
                          "unexpected error: \(error.localizedDescription)")
        }
        // A real edit still works.
        let out = try await Tools.edit.run(["file_path": "f.txt", "old_string": "world",
                                            "new_string": "there"], ctx)
        XCTAssertTrue(out.contains("edited"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8),
                       "hello there")
    }

    // "" and "." resolve to the workspace directory itself; write must
    // refuse directory targets instead of attempting the write.
    func testWriteRejectsDirectoryTarget() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ToolContext(workspace: dir.path)
        for p in [".", ""] {
            do {
                _ = try await Tools.write.run(["file_path": p, "content": "x"], ctx)
                XCTFail("write to directory must fail for '\(p)'")
            } catch {}
        }
        // Ordinary file writes are unaffected.
        let out = try await Tools.write.run(["file_path": "ok.txt", "content": "hi"], ctx)
        XCTAssertTrue(out.contains("wrote"))
    }

    // Attachment extraction hops to the blocking pool and back through a
    // continuation; a wiring mistake would hang or drop the batch.
    func testAttachmentsExtraction() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("note.txt")
        try "extracted content here".write(to: f, atomically: true, encoding: .utf8)
        let result = await Extract.attachments(for: [f])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "note.txt")
        XCTAssertTrue(result.first?.extractedText.contains("extracted content") == true,
                      "got: \(result.first?.extractedText ?? "nil")")
    }

    // SSE streaming runs through the client's shared URLSession and the
    // task-indexed delegate; Preview's URLProtocol stands in for the API.
    func testStreamDeliversEventsViaSharedSession() async throws {
        let client = DeepSeekClient(session: Preview.session)
        client.config = .init(baseURL: "https://preview.harness.invalid/v1",
                              apiKey: "k", model: "fixture/fast")
        var texts: [String] = []
        var sawDone = false
        for try await event in client.stream(messages: [WireMessage(role: .user, content: "hi")],
                                             tools: nil) {
            switch event {
            case .text(let d): texts.append(d)
            case .done: sawDone = true
            default: break
            }
        }
        XCTAssertTrue(sawDone, "stream must finish with .done")
        XCTAssertFalse(texts.isEmpty, "preview fixture must yield text deltas")
    }

    // The loopback check must parse address literals, not trust string
    // prefixes: a DNS name like 127.0.0.1.attacker.com must never count as
    // loopback, or the API key rides a plaintext HTTP request to it.
    func testLoopbackHostRejectsDNSWithLoopbackPrefix() {
        XCTAssertFalse(DeepSeekClient.isLoopbackHost("127.0.0.1.attacker.com"))
        XCTAssertFalse(DeepSeekClient.isLoopbackHost("127.evil.example"))
        XCTAssertFalse(DeepSeekClient.isLoopbackHost("localhost.attacker.com"))
        XCTAssertTrue(DeepSeekClient.isLoopbackHost("127.0.0.1"))
        XCTAssertTrue(DeepSeekClient.isLoopbackHost("localhost"))
        XCTAssertTrue(DeepSeekClient.isLoopbackHost("sub.localhost"))
        XCTAssertTrue(DeepSeekClient.isLoopbackHost("::1"))
        XCTAssertTrue(DeepSeekClient.isLoopbackHost("::ffff:127.0.0.1"))
        // inet_pton is strict: shorthand like 127.1 is a DNS name here, not
        // a loopback literal, so it must not carry the key either.
        XCTAssertFalse(DeepSeekClient.isLoopbackHost("127.1"))
        XCTAssertFalse(DeepSeekClient.isLoopbackHost("example.com"))
        XCTAssertFalse(DeepSeekClient.isLoopbackHost("::ffff:8.8.8.8"))
    }

    func testInsecureEndpointRejectedForLoopbackPrefixedDNS() {
        let client = DeepSeekClient()
        client.config.baseURL = "http://127.0.0.1.attacker.com"
        XCTAssertThrowsError(try client.endpoint("models")) { error in
            XCTAssertEqual(error as? ClientError, .insecureEndpoint)
        }
    }

    // The default workspace must be strictly inside the home directory,
    // never the home directory itself — $HOME would be no confinement.
    func testDefaultWorkspaceIsNotTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNotEqual(Settings.defaultWorkspaceURL.path, home.path)
        XCTAssertTrue(Settings.defaultWorkspaceURL.path.hasPrefix(home.path + "/"))
    }

    // Duplicate YAML keys must not trap the dictionary constructor; the
    // parser takes last-wins instead of crashing at launch.
    func testYAMLDuplicateKeysLastWins() {
        let map = YMini.parse("a: 1\na: 2\nb: 3\n")
        XCTAssertEqual(map?.mapPairs["a"]?.intValue, 2)
        XCTAssertEqual(map?.mapPairs["b"]?.intValue, 3)
        let yaml = """
        - insert:
            - id: preset-dup
              name: '@deepseek-ai/dsh-agent-preset'
              config:
                id: dup
                id: dup2
                order: 1
                plugins:
                  - id: persona
                    name: '@deepseek-ai/dsh-persona'
                    config:
                      prefix: You are a helpful assistant.
                      complete: true
        """
        let profile = AgentProfiles.parse(yaml: yaml)
        XCTAssertEqual(profile?.id, "dup2")
    }

    // Wire tool-result pruning: old oversized results shrink to head+tail
    // excerpts, recent turns stay verbatim, small wires are untouched.
    func testPruneOldToolResults() {
        let big = String(repeating: "x", count: 20_000)
        var wire: [WireMessage] = [WireMessage(role: .system, content: "s")]
        for i in 0..<12 {
            wire.append(WireMessage(role: .assistant, content: nil,
                                    tool_calls: [WireToolCall(id: "c\(i)", function: .init(name: "bash", arguments: "{}"))]))
            wire.append(WireMessage(role: .tool, content: big, tool_call_id: "c\(i)", name: "bash"))
        }
        let pruned = AgentLoop.pruneOldToolResults(wire, keepTurns: 4, budget: 10_000)
        // The last 4 tool results stay verbatim.
        XCTAssertEqual(pruned.filter { $0.role == .tool && $0.content == big }.count, 4)
        // Older ones carry the pruning marker and shrink.
        XCTAssertTrue(pruned.contains { $0.role == .tool && $0.content?.contains("pruned") == true })
        XCTAssertLessThan(pruned.reduce(0) { $0 + ($1.content?.utf8.count ?? 0) },
                          wire.reduce(0) { $0 + ($1.content?.utf8.count ?? 0) })
        // Under budget: untouched.
        let smallWire = [WireMessage(role: .system, content: "s"),
                         WireMessage(role: .assistant, content: "hi"),
                         WireMessage(role: .tool, content: "ok", tool_call_id: "c", name: "bash")]
        XCTAssertEqual(AgentLoop.pruneOldToolResults(smallWire, keepTurns: 4, budget: 10_000).map(\.content),
                       smallWire.map(\.content))
    }

    // Child processes must not inherit secret-looking parent env vars:
    // approved shells keep PATH/HOME/etc. but never API keys or tokens.
    func testShellEnvironmentScrubsSecrets() {
        let env = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/test",
            "LANG": "en_US.UTF-8",
            "DEEPSEEK_API_KEY": "sk-secret",
            "AWS_SECRET_ACCESS_KEY": "shh",
            "AWS_CREDENTIAL_FILE": "/tmp/creds",
            "GH_TOKEN": "tok",
            "MY_PASSWORD": "pw",
        ]
        let out = Shell.sanitizedEnvironment(env)
        XCTAssertEqual(out["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(out["HOME"], "/Users/test")
        XCTAssertEqual(out["LANG"], "en_US.UTF-8")
        XCTAssertEqual(out["TERM"], "dumb")
        XCTAssertNil(out["DEEPSEEK_API_KEY"])
        XCTAssertNil(out["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(out["AWS_CREDENTIAL_FILE"])
        XCTAssertNil(out["GH_TOKEN"])
        XCTAssertNil(out["MY_PASSWORD"])
    }

    // Capability vars are stripped too: the ssh-agent socket, dyld
    // interposition, shell startup files, and interpreter code-injection
    // flags never reach a spawned shell.
    func testShellEnvironmentStripsCapabilityVars() {
        let env = [
            "SSH_AUTH_SOCK": "/tmp/ssh-agent",
            "SSH_AGENT_PID": "123",
            "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            "DYLD_PRINT_LIBRARIES": "1",
            "GIT_SSH_COMMAND": "ssh -i /tmp/key",
            "GIT_ASKPASS": "/tmp/askpass",
            "BASH_ENV": "/tmp/bashrc",
            "ZDOTDIR": "/tmp/zsh",
            "NODE_OPTIONS": "--require /tmp/pwn.js",
            "JAVA_TOOL_OPTIONS": "-agentlib:x",
            "PATH": "/usr/bin:/bin",
        ]
        let out = Shell.sanitizedEnvironment(env)
        for key in env.keys where key != "PATH" {
            XCTAssertNil(out[key], "\(key) leaked into the child environment")
        }
        XCTAssertEqual(out["PATH"], "/usr/bin:/bin")
    }

    // The sanitizer must actually be applied to spawned processes, not just
    // pass unit tests as a pure function: run env and inspect its output.
    func testShellCaptureAppliesSanitizedEnvironment() async throws {
        let result = try await Shell.captureAsync(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("TERM=dumb"))
        for marker in ["SSH_AUTH_SOCK", "DYLD_INSERT_LIBRARIES", "DEEPSEEK_API_KEY", "BASH_ENV"] {
            XCTAssertFalse(result.stdout.contains("\(marker)="), "\(marker) leaked into the child env")
        }
    }

    // Tool results with empty content must still encode a non-empty string
    // for the wire: strict API endpoints reject content:"".
    func testEncodeMessagesGuardsEmptyToolContent() throws {
        let wire = [WireMessage(role: .tool, content: "", tool_call_id: "c1", name: "bash")]
        let encoded = try DeepSeekClient.encodeMessages(wire)
        XCTAssertEqual(encoded.count, 1)
        let content = encoded[0]["content"] as? String
        XCTAssertNotNil(content)
        XCTAssertFalse(content!.isEmpty)
    }

    // reasoning_content is display-only: DeepSeek rejects requests that
    // echo it back in input messages, so encoding must strip it.
    func testEncodeMessagesStripsReasoningContent() throws {
        let wire = [WireMessage(role: .assistant, content: "answer", reasoning_content: "chain of thought")]
        let encoded = try DeepSeekClient.encodeMessages(wire)
        XCTAssertEqual(encoded.count, 1)
        XCTAssertNil(encoded[0]["reasoning_content"])
        XCTAssertEqual(encoded[0]["content"] as? String, "answer")
    }

    // Wildcard patterns treat regex metacharacters literally; * and ?
    // keep their glob meaning.
    func testWildcardRegexMatchesLiterally() {
        let rx = Wildcard.regex("file[0].txt")
        XCTAssertEqual(rx.numberOfMatches(in: "file[0].txt",
                                          range: NSRange(location: 0, length: 11)), 1)
        XCTAssertEqual(rx.numberOfMatches(in: "fileX0Y.txt",
                                           range: NSRange(location: 0, length: 11)), 0)
        let star = Wildcard.regex("*.txt")
        XCTAssertEqual(star.numberOfMatches(in: "a.txt",
                                            range: NSRange(location: 0, length: 5)), 1)
        XCTAssertEqual(star.numberOfMatches(in: "a/b.txt",
                                            range: NSRange(location: 0, length: 7)), 0)
    }
}
