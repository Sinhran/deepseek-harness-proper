import Foundation

enum AgentEvent {
    case user(Message)
    case assistantStart(UUID)                 // new assistant bubble, id = message id
    case text(UUID, String)
    case reasoning(UUID, String)
    case discardAssistant(UUID)
    case stepStart(UUID, Step)                // (messageID, step)
    case stepFinish(UUID, Step)
    case status(String)                       // "Turn 3 · working..."
    case change(FileChange)
    case done
    case failed(String)
}

final class AgentLoop {
    private final class ChangeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var turn = 0
        private var changes: [FileChange] = []
        private let onChange: (FileChange) -> Void

        init(onChange: @escaping (FileChange) -> Void) { self.onChange = onChange }
        func setTurn(_ turn: Int) { lock.lock(); self.turn = turn; lock.unlock() }
        func record(_ change: FileChange) {
            lock.lock()
            var value = change
            value.turn = turn
            changes.append(value)
            lock.unlock()
            onChange(value)
        }
        func take() -> [FileChange] {
            lock.lock(); defer { lock.unlock() }
            let result = changes
            changes.removeAll()
            return result
        }
    }

    var client = DeepSeekClient()
    var onEvent: (AgentEvent) -> Void = { _ in }
    /// Resolve approval for a gated tool call. Called on any thread; UI dispatches to main.
    /// Defaults to deny: a caller that forgets to install a handler must never
    /// silently auto-approve gated tools.
    var approve: (String, String) async -> Bool = { _, _ in false }
    /// When set, only these tool names may be advertised or executed, whatever
    /// the profile, autonomy level, or a forged tool call says. Used by the
    /// transpiler sub-loop to confine itself to write/edit.
    var allowedTools: Set<String>? = nil
    /// Upper bound on the global autonomy setting for this loop and its
    /// subagents. Unattended runs (scheduled tasks) set this so switching the
    /// app to Full autonomy later never grants saved automations — some of
    /// which an agent may have created — unattended shell access.
    var autonomyCap: Autonomy? = nil
    private var autonomy: Autonomy { Settings.shared.autonomy.capped(at: autonomyCap) }
    private let cancelLock = NSLock()
    private var cancelFlag = false
    private var cancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelFlag || Task.isCancelled }
        set { cancelLock.lock(); cancelFlag = newValue; cancelLock.unlock() }
    }

    func cancel() { cancelled = true }

    func makeContext(session: Session, depth: Int = 0) -> ToolContext {
        ToolContext(
            workspace: session.workspace,
            depth: depth,
            recordChange: { [weak self] c in self?.onEvent(.change(c)) },
            scheduler: Scheduler.shared,
            plugins: PluginEngine.shared,
            makeSubloop: { [weak self, client] in
                let l = AgentLoop(); l.client = client
                l.approve = self?.approve ?? { _, _ in false }
                l.allowedTools = self?.allowedTools
                // A missing parent must fail closed, not lift the cap.
                l.autonomyCap = self == nil ? .ask : self?.autonomyCap
                return l
            })
    }

    /// Full interactive run against a persisted session. Returns the mutated session.
    @discardableResult
    /// `wireContent` replays an earlier turn's exact API-side text (Regenerate):
    /// attachment blocks included, while the visible message stays `userText`.
    func run(session: Session, userText: String, attachments: [Attachment] = [],
             wireContent: String? = nil) async -> Session {
        var s = session
        cancelled = false
        var turn = (s.messages.map(\.turn).max() ?? 0)
        var content = userText
        for a in attachments where !a.extractedText.isEmpty {
            content += Self.attachmentBlock(a)
        }
        if let wireContent { content = wireContent }
        var ctx = makeContext(session: s)
        let changeRecorder = ChangeRecorder { [weak self] in self?.onEvent(.change($0)) }
        ctx.recordChange = { changeRecorder.record($0) }

        let userMsg = Message(role: .user, content: userText, turn: turn + 1)
        s.messages.append(userMsg)
        onEvent(.user(userMsg))
        s.wire.append(WireMessage(role: .user, content: content))
        if s.messages.count == 1 && s.title == "New session" {
            s.title = String(userText.prefix(60))
        }
        s.updated = Date()

        let maxTurns = 40
        let firstTurn = turn
        var specs = toolSpecs()

        while turn - firstTurn < maxTurns && !cancelled {
            turn += 1
            changeRecorder.setTurn(turn)
            // turn indexes the whole session wire; count this run's turns
            // so a follow-up message starts over at "Deep diving...".
            let runTurn = turn - firstTurn
            onEvent(.status(runTurn == 1 ? "Deep diving..." : "Turn \(runTurn)"))

            var msg = Message(role: .assistant, turn: turn)
            onEvent(.assistantStart(msg.id))

            var calls: [Int: WireToolCall] = [:]
            do {
                for try await ev in client.stream(messages: s.wire, tools: specs) {
                    if cancelled { break }
                    switch ev {
                    case .text(let d):
                        msg.content += d; onEvent(.text(msg.id, d))
                    case .reasoning(let d):
                        msg.reasoning += d; onEvent(.reasoning(msg.id, d))
                    case .toolCall(let i, let id, let name, let d):
                        var c = calls[i] ?? WireToolCall(id: "", function: .init(name: "", arguments: ""))
                        if let id { c.id = id }
                        if let name { c.function.name = name }
                        if let d { c.function.arguments += d }
                        calls[i] = c
                    case .usage, .done: break
                    }
                }
            } catch {
                if !cancelled {
                    msg.content += "\n\n**(error)** \(error.localizedDescription)"
                    onEvent(.text(msg.id, "\n\n**(error)** \(error.localizedDescription)"))
                }
                if msg.content.isEmpty && msg.reasoning.isEmpty && msg.steps.isEmpty {
                    onEvent(.discardAssistant(msg.id))
                } else {
                    s.messages.append(msg); s.updated = Date()
                    s.wire.append(WireMessage(role: .assistant,
                                              content: msg.content.isEmpty ? nil : msg.content,
                                              reasoning_content: msg.reasoning.isEmpty ? nil : msg.reasoning))
                }
                if !cancelled { onEvent(.failed(error.localizedDescription)) }
                s.changes.append(contentsOf: changeRecorder.take())
                onEvent(.done)
                return s
            }

            let sorted = cancelled ? [] : calls.keys.sorted().map { calls[$0]! }
            if cancelled && msg.content.isEmpty && msg.reasoning.isEmpty && msg.steps.isEmpty {
                onEvent(.discardAssistant(msg.id))
                break
            }
            s.wire.append(WireMessage(role: .assistant,
                                      content: msg.content.isEmpty ? nil : msg.content,
                                      reasoning_content: msg.reasoning.isEmpty ? nil : msg.reasoning,
                                      tool_calls: sorted.isEmpty ? nil : sorted))

            if sorted.isEmpty || cancelled {
                if msg.content.isEmpty && msg.reasoning.isEmpty && msg.steps.isEmpty {
                    onEvent(.discardAssistant(msg.id))
                } else {
                    s.messages.append(msg); s.updated = Date()
                }
                break
            }

            // Execute tool calls, append results, continue the turn loop.
            for call in sorted {
                if cancelled {
                    s.wire.append(WireMessage(role: .tool, content: "Cancelled before execution.", tool_call_id: call.id, name: call.function.name))
                    continue
                }
                var step = Step(name: call.function.name, payload: call.function.arguments, status: .running)
                onEvent(.stepStart(msg.id, step))
                let started = Date()
                let result: String
                do {
                    result = try await execute(call: call, ctx: ctx, specs: specs)
                    step.status = .ok
                } catch ToolError.denied {
                    step.status = .denied
                    step.result = "Denied by user."
                    s.wire.append(WireMessage(role: .tool, content: "Tool call denied by user.",
                                              tool_call_id: call.id, name: call.function.name))
                    step.durationMS = Int(Date().timeIntervalSince(started) * 1000)
                    msg.steps.append(step); onEvent(.stepFinish(msg.id, step))
                    continue
                } catch {
                    step.status = .error
                    step.result = "error: \(error.localizedDescription)"
                    s.wire.append(WireMessage(role: .tool, content: "error: \(error.localizedDescription)",
                                              tool_call_id: call.id, name: call.function.name))
                    step.durationMS = Int(Date().timeIntervalSince(started) * 1000)
                    msg.steps.append(step); onEvent(.stepFinish(msg.id, step))
                    continue
                }
                step.result = result
                step.durationMS = Int(Date().timeIntervalSince(started) * 1000)
                step.status = .ok
                msg.steps.append(step)
                onEvent(.stepFinish(msg.id, step))
                s.wire.append(WireMessage(role: .tool, content: String(result.prefix(60_000)),
                                          tool_call_id: call.id, name: call.function.name))
            }
            if msg.content.isEmpty && msg.reasoning.isEmpty && msg.steps.isEmpty {
                onEvent(.discardAssistant(msg.id))
            } else {
                s.messages.append(msg); s.updated = Date()
            }
            specs = toolSpecs() // plugins may have registered new tools mid-run
            s.wire = Self.pruneOldToolResults(s.wire)
        }
        // Cancellation can leave an assistant turn whose tool_calls were never
        // answered; the persisted wire must still be a valid request.
        s.wire = Self.repairDanglingToolCalls(s.wire)

        if turn - firstTurn >= maxTurns { onEvent(.status("Stopped: turn limit reached")) }
        s.changes.append(contentsOf: changeRecorder.take())
        onEvent(.done)
        return s
    }

    /// Wrap extracted attachment text for the wire. Attribute values are
    /// XML-escaped, and any closing tag inside the body is neutralized, so a
    /// file cannot end its own block early and pose as user instructions.
    static func attachmentBlock(_ a: Attachment) -> String {
        func attr(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = a.extractedText.replacingOccurrences(
            of: "</attachment", with: "<\\/attachment", options: .caseInsensitive)
        return "\n\n<attachment name=\"\(attr(a.name))\" path=\"\(attr(a.path))\">\n\(body)\n</attachment>"
    }

    /// Headless run for subagents and scheduled tasks. Returns final assistant text.
    func runHeadless(prompt: String, ctx: ToolContext, maxTurns: Int = 15) async throws -> String {
        cancelled = false
        var wire = [WireMessage(role: .system, content: "You are a DeepSeek Harness subagent. Workspace: \(ctx.workspace). Complete the task, reply with the result."),
                    WireMessage(role: .user, content: prompt)]
        var specs = toolSpecs()
        var turn = 0
        while turn < maxTurns && !cancelled {
            turn += 1
            var text = ""; var reasoning = ""; var calls: [Int: WireToolCall] = [:]
            for try await ev in client.stream(messages: wire, tools: specs) {
                if cancelled { break }
                switch ev {
                case .text(let d): text += d
                case .reasoning(let d): reasoning += d
                case .toolCall(let i, let id, let name, let d):
                    var c = calls[i] ?? WireToolCall(id: "", function: .init(name: "", arguments: ""))
                    if let id { c.id = id }; if let name { c.function.name = name }; if let d { c.function.arguments += d }
                    calls[i] = c
                default: break
                }
            }
            if cancelled { throw CancellationError() }
            let sorted = calls.keys.sorted().map { calls[$0]! }
            wire.append(WireMessage(role: .assistant, content: text.isEmpty ? nil : text,
                                    reasoning_content: reasoning.isEmpty ? nil : reasoning,
                                    tool_calls: sorted.isEmpty ? nil : sorted))
            if sorted.isEmpty { return text }
            for call in sorted {
                if cancelled { throw CancellationError() }
                let result: String
                do { result = try await execute(call: call, ctx: ctx, specs: specs) }
                catch is CancellationError { throw CancellationError() }
                catch { result = "error: \(error.localizedDescription)" }
                wire.append(WireMessage(role: .tool, content: String(result.prefix(60_000)),
                                        tool_call_id: call.id, name: call.function.name))
            }
            specs = toolSpecs() // plugins may have registered new tools mid-run
            wire = Self.pruneOldToolResults(wire)
            wire = Self.repairDanglingToolCalls(wire)
        }
        if cancelled { throw CancellationError() }
        return "(subagent reached turn limit)"
    }

    /// Deterministic tool-result pruning (upstream tool-result-pruner
    /// semantics): once the wire exceeds a byte budget, tool results older
    /// than the most recent turns are reduced to head+tail excerpts so long
    /// sessions stop growing without bound. Recent turns stay verbatim.
    static func pruneOldToolResults(_ wire: [WireMessage], keepTurns: Int = 8,
                                    budget: Int = 400_000, threshold: Int = 8_192,
                                    head: Int = 4_096, tail: Int = 1_024) -> [WireMessage] {
        let total = wire.reduce(0) { $0 + ($1.content?.utf8.count ?? 0) }
        guard total > budget else { return wire }
        var assistantTurns = 0
        var cutoff = wire.count
        for i in wire.indices.reversed() {
            if wire[i].role == .assistant, wire[i].tool_calls != nil {
                assistantTurns += 1
                if assistantTurns >= keepTurns { cutoff = i; break }
            }
        }
        // Fewer tool turns than keepTurns: every result is recent, so there is
        // nothing old to prune. (Falling through with cutoff == wire.count
        // would make `i < cutoff` true for EVERY message and truncate the
        // freshest result too.)
        guard cutoff < wire.count, cutoff > 0 else { return wire }
        return wire.enumerated().map { i, m in
            guard i < cutoff, m.role == .tool, let c = m.content, c.utf8.count > threshold else { return m }
            var pruned = m
            pruned.content = String(c.prefix(head))
                + "\n…(pruned from \(c.utf8.count) bytes to fit the context budget)…\n"
                + String(c.suffix(tail))
            return pruned
        }
    }

    /// Every `tool_calls` entry on the wire must be followed by exactly one
    /// `tool` message with the same id, or OpenAI-compatible endpoints reject
    /// the next request. Cancellation can land between appending an assistant
    /// turn and executing its calls, leaving ids with no result; this inserts
    /// a placeholder for each missing one.
    static func repairDanglingToolCalls(_ wire: [WireMessage]) -> [WireMessage] {
        var answered = Set<String>()
        for m in wire where m.role == .tool {
            if let id = m.tool_call_id { answered.insert(id) }
        }
        var out: [WireMessage] = []
        out.reserveCapacity(wire.count)
        var i = 0
        while i < wire.count {
            let m = wire[i]
            out.append(m)
            i += 1
            guard m.role == .assistant, let calls = m.tool_calls, !calls.isEmpty else { continue }
            // Copy this turn's result run verbatim, then append placeholders
            // for any call id the run does not answer.
            while i < wire.count, wire[i].role == .tool {
                out.append(wire[i]); i += 1
            }
            for call in calls where !answered.contains(call.id) {
                answered.insert(call.id)
                out.append(WireMessage(role: .tool, content: "Cancelled before execution.",
                                       tool_call_id: call.id, name: call.function.name))
            }
        }
        return out
    }

    private func toolSpecs() -> [ToolSpec] {
        // A loop-specific allowlist replaces the profile set and caps plugins.
        let allowed = allowedTools ?? AgentProfiles.profile(id: Settings.shared.agentProfile).nativeTools
        var specs = Tools.all().filter { allowed.contains($0.spec.name) }.map { $0.spec }
        specs += PluginEngine.shared.agentToolSpecs()
        specs += MCPHub.shared.toolSpecs()
        if let only = allowedTools { specs = specs.filter { only.contains($0.name) } }
        return specs
    }

    private func execute(call: WireToolCall, ctx: ToolContext, specs: [ToolSpec]) async throws -> String {
        let name = call.function.name
        let args = JSON.object(call.function.arguments)

        // Reject anything that was not advertised to the model this turn:
        // a forged or hallucinated call must not reach a tool the profile
        // (or this loop's allowlist) excluded.
        guard specs.contains(where: { $0.name == name }) else {
            throw ToolError.failed("tool not available: \(name)")
        }

        // Plugin-provided tool?
        if PluginEngine.shared.agentToolSpecs().contains(where: { $0.name == name }) {
            if Tools.category(.meta, needsApproval: autonomy),
               !(await approve(name, call.function.arguments)) { throw ToolError.denied }
            guard let result = try await PluginEngine.shared.invokeTool(name: name, args: args) else {
                throw ToolError.failed("plugin tool unavailable: \(name)")
            }
            return result
        }
        // MCP server tool? Read-only ones approve like reads, the rest
        // (clicks, typing, writes) like shell.
        if MCPHub.shared.owns(name) {
            if Tools.category(MCPHub.shared.category(name, arguments: args), needsApproval: autonomy),
               !(await approve(MCPHub.shared.displayName(name, arguments: args) ?? name, Self.summarize(call: call))) {
                throw ToolError.denied
            }
            return try await MCPHub.shared.call(name, arguments: args)
        }
        guard let tool = Tools.all().first(where: { $0.spec.name == name }) else {
            throw ToolError.failed("unknown tool \(name)")
        }
        var ctx = ctx
        if name == "bash", args.bool("unsandboxed"), ctx.sandbox != .fullAccess {
            // Escaping the sandbox is its own decision: asked every time,
            // whatever the autonomy level. Unattended runs deny it.
            let ok = await approve(name, "Outside the sandbox: " + Self.summarize(call: call))
            if !ok { throw ToolError.failed("The user declined running this command outside the sandbox.") }
            ctx.sandbox = .fullAccess
        } else if Tools.category(tool.category, needsApproval: autonomy) {
            let ok = await approve(name, Self.summarize(call: call))
            if !ok { throw ToolError.denied }
        }
        return try await tool.run(args, ctx)
    }

    private static func summarize(call: WireToolCall) -> String {
        let o = JSON.object(call.function.arguments)
        switch call.function.name {
        case "bash": return o.str("command") ?? call.function.arguments
        case "read", "write", "edit": return o.str("file_path") ?? call.function.arguments
        case "grep": return "\(o.str("pattern") ?? "") in \(o.str("path") ?? ".")"
        case "web_fetch": return o.str("url") ?? ""
        case "web_search": return o.str("query") ?? ""
        default: return call.function.arguments
        }
    }
}
