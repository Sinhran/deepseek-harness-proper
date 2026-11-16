import Foundation
import AppKit
@testable import DSHCore

/// Headless regression harness for `swift test`. Exercises the JS plugin path, tools, diff, scheduler math.
enum Smoke {
    @discardableResult static func run() -> Int {
        var pass = 0, fail = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond { pass += 1; print("PASS  \(name)") }
            else { fail += 1; print("FAIL  \(name)  \(detail)") }
        }

        // Hermetic support dir: the XCTest environment probe is not set by
        // every runner, so without this the fixtures below (plugins,
        // sessions) land in the user's real Application Support dir.
        let isolation = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolation, withIntermediateDirectories: true)
        let previousOverride = Settings.supportDirOverride
        Settings.supportDirOverride = isolation
        defer {
            Settings.supportDirOverride = previousOverride
            try? FileManager.default.removeItem(at: isolation)
        }

        // 1. Write a sample JS plugin. "enabled": true is the explicit trust
        // action new bundles require before they load.
        let id = "smoke-echo"
        let dir = Settings.pluginsDir.appendingPathComponent(id)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["id": id, "name": "Echo", "kind": "js", "main": "index.js", "enabled": true]
            try JSON.compact(manifest).write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let js = """
            module.exports = function(ctx) {
              ctx.tool({name:'echo', description:'echo args', parameters:{type:'object',properties:{msg:{type:'string'}}}},
                function(args){ return 'echo:' + (args.msg || ''); });
              ctx.command('hi', 'Say hi to {args}');
              ctx.skill('polite', 'Always be polite.');
              ctx.store.set('k', 42);
              var timer = setInterval(function() {
                ctx.store.set('timer', 'fired');
                clearInterval(timer);
              }, 1);
              ctx.tool({name:'isdir', description:'directory check', parameters:{type:'object',properties:{}}},
                function(){ return fs.statSync('.').isDirectory() ? 'directory' : 'file'; });
            };
            """
            try js.write(to: dir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        } catch {
            check("plugin fixture written", false, "\(error)")
            print("\n\(pass) passed, \(fail) failed")
            return fail
        }

        let pe = PluginEngine.shared
        pe.reload()
        // JS loads on its serial queue; poll for registration (or a load
        // failure) instead of a fixed sleep so slow CI cannot flake the run.
        let loadDeadline = Date().addingTimeInterval(10)
        while Date() < loadDeadline,
              !pe.agentToolSpecs().contains(where: { $0.name == "echo" }),
              pe.records.first(where: { $0.id == id })?.broken == nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
        check("plugin discovered", pe.records.contains { $0.id == id })
        check("plugin not broken", pe.records.first { $0.id == id }?.broken == nil,
              pe.records.first { $0.id == id }?.broken ?? "")
        check("js tool registered", pe.agentToolSpecs().contains { $0.name == "echo" })
        check("command registered", pe.expandCommand("hi", args: "bob") == "Say hi to bob")
        check("skill registered", pe.skillBlocks().contains("polite"))

        // 2. Invoke the JS tool
        let sem = DispatchSemaphore(value: 0)
        var echoResult = ""
        Task {
            echoResult = (try? await pe.invokeTool(name: "echo", args: ["msg": "hello"])) ?? "(nil)"
            sem.signal()
        }
        check("js tool invoke completed", sem.wait(timeout: .now() + 10) == .success)
        check("js tool invoke", echoResult == "echo:hello", echoResult)
        let stateData = try? Data(contentsOf: dir.appendingPathComponent("state.json"))
        let pluginState = stateData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        check("plugin timer clear interval", pluginState?["timer"] == "\"fired\"")
        let statSem = DispatchSemaphore(value: 0); var statResult = ""
        Task {
            statResult = (try? await pe.invokeTool(name: "isdir", args: [:])) ?? "(nil)"
            statSem.signal()
        }
        check("plugin directory stat", statSem.wait(timeout: .now() + 10) == .success && statResult == "directory", statResult)

        // 2b. A plugin that breaks after registering must not keep its tools.
        let brokenID = "smoke-broken"
        let brokenDir = Settings.pluginsDir.appendingPathComponent(brokenID)
        do {
            try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["id": brokenID, "name": "Broken", "kind": "js", "main": "index.js", "enabled": true]
            try JSON.compact(manifest).write(to: brokenDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let js = """
            module.exports = function(ctx) {
              ctx.tool({name:'doomed', description:'doomed tool', parameters:{type:'object',properties:{}}},
                function(){ return 'never'; });
              throw new Error('boom after registration');
            };
            """
            try js.write(to: brokenDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        } catch {
            check("broken plugin fixture written", false, "\(error)")
        }
        defer { try? FileManager.default.removeItem(at: brokenDir) }
        pe.reload()
        let brokenDeadline = Date().addingTimeInterval(10)
        while Date() < brokenDeadline,
              pe.records.first(where: { $0.id == brokenID })?.broken == nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
        check("broken plugin flagged", pe.records.first { $0.id == brokenID }?.broken != nil)
        check("broken plugin tool unregistered", !pe.agentToolSpecs().contains { $0.name == "doomed" })
        let doomedSem = DispatchSemaphore(value: 0); var doomedResult: String? = "sentinel"
        Task {
            doomedResult = try? await pe.invokeTool(name: "doomed", args: [:])
            doomedSem.signal()
        }
        check("broken plugin tool not invokable",
              doomedSem.wait(timeout: .now() + 10) == .success && doomedResult == nil, "\(doomedResult ?? "nil")")

        // 3. Built-in tools
        let ctx = ToolContext(workspace: NSTemporaryDirectory())
        let wsem = DispatchSemaphore(value: 0)
        var toolOut = ""
        Task {
            let writeTool = Tools.all().first { $0.spec.name == "write" }!
            toolOut = (try? await writeTool.run(["file_path": "dsh-smoke.txt", "content": "line1\nline2\n"], ctx)) ?? "(nil)"
            wsem.signal()
        }
        check("write tool completed", wsem.wait(timeout: .now() + 10) == .success)
        check("write tool", toolOut.contains("wrote"))
        defer { try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "dsh-smoke.txt") }

        // 4. Diff engine
        let hunks = DiffEngine.diff(old: "a\nb\nc\n", new: "a\nX\nc\n")
        let (adds, dels) = DiffEngine.counts(hunks: hunks)
        check("diff hunk", adds == 1 && dels == 1, "+\(adds) -\(dels)")

        // 5. Schedule math
        let next = Schedule.daily(hour: 9, minute: 0, tz: "UTC").nextFire()
        check("schedule next-fire", next != nil && next! > Date())

        // 6. Store persistence roundtrip
        let store = SessionStore.shared
        let s = store.newSession(workspace: "/tmp")
        check("session created", store.sessions.contains { $0.id == s.id })
        store.flush()
        check("session file persisted", store.load(s.id) != nil)
        store.delete(s.id)
        store.flush()

        // 7. Model selection rule: the session's own pick wins when valid,
        // then the stored default, then the first model.
        check("session pick wins", ModelCatalog.preferredModel(models: ["a", "b"], settingsDefault: "b", sessionModel: "a") == "a")
        check("settings default seeds", ModelCatalog.preferredModel(models: ["a", "b"], settingsDefault: "b", sessionModel: "") == "b")
        check("session fallback", ModelCatalog.preferredModel(models: ["a", "b"], settingsDefault: "z", sessionModel: "a") == "a")
        check("first fallback", ModelCatalog.preferredModel(models: ["a", "b"], settingsDefault: "z", sessionModel: "z") == "a")
        check("empty list keeps session", ModelCatalog.preferredModel(models: [], settingsDefault: "z", sessionModel: "s") == "s")

        // 8. Regression checks for audited bugs.
        check("markdown link label", !String(MD.render("[docs](https://example.com)").string).contains("docs]"))
        check("markdown earliest inline", String(MD.render("*em* and **bold**").string).contains("em") && !String(MD.render("*em* and **bold**").string).contains("*em*"))
        check("markdown tab heading", MD.render("###\tHeading").string == "Heading\n")
        check("markdown formatted link label", {
            let rendered = MD.render("[**docs**](https://example.com)")
            let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let link = rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL
            return font?.fontDescriptor.symbolicTraits.contains(.bold) == true && link?.host == "example.com"
        }())
        check("markdown level five heading", MD.render("##### Heading").string == "Heading\n")
        check("decode numeric entities", WebText.decodeEntities("&#65;&#x42;") == "AB", WebText.decodeEntities("&#65;&#x42;"))
        check("decode amp once", WebText.decodeEntities("&amp;lt;") == "&lt;")
        check("diff context", {
            let old = (0...20).map { "L\($0)" }.joined(separator: "\n")
            var lines = (0...20).map { "L\($0)" }; lines[2] = "X2"; lines[15] = "X15"
            let hunks = DiffEngine.diff(old: old, new: lines.joined(separator: "\n"), context: 3)
            return hunks.count == 2 && hunks.allSatisfy { h in
                h.ops.filter { if case .equal = $0 { return true }; return false }.count <= 6 + 1
            }
        }())
        check("weekly invalid weekday", Schedule.weekly(weekday: 0, hour: 9, minute: 0, tz: "UTC").nextFire() == nil)
        check("schedule rejects bad interval", !Schedule.interval(seconds: 0).isValid && !Schedule.interval(seconds: -5).isValid)
        check("schedule rejects bad hour", !Schedule.daily(hour: 25, minute: 0, tz: "UTC").isValid)
        check("schedule rejects bad tz", !Schedule.daily(hour: 9, minute: 0, tz: "Not/AZone").isValid)
        // TaskRun.status used to be a free-form string ("ok", "running",
        // "error: ..."); old automations.json files must still decode.
        let runID = "8B1C2D3E-4F50-4617-8899-AABBCCDDEEFF"
        let sid = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        func legacyRun(_ status: String) -> TaskRun? {
            let json = #"{"id":"\#(runID)","date":"2026-01-01T00:00:00Z","sessionID":"\#(sid)","status":"\#(status)"}"#
            return try? dec.decode(TaskRun.self, from: Data(json.utf8))
        }
        check("legacy error run decodes", legacyRun("error: interrupted")?.status == .error,
              "\(String(describing: legacyRun("error: interrupted")?.status))")
        check("legacy ok run decodes", legacyRun("ok")?.status == .ok)
        check("legacy running run decodes", legacyRun("running")?.status == .running)
        check("workspace confinement", (try? ToolContext(workspace: "/tmp/ws").resolveChecked("/etc/passwd")) == nil)
        let regressionRoot = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-audit-\(UUID().uuidString)", isDirectory: true)
        let outsideRoot = regressionRoot.deletingLastPathComponent().appendingPathComponent("dsh-outside-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: regressionRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: regressionRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let regressionContext = ToolContext(workspace: regressionRoot.path)
        try? Data("needle".utf8).write(to: regressionRoot.appendingPathComponent("AgentLoop.swift"))
        let nested = regressionRoot.appendingPathComponent("Sources/dsh", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? Data("needle".utf8).write(to: nested.appendingPathComponent("Tools.swift"))
        let grepFileSemaphore = DispatchSemaphore(value: 0); var grepFileOutput = ""
        Task {
            let tool = Tools.all().first { $0.spec.name == "grep" }!
            grepFileOutput = (try? await tool.run(["pattern": "needle", "path": regressionRoot.appendingPathComponent("AgentLoop.swift").path], regressionContext)) ?? ""
            grepFileSemaphore.signal()
        }
        check("grep file path", grepFileSemaphore.wait(timeout: .now() + 10) == .success && grepFileOutput.contains("AgentLoop.swift:1"))
        let globSemaphore = DispatchSemaphore(value: 0); var globOutput = ""
        Task {
            let tool = Tools.all().first { $0.spec.name == "glob" }!
            globOutput = (try? await tool.run(["pattern": "**/*.swift", "path": regressionRoot.path], regressionContext)) ?? ""
            globSemaphore.signal()
        }
        check("glob recursive root files", globSemaphore.wait(timeout: .now() + 10) == .success
              && globOutput.contains("AgentLoop.swift") && globOutput.contains("Sources/dsh/Tools.swift"))
        let outsideFile = outsideRoot.appendingPathComponent("private.txt")
        try? Data("secretneedle".utf8).write(to: outsideFile)
        try? FileManager.default.createSymbolicLink(at: regressionRoot.appendingPathComponent("escape"), withDestinationURL: outsideRoot)
        check("workspace rejects symlink suffix", (try? regressionContext.resolveChecked("escape/newdir/file")) == nil)
        check("plugin rejects symlink suffix", PluginEngine.confined(regressionRoot, "escape/newdir/file") == nil)
        check("new file line count", DiffEngine.lineCount("single") == 1
              && DiffEngine.counts(hunks: DiffEngine.diff(old: "", new: "single")).0 == 1)
        check("web blocks translated private addresses",
              Tools.isBlockedAddress("64:ff9b::7f00:1") && Tools.isBlockedAddress("2002:7f00:1::"))
        check("web blocks IPv4-compatible loopback", Tools.isBlockedAddress("::7f00:1"))
        check("web blocks local NAT64", Tools.isBlockedAddress("64:ff9b:1::7f00:1"))
        check("web blocks reserved IPv6", Tools.isBlockedAddress("100::1") && Tools.isBlockedAddress("3fff::1"))
        var lineReader = SSELineReader()
        var sseLines: [String] = []
        for byte in Data("data: {\"text\":\"a\u{2028}b\"}\r\ndata: [DONE]\n".utf8) {
            if let line = lineReader.append(byte) { sseLines.append(line) }
        }
        if let line = lineReader.finish() { sseLines.append(line) }
        let ssePayload = sseLines.first.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""
        let sseObject = (try? JSONSerialization.jsonObject(with: Data(ssePayload.utf8))) as? [String: String]
        check("SSE preserves Unicode line separators", sseLines.count == 2 && sseObject?["text"] == "a\u{2028}b")
        let sharedStrings = XLSXText.sharedStrings(Data(#"<sst><si><t>Alpha &amp; Beta</t></si><si><r><t>Two</t></r><r><t> words</t></r></si></sst>"#.utf8))
        let worksheet = Data(#"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>inline</t></is></c><c r="C1"><v>42</v></c></row></sheetData></worksheet>"#.utf8)
        check("xlsx shared strings resolve", XLSXText.worksheet(worksheet, sharedStrings: sharedStrings) == "Alpha & Beta\tinline\t42")

        // Shell must drain pipes concurrently: >64KB before exit used to deadlock until timeout.
        let shellSem = DispatchSemaphore(value: 0); var shellOut = ""
        Task { shellOut = (try? await Shell.run("yes | head -c 200000", cwd: "/tmp", timeout: 10)) ?? ""; shellSem.signal() }
        check("shell large output completed", shellSem.wait(timeout: .now() + 15) == .success)
        check("shell large output no deadlock", shellOut.count > 100_000, "\(shellOut.count)")
        let capSem = DispatchSemaphore(value: 0); var outputWasCapped = false
        Task {
            let result = try? await Shell.captureAsync(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "while true; do printf x; done"],
                timeout: 5, maxOutputBytes: 4096)
            outputWasCapped = result?.outputLimited == true
            capSem.signal()
        }
        check("shell output limit stops process", capSem.wait(timeout: .now() + 10) == .success && outputWasCapped)
        let childMarker = regressionRoot.appendingPathComponent("late-child-\(UUID().uuidString)")
        let quotedMarker = "'" + childMarker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let childCommand = "sleep 1; /usr/bin/touch \(quotedMarker)"
        var childTimedOut = false
        let childSem = DispatchSemaphore(value: 0)
        Task {
            let result = try? await Shell.captureAsync(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", childCommand], timeout: 0.15)
            childTimedOut = result?.timedOut == true
            childSem.signal()
        }
        let childFinished = childSem.wait(timeout: .now() + 10) == .success
        // killTree's SIGKILL grace is 2s; a slow SIGTERM-tolerant child may
        // legally write the marker up to then. Poll past the grace window
        // instead of a fixed sleep that races it.
        let markerDeadline = Date().addingTimeInterval(3.5)
        var childEscaped = false
        while Date() < markerDeadline {
            if FileManager.default.fileExists(atPath: childMarker.path) { childEscaped = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        check("shell timeout stops descendant",
              childFinished && childTimedOut && !childEscaped)
        // Negative read limit used to trap on an invalid Range.
        let readSem = DispatchSemaphore(value: 0); var readOut = ""
        Task {
            let readTool = Tools.all().first { $0.spec.name == "read" }!
            readOut = (try? await readTool.run(["file_path": "dsh-smoke.txt", "limit": -5], ctx)) ?? "(error)"
            readSem.signal()
        }
        check("read negative limit completed", readSem.wait(timeout: .now() + 10) == .success)
        check("read negative limit no crash", !readOut.isEmpty)
        check("plugin path confinement", PluginEngine.confined(Settings.pluginsDir.appendingPathComponent("x"), "/etc/passwd") == nil
              && PluginEngine.confined(Settings.pluginsDir.appendingPathComponent("x"), "index.js") != nil
              && PluginEngine.confined(Settings.pluginsDir.appendingPathComponent("x"), "../../sessions") == nil)
        check("uninstall traversal rejected", (try? pe.uninstall("../../sessions")) == nil)
        // 9. Upstream agent profiles, built in as is.
        let profiles = AgentProfiles.all
        check("profiles built in", profiles.map { $0.id } == ["standard", "ptc", "minimal", "cordis"],
              profiles.map { $0.id }.joined(separator: ","))
        check("profile order", profiles.map { $0.order } == [1, 2, 3, 4])
        let std = AgentProfiles.profile(id: "standard")
        check("standard persona", std.personaPrefix == "You are a coding agent powered by the {{model}} model.")
        check("standard tools", std.nativeTools == ["bash", "read", "write", "edit", "grep", "glob", "web_fetch",
              "web_search", "schedule_create", "schedule_list", "schedule_delete", "subagent", "plugin_manager"],
              "\(std.nativeTools.sorted().joined(separator: ",")) web=\(String(describing: std.plugins.first { $0.id == "tool-web" }))")
        check("standard plan section retained", std.rawYAML.contains("exit_plan_mode"))
        let fetchDisabled = AgentProfiles.parse(yaml: std.rawYAML.replacingOccurrences(of: "fetch: true", with: "fetch: false"))
        check("profile fetch flag keeps search", fetchDisabled?.nativeTools.contains("web_fetch") == false
              && fetchDisabled?.nativeTools.contains("web_search") == true)
        let min = AgentProfiles.profile(id: "minimal")
        check("minimal complete persona", min.personaComplete && min.personaPrefix == "You are a helpful software engineer assistant.")
        check("minimal shell only", min.nativeTools == ["bash"], min.nativeTools.sorted().joined(separator: ","))
        let ptc = AgentProfiles.profile(id: "ptc")
        check("ptc executor noted", ptc.unsupportedTools.contains("tool-executor-ptc"), ptc.unsupportedTools.joined(separator: ","))
        check("ptc no plugin manager", !ptc.nativeTools.contains("plugin_manager"))
        let cordis = AgentProfiles.profile(id: "cordis")
        check("cordis tool noted", cordis.unsupportedTools.contains("tool-cordis"), cordis.unsupportedTools.joined(separator: ","))
        check("raw yaml intact", std.rawYAML.contains("@deepseek-ai/dsh-agent-preset") && std.rawYAML.contains("preset-standard"))
        // 10. Brand accent stays blue: the CTA regressed to amber once.
        func resolved(_ color: NSColor, dark: Bool) -> NSColor? {
            var out: NSColor?
            NSAppearance(named: dark ? .darkAqua : .aqua)?
                .performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
            return out
        }
        func blueDominant(_ color: NSColor, dark: Bool) -> Bool {
            guard let rgb = resolved(color, dark: dark) else { return false }
            return rgb.blueComponent > rgb.redComponent && rgb.blueComponent > rgb.greenComponent
        }
        for dark in [false, true] {
            check("cta blue fill", blueDominant(T.ctaFill, dark: dark))
            check("cta blue hover", blueDominant(T.ctaHover, dark: dark))
            check("accent blue", blueDominant(T.accent, dark: dark))
            check("info blue", blueDominant(T.infoFill, dark: dark))
        }

        print("\n\(pass) passed, \(fail) failed")
        return fail
    }
}
