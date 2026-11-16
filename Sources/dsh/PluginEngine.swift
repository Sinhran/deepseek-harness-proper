import Foundation
import JavaScriptCore

/// Plugin layout on disk (~/Library/Application Support/dsh-proper/plugins/<id>/):
///   plugin.json   {"id","name","version","description","kind": js|native|manifest,
///                  "main": "index.js", "tools": [...], "commands": [...], "skills": [...],
///                  "binary": "bin", "config": {...}}
///   index.js / plugin.swift + bin / manifest only
///   state.json  (ctx.store persistence)

final class PluginEngine {
    static let shared = PluginEngine()
    private var _records: [PluginRecord] = []
    /// Snapshot of discovered plugins. All registry state lives behind
    /// `registryLock`; JS callbacks and agent dispatch read through it.
    var records: [PluginRecord] { withRegistry { _records } }
    private var jsRuntimes: [String: JSRuntime] = [:]
    private var nativeTools: [String: (dir: URL, bin: String)] = [:] // toolName -> (dir, bin)
    private var jsTools: [String: String] = [:]      // toolName -> pluginID
    private var toolSpecs: [String: ToolSpec] = [:]  // toolName -> spec
    private var commands: [(plugin: String, name: String, template: String)] = []
    private var skills: [(plugin: String, name: String, markdown: String)] = []
    private let registryLock = NSRecursiveLock()
    private func withRegistry<T>(_ body: () -> T) -> T { registryLock.lock(); defer { registryLock.unlock() }; return body() }
    /// Keep a manifest-relative path inside the plugin dir; nil on escape.
    static func confined(_ dir: URL, _ rel: String) -> URL? {
        if rel.hasPrefix("~") { return nil }
        guard let path = try? ToolContext.resolveChecked(rel, within: dir.path) else { return nil }
        return URL(fileURLWithPath: path)
    }
    var changed: () -> Void

    private init(changed: @escaping () -> Void = {}) {
        self.changed = changed
        reload()
    }

    func reload() {
        let found = discover()
        withRegistry {
            jsRuntimes.values.forEach { $0.dispose() }
            jsRuntimes.removeAll(); nativeTools.removeAll(); jsTools.removeAll()
            toolSpecs.removeAll(); commands.removeAll(); skills.removeAll()
            _records = found
            for r in _records where r.enabled && r.broken == nil {
                switch r.kind {
                case .js: loadJS(r)
                case .native: indexNative(r)
                case .manifest: indexManifest(r)
                }
            }
        }
        changed()
    }

    // MARK: Discovery

    func discover() -> [PluginRecord] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: Settings.pluginsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [PluginRecord] = []
        for dir in dirs where dir.hasDirectoryPath {
            let id = dir.lastPathComponent
            let manifestURL = dir.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // bare JS bundle without manifest: sniff package.json or index.js
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.js").path)
                    || FileManager.default.fileExists(atPath: dir.appendingPathComponent("package.json").path) {
                    out.append(PluginRecord(id: id, name: id, kind: .js))
                }
                continue
            }
            let kind = PluginKind(rawValue: m["kind"] as? String ?? "js") ?? .js
            var rec = PluginRecord(id: id,
                                    name: m["name"] as? String ?? id,
                                    version: m["version"] as? String ?? "",
                                    desc: m["description"] as? String ?? "",
                                    kind: kind)
            // Absent "enabled" means untrusted: new bundles stay off until an
            // explicit enable (UI or plugin_manager) writes the key.
            rec.enabled = m["enabled"] as? Bool ?? false
            out.append(rec)
        }
        return out.sorted { $0.name < $1.name }
    }

    private func manifest(_ id: String) -> [String: Any] {
        let u = Settings.pluginsDir.appendingPathComponent(id).appendingPathComponent("plugin.json")
        guard let d = try? Data(contentsOf: u) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    // MARK: Manifest plugins (no code)

    private func indexManifest(_ r: PluginRecord) {
        let m = manifest(r.id)
        for c in m["commands"] as? [[String: Any]] ?? [] {
            if let n = c["name"] as? String, let t = c["template"] as? String {
                commands.append((r.id, n, t))
            }
        }
        for s in m["skills"] as? [[String: Any]] ?? [] {
            if let n = s["name"] as? String {
                var md = s["content"] as? String ?? ""
                if let f = s["file"] as? String,
                   let u = Self.confined(Settings.pluginsDir.appendingPathComponent(r.id), f) {
                    md = (try? String(contentsOf: u, encoding: .utf8)) ?? md
                }
                if !md.isEmpty { skills.append((r.id, n, md)) }
            }
        }
    }

    // MARK: Native plugins (compiled Swift binaries, stdio JSON protocol)

    private func indexNative(_ r: PluginRecord) {
        let m = manifest(r.id)
        let dir = Settings.pluginsDir.appendingPathComponent(r.id)
        guard let bin = m["binary"] as? String, let binURL = Self.confined(dir, bin),
              FileManager.default.isExecutableFile(atPath: binURL.path) else {
            markBroken(r.id, "native binary missing")
            return
        }
        for t in m["tools"] as? [[String: Any]] ?? [] {
            if let n = t["name"] as? String, !Self.isBuiltinTool(n),
               nativeTools[n] == nil, jsTools[n] == nil {
                // First plugin to claim a name wins; later collisions are
                // ignored so registration order cannot hijack a tool.
                nativeTools[n] = (dir, bin)
                toolSpecs[n] = ToolSpec(name: n,
                                        description: t["description"] as? String ?? "",
                                        parameters: t["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]])
            }
        }
        for c in m["commands"] as? [[String: Any]] ?? [] {
            if let n = c["name"] as? String, let t = c["template"] as? String { commands.append((r.id, n, t)) }
        }
    }

    private func runNative(_ tool: String, dir: URL, bin: String, args: [String: Any]) async throws -> String {
        guard let binURL = Self.confined(dir, bin) else { throw ToolError.failed("plugin binary escapes plugin dir") }
        let result = try await Shell.captureAsync(executable: binURL, arguments: [tool],
                                                  input: JSON.compact(args).data(using: .utf8), timeout: 30)
        if result.timedOut { throw ToolError.failed("plugin exceeded 30s") }
        if result.status != 0 {
            throw ToolError.failed("plugin exited \(result.status): \(result.stderr.prefix(500))")
        }
        return String(result.stdout.prefix(200_000))
    }

    // MARK: JS plugins (JavaScriptCore, system framework)

    private func loadJS(_ r: PluginRecord) {
        let dir = Settings.pluginsDir.appendingPathComponent(r.id)
        let m = manifest(r.id)
        var entry = m["main"] as? String
        if entry == nil, let pkg = try? String(contentsOf: dir.appendingPathComponent("package.json"), encoding: .utf8),
           let p = JSON.object(pkg)["main"] as? String { entry = p }
        let entryName = entry ?? "index.js"
        guard let entryURL = Self.confined(dir, entryName) else {
            markBroken(r.id, "entry escapes plugin dir"); return
        }
        guard let src = try? String(contentsOf: entryURL, encoding: .utf8) else {
            markBroken(r.id, "entry \(entryName) unreadable"); return
        }
        let rt = JSRuntime(pluginID: r.id, dir: dir, engine: self)
        jsRuntimes[r.id] = rt
        rt.queue.async {
            rt.start(source: src, entryPath: entryURL.path)
        }
        // JSRuntime installs a 20s execution-time limit on the VM, so a
        // top-level infinite loop terminates itself and the queue continues.
        // This watchdog is the backstop for the remaining case (a plugin that
        // never returns from a native bridge call): it marks the plugin
        // broken so nothing tries to use a runtime that never finished.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25) { [weak rt, weak self] in
            guard let rt else { return }
            if !rt.startCompleted {
                self?.markBroken(r.id, "JS plugin load timed out", runtime: rt)
            }
        }
    }

    func markBroken(_ id: String, _ why: String, runtime: JSRuntime? = nil) {
        let didChange = withRegistry { () -> Bool in
            if let runtime, jsRuntimes[id] !== runtime { return false }
            guard let i = _records.firstIndex(where: { $0.id == id }) else { return false }
            _records[i].broken = why
            // A broken plugin must not keep whatever it registered before
            // failing: its tools, commands, and skills stay live otherwise.
            let dirPath = Settings.pluginsDir.appendingPathComponent(id).path
            for (name, plugin) in jsTools where plugin == id {
                jsTools.removeValue(forKey: name); toolSpecs.removeValue(forKey: name)
            }
            for (name, native) in nativeTools where native.dir.path == dirPath {
                nativeTools.removeValue(forKey: name); toolSpecs.removeValue(forKey: name)
            }
            commands.removeAll { $0.plugin == id }
            skills.removeAll { $0.plugin == id }
            return true
        }
        if didChange { changed() }
    }

    func isCurrent(_ runtime: JSRuntime) -> Bool {
        withRegistry { jsRuntimes[runtime.pluginID] === runtime }
    }

    func runtimeDidChange(_ runtime: JSRuntime) {
        if isCurrent(runtime) { changed() }
    }

    // MARK: Registration sinks (called from JS bridges)

    static func isBuiltinTool(_ n: String) -> Bool {
        ["bash","read","write","edit","grep","glob","web_fetch","web_search",
         "schedule_create","schedule_list","schedule_delete","subagent","plugin_manager"].contains(n)
    }
    func registerTool(pluginID: String, specJSON: String) {
        let o = JSON.object(specJSON)
        guard let n = o["name"] as? String, !Self.isBuiltinTool(n) else { return }
        withRegistry {
            // First plugin to claim a name wins; later collisions are ignored so
            // registration order cannot hijack an existing tool.
            if jsTools[n] != nil || nativeTools[n] != nil { return }
            toolSpecs[n] = ToolSpec(name: n,
                                    description: o["description"] as? String ?? "",
                                    parameters: o["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]])
            jsTools[n] = pluginID
        }
    }
    func registerCommand(pluginID: String, name: String, template: String) {
        withRegistry { commands.append((pluginID, name, template)) }
    }
    func registerSkill(pluginID: String, name: String, markdown: String) {
        withRegistry { skills.append((pluginID, name, markdown)) }
    }

    // MARK: Agent-facing surface

    func agentToolSpecs() -> [ToolSpec] { withRegistry { Array(toolSpecs.values) } }

    func invokeTool(name: String, args: [String: Any]) async throws -> String? {
        let (js, native) = withRegistry { (jsTools[name].flatMap { jsRuntimes[$0] }, nativeTools[name]) }
        if let rt = js {
            return try await rt.invokeTool(name: name, args: JSON.compact(args))
        }
        if let n = native {
            return try await runNative(name, dir: n.dir, bin: n.bin, args: args)
        }
        return nil
    }

    func slashCommands() -> [(plugin: String, name: String, template: String)] { withRegistry { commands } }

    func expandCommand(_ name: String, args: String) -> String? {
        withRegistry { commands.first(where: { $0.name == name }) }?.template
            .replacingOccurrences(of: "{args}", with: args)
            .replacingOccurrences(of: "$ARGUMENTS", with: args)
    }

    func skillBlocks() -> String {
        withRegistry { skills.map { "### Skill: \($0.name) (plugin \($0.plugin))\n\($0.markdown)" }.joined(separator: "\n\n") }
    }

    // MARK: Management

    func install(from dir: URL) throws -> String {
        let src = dir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            if FileManager.default.fileExists(atPath: src.path) {
                let id = src.deletingPathExtension().lastPathComponent
                try Self.validatePluginID(id)
                let dest = Settings.pluginsDir.appendingPathComponent(id)
                guard !FileManager.default.fileExists(atPath: dest.path) else {
                    throw ToolError.failed("plugin \(id) already installed; uninstall it first")
                }
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: dest.appendingPathComponent("index.js"))
                writeManifestStub(id: id, kind: "js", name: id)
                reload()
                return "installed \(id) (wrapped single file)"
            }
            throw ToolError.failed("\(dir.path) is not a directory or file")
        }
        let id = src.lastPathComponent
        try Self.validatePluginID(id)
        let dest = Settings.pluginsDir.appendingPathComponent(id)
        let srcStd = src.standardizedFileURL, destStd = dest.standardizedFileURL
        guard !destStd.path.hasPrefix(srcStd.path + "/"), srcStd.path != destStd.path else {
            throw ToolError.failed("install source contains the plugins directory")
        }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw ToolError.failed("plugin \(id) already installed; uninstall it first")
        }
        // Reject symlinks and oversized bundles before copying anything.
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: src, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) {
            for case let u as URL in e.allObjects {
                let v = try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                if v?.isSymbolicLink == true { throw ToolError.failed("plugin bundle contains a symlink: \(u.lastPathComponent)") }
                total += Int64(v?.fileSize ?? 0)
                if total > 50_000_000 { throw ToolError.failed("plugin bundle too large (>50MB)") }
            }
        }
        let tmp = Settings.pluginsDir.appendingPathComponent(".install-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        if !FileManager.default.fileExists(atPath: dest.appendingPathComponent("plugin.json").path) {
            let kind = FileManager.default.fileExists(atPath: dest.appendingPathComponent("plugin.swift").path) ? "native" : "js"
            writeManifestStub(id: id, kind: kind, name: id)
        } else {
            // The bundle's manifest is kept (name/version/tools/config), but
            // its self-asserted "enabled" flag is not: installing is not
            // enabling. Without this, a bundle shipping "enabled": true runs
            // arbitrary code on the very next reload.
            forceDisabled(dest)
        }
        reload()
        return "installed \(id)"
    }

    static func validatePluginID(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw ToolError.failed("invalid plugin id: \(id)")
        }
    }

    private func writeManifestStub(id: String, kind: String, name: String) {
        let m: [String: Any] = ["id": id, "name": name, "kind": kind, "main": "index.js"]
        let u = Settings.pluginsDir.appendingPathComponent(id).appendingPathComponent("plugin.json")
        try? JSON.compact(m).write(to: u, atomically: true, encoding: .utf8)
    }

    /// Rewrite an installed bundle's manifest with "enabled": false, keeping
    /// every other key. A bundle that ships "enabled": true must not be able
    /// to grant itself trust by being installed.
    private func forceDisabled(_ dir: URL) {
        let u = dir.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: u),
              var m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        m["enabled"] = false
        try? JSON.compact(m).write(to: u, atomically: true, encoding: .utf8)
    }

    func uninstall(_ id: String) throws {
        try Self.validatePluginID(id)
        guard withRegistry({ _records.contains(where: { $0.id == id }) }) else { throw ToolError.failed("no plugin \(id)") }
        let target = Settings.pluginsDir.appendingPathComponent(id).standardizedFileURL
        guard target.deletingLastPathComponent().standardizedFileURL.path == Settings.pluginsDir.standardizedFileURL.path else {
            throw ToolError.failed("invalid plugin id: \(id)")
        }
        let rt = withRegistry { () -> JSRuntime? in
            let rt = jsRuntimes.removeValue(forKey: id); rt?.dispose(); return rt
        }
        _ = rt
        try FileManager.default.removeItem(at: target)
        reload()
    }

    func setEnabled(_ id: String, _ enabled: Bool) throws {
        let found = withRegistry { () -> Bool in
            guard let i = _records.firstIndex(where: { $0.id == id }) else { return false }
            _records[i].enabled = enabled
            return true
        }
        // An unknown id is an error, not a no-op: plugin_manager would
        // otherwise report "enabled foo" for a plugin that does not exist.
        guard found else { throw ToolError.failed("no plugin \(id)") }
        setManifestEnabled(id, enabled)
        reload()
    }

    /// Transpile a JS plugin to a native Swift binary via a compile-fix agent loop.
    /// Called from inside the agent's plugin_manager tool; uses a fresh headless loop.
    func transpileToNative(name: String) async throws -> String {
        guard let record = records.first(where: { $0.id == name }) else { throw ToolError.failed("no plugin \(name)") }
        // Trust is the user's, not the model's: the sub-loop rewrites
        // plugin.json, and whatever "enabled" it writes (or drops) must not
        // decide whether the plugin runs. A successful transpile always ends
        // disabled; a failed one restores the JS plugin's previous state.
        let wasEnabled = record.enabled
        let dir = Settings.pluginsDir.appendingPathComponent(name)
        let m = manifest(name)
        guard let entry = Self.confined(dir, m["main"] as? String ?? "index.js"),
              let js = try? String(contentsOf: entry, encoding: .utf8) else { throw ToolError.failed("cannot read JS source") }

        var ctx = ToolContext(workspace: dir.path, depth: 0)
        let loop = AgentLoop()
        // Dispatch-level allowlist: read/write/edit only, enforced regardless
        // of autonomy. Path confinement is NOT re-checked here: `summary` is a
        // display string (raw JSON for some tools), not the tool's resolved
        // argument, so resolving it would be theatre. The real boundary is the
        // sub-loop's ToolContext(workspace: dir.path), which every file tool
        // resolves through.
        loop.allowedTools = ["read", "write", "edit"]
        loop.approve = { name, _ in
            name == "read" || name == "write" || name == "edit"
        }
        let client = DeepSeekClient()
        let model = await MainActor.run {
            ModelCatalog.preferredModel(models: ModelCatalog.shared.models,
                                        settingsDefault: Settings.shared.model,
                                        sessionModel: "")
        }
        guard !model.isEmpty else { throw ToolError.failed("no available model for plugin transpilation") }
        client.config = .init(baseURL: Settings.shared.baseURL,
                              apiKey: Settings.shared.apiKey,
                              model: model)
        loop.client = client

        let prompt = """
        Convert this JavaScript dsh plugin to a native Swift plugin.

        JS source:
        ```js
        \(js)
        ```

        Write plugin.swift in the current directory implementing the plugin as a CLI binary:
        - argv[1] is the tool name, stdin is a JSON object of arguments, stdout is the JSON/text result.
        - If the plugin registers multiple tools, dispatch on argv[1].
        - If the plugin registers commands/skills instead of tools, still write the binary to print a
          small JSON {"ok":true} and put commands/skills into plugin.json instead.
        Also update plugin.json: set "kind":"native", "binary":"bin", and a "tools" array with
        each tool's {"name","description","parameters"}.
        Do not use any Swift libraries beyond Foundation + JavaScriptCore.
        """
        ctx.plugins = self
        _ = try await loop.runHeadless(prompt: prompt, ctx: ctx, maxTurns: 20)

        // compile
        let srcFile = dir.appendingPathComponent("plugin.swift")
        let bin = dir.appendingPathComponent("bin")
        // Drop any previous binary: an isExecutableFile check after a failed
        // compile would otherwise pass on the stale artifact.
        try? FileManager.default.removeItem(at: bin)
        var lastErr = ""
        let attempts = 3
        for attempt in 1...attempts {
            let out = try await Shell.run("xcrun swiftc -O -o bin plugin.swift 2>&1", cwd: dir.path, timeout: 120)
            if FileManager.default.isExecutableFile(atPath: bin.path) {
                // Transpiling leaves the JS sandbox: the binary is unconfined
                // native code, written by a model that read the plugin's own
                // (untrusted) source. Trust granted to the JS version does not
                // carry over; the user must review and enable it again.
                setManifestEnabled(name, false)
                reload()
                return "transpiled \(name) to native Swift (compiled \(srcFile.lastPathComponent)). "
                    + "The plugin is now DISABLED: native plugins run unsandboxed, so review "
                    + "plugin.swift and enable it explicitly."
            }
            lastErr = out
            // No fix round after the final compile: its edits would never
            // be compiled, so it only burns an LLM call.
            guard attempt < attempts else { break }
            let current = (try? String(contentsOf: srcFile, encoding: .utf8)) ?? ""
            let fix = """
            The plugin.swift failed to compile:
            ```
            \(out.prefix(3000))
            ```
            Original JavaScript source:
            ```js
            \(js)
            ```
            Current plugin.swift:
            ```swift
            \(current)
            ```
            Read or edit plugin.swift, fix the errors, and try again.
            """
            _ = try? await loop.runHeadless(prompt: fix, ctx: ctx, maxTurns: 6)
        }
        setManifestEnabled(name, wasEnabled)
        markBroken(name, "transpile failed: \(lastErr.prefix(300))")
        throw ToolError.failed("transpile failed: \(lastErr.prefix(300))")
    }

    /// Write `enabled` into a plugin's manifest, keeping every other key.
    private func setManifestEnabled(_ id: String, _ enabled: Bool) {
        var m = manifest(id); m["enabled"] = enabled
        let u = Settings.pluginsDir.appendingPathComponent(id).appendingPathComponent("plugin.json")
        try? JSON.compact(m).write(to: u, atomically: true, encoding: .utf8)
    }

    func describeForAgent() -> String {
        if records.isEmpty { return "no plugins installed" }
        return records.map {
            "\($0.enabled ? "on " : "off") [\($0.kind.rawValue)] \($0.id) \($0.version)" +
            ($0.broken.map { " | BROKEN: \($0)" } ?? "") + " | \($0.desc)"
        }.joined(separator: "\n")
    }
}
