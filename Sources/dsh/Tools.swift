import Foundation
import Darwin

enum ToolCategory { case read, write, shell, meta }

struct ToolContext {
    var workspace: String
    var depth: Int = 0
    var recordChange: (FileChange) -> Void = { _ in }
    var scheduler: Scheduler?
    var plugins: PluginEngine?
    var makeSubloop: (() -> AgentLoop)? = nil
    /// Confinement for shell commands. The loop sets `.fullAccess` only for
    /// a call the user approved to run outside the sandbox.
    var sandbox: SandboxMode = Settings.shared.sandboxMode

    func resolveChecked(_ path: String) throws -> String {
        try Self.resolveChecked(path, within: workspace)
    }
    static func resolveChecked(_ path: String, within root: String) throws -> String {
        let expanded = path.expandingTilde
        // `..` is allowed as long as the standardized result stays inside the
        // workspace: the prefix check below is what actually confines the
        // path, and the returned (collapsed) path is the one every tool opens,
        // so textual collapsing cannot disagree with the filesystem.
        let ws = try resolveExistingPrefix(URL(fileURLWithPath: root))
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : ws.appendingPathComponent(expanded)
        let resolved = try resolveExistingPrefix(candidate)
        let w = ws.path, r = resolved.path
        guard r == w || r.hasPrefix(w + "/") else {
            throw ToolError.failed("path escapes the workspace: \(path)")
        }
        return r
    }
    private static func resolveExistingPrefix(_ url: URL, depth: Int = 0) throws -> URL {
        guard depth < 40 else { throw ToolError.failed("too many symbolic links") }
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path)
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil {
            guard ancestor.path != "/" else { break }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        let resolved: URL
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path) {
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : ancestor.deletingLastPathComponent().appendingPathComponent(destination)
            resolved = try resolveExistingPrefix(target, depth: depth + 1)
        } else {
            resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        }
        return suffix.reduce(resolved) { $0.appendingPathComponent($1) }.standardizedFileURL
    }
    /// Unconfined resolution for explicitly gated meta operations (plugin install
    /// from a user/agent-approved source path). Never use for read/write tools.
    func resolveExternal(_ path: String) -> String {
        let p = path.expandingTilde
        if p.hasPrefix("/") { return (p as NSString).standardizingPath }
        return ((workspace as NSString).appendingPathComponent(p) as NSString).standardizingPath
    }
}

struct Tool {
    var spec: ToolSpec
    var category: ToolCategory
    var run: ([String: Any], ToolContext) async throws -> String
}

enum ToolError: LocalizedError {
    case missing(String), denied, failed(String)
    var errorDescription: String? {
        switch self {
        case .missing(let p): return "missing required parameter: \(p)"
        case .denied: return "denied by user"
        case .failed(let m): return m
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue ?? self[k] as? Int }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? self[k] as? Bool ?? false }
}

enum Tools {

    static func all() -> [Tool] { [bash, read, write, edit, grep, glob, webFetch, webSearch,
                                   scheduleCreate, scheduleList, scheduleDelete, subagent, pluginManager] }

    static func category(_ c: ToolCategory, needsApproval autonomy: Autonomy) -> Bool {
        switch (autonomy, c) {
        case (.full, _): return false
        case (.autoWrite, .shell), (.autoWrite, .meta): return true
        case (.autoWrite, _): return false
        case (.autoRead, .read): return false
        case (.autoRead, _): return true
        case (.ask, _): return true
        }
    }

    private static func enumeratedPaths(root: String, context: ToolContext, skipDirs: Set<String>,
                                        limit: Int, deadline: Date) -> ([(relative: String, full: String)], Bool) {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return ([], false) }
        var paths: [(relative: String, full: String)] = []
        var visited = 0
        for case let relative as String in enumerator {
            visited += 1
            if visited > limit || Date() > deadline { return (paths, true) }
            if skipDirs.contains((relative as NSString).lastPathComponent)
                || relative.split(separator: "/").contains(where: { skipDirs.contains(String($0)) }) {
                // Skip the whole subtree too: enumerating .git or
                // node_modules anyway would burn the visited-path budget
                // on entries that are thrown away unseen.
                enumerator.skipDescendants()
                continue
            }
            let full = (root as NSString).appendingPathComponent(relative)
            guard (try? context.resolveChecked(full)) != nil else { continue }
            paths.append((relative, full))
        }
        return (paths, false)
    }

    // MARK: bash

    static let bash = Tool(
        spec: ToolSpec(name: "bash", description: "Run a shell command in the workspace. Returns stdout+stderr. Commands run in an OS sandbox: by default they can change files only in the workspace and temporary folders, and can't read credentials (~/.ssh, ~/.aws, Keychains, browser data).", parameters: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "The command to run"],
                "description": ["type": "string", "description": "One-line description of what this does"],
                "timeout": ["type": "integer", "description": "Seconds before the command is killed (default 120)"],
                "unsandboxed": ["type": "boolean", "description": "Run this one command outside the sandbox. Always asks the user, even at full autonomy. Use only when the sandbox blocked something the task truly needs (e.g. git push over SSH, installing into ~/), and say why in description."],
            ],
            "required": ["command"],
        ]),
        category: .shell
    ) { args, ctx in
        guard let cmd = args.str("command") else { throw ToolError.missing("command") }
        let timeout = TimeInterval(min(max(args.int("timeout") ?? 120, 1), 600))
        return try await Shell.run(cmd, cwd: ctx.workspace, timeout: timeout,
                                   sandbox: .current(workspace: ctx.workspace, mode: ctx.sandbox))
    }

    // MARK: read

    static let read = Tool(
        spec: ToolSpec(name: "read", description: "Read a file with line numbers. Use offset/limit for large files.", parameters: [
            "type": "object",
            "properties": [
                "file_path": ["type": "string"],
                "offset": ["type": "integer", "description": "1-based line to start at"],
                "limit": ["type": "integer", "description": "Max lines (default 400)"],
            ],
            "required": ["file_path"],
        ]),
        category: .read
    ) { args, ctx in
        guard let p = args.str("file_path") else { throw ToolError.missing("file_path") }
        let path = try ctx.resolveChecked(p)
        let offset = max(1, args.int("offset") ?? 1)
        let limit = min(max(args.int("limit") ?? 400, 0), 2000)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        else { throw ToolError.failed("cannot read \(p)") }
        if size > 4_000_000 {
            // Too big to hold in memory: stream lines up to the requested
            // window instead of rejecting before offset/limit can help.
            return try Self.readWindow(path: path, offset: offset, limit: limit, size: size)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ToolError.failed("cannot read \(p)")
        }
        // NUL bytes in the head mean binary; latin-1 would decode anything
        // and make this check unreachable.
        if data.prefix(8192).contains(0) { throw ToolError.failed("binary file; not text-decodable") }
        var text: String
        if let t = String(data: data, encoding: .utf8) { text = t }
        else if let t = String(data: data, encoding: .isoLatin1) { text = t }
        else { throw ToolError.failed("binary file; not text-decodable") }
        // A trailing newline terminates the last line; it does not start an
        // empty one. Without this the tool reports a phantom line N+1 and
        // every offset/limit window past it is off by one.
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        guard offset <= lines.count else { return "(file has \(lines.count) lines; offset \(offset) is past end)" }
        let slice = lines[(offset - 1)..<min(offset - 1 + limit, lines.count)]
        var out = ""
        for (i, l) in slice.enumerated() { out += "\(offset + i)\t\(l)\n" }
        if offset - 1 + limit < lines.count { out += "(\(lines.count - offset + 1 - limit) more lines)" }
        return out
    }

    /// Line-window read for files too large to load whole. Scans at most
    /// `scanCap` bytes; reports truncation honestly when it stops early.
    private static func readWindow(path: String, offset: Int, limit: Int, size: Int) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ToolError.failed("cannot read \(path)")
        }
        defer { try? handle.close() }
        var pending = handle.readData(ofLength: 8192)
        if pending.contains(0) { throw ToolError.failed("binary file; not text-decodable") }
        var lineNo = 0, emitted = 0, scanned = pending.count
        var out = ""
        let scanCap = 67_108_864
        var hitCap = false
        func takeLine(_ d: Data) {
            lineNo += 1
            guard lineNo >= offset, emitted < limit else { return }
            out += "\(lineNo)\t\(Self.decodeLine(d))\n"
            emitted += 1
        }
        while scanned < scanCap {
            // Consume complete lines by advancing a cursor over `pending` and
            // dropping the consumed prefix once per chunk. Slicing off the
            // remainder per line instead (pending.subdata(in: nl+1..<count))
            // copies the whole buffer once per line — quadratic, and a 60MB
            // file of short lines took over 30s to scan.
            var cursor = pending.startIndex
            while let nl = pending[cursor...].firstIndex(of: 0x0A) {
                takeLine(pending[cursor..<nl])
                cursor = pending.index(after: nl)
                if out.count > 200_000 { break }
            }
            if cursor > pending.startIndex { pending = pending.subdata(in: cursor..<pending.endIndex) }
            if out.count > 200_000 || scanned >= size { break }
            let chunk = handle.readData(ofLength: 262_144)
            if chunk.isEmpty { break }
            scanned += chunk.count
            pending.append(chunk)
        }
        if scanned < size && scanned >= scanCap { hitCap = true }
        // Flush a final unterminated line. `pending` is empty when the file
        // ends in a newline (the last line was already consumed), so this
        // never invents a phantom trailing line.
        if !pending.isEmpty, out.count <= 200_000 { takeLine(pending) }
        if out.count > 200_000 { out = String(out.prefix(200_000)) + "\n(output truncated)" }
        if offset > lineNo { return "(file has \(lineNo)+ lines; offset \(offset) is past end\(hitCap ? " within first \(scanCap) bytes" : ""))" }
        var tail = ""
        if lineNo - offset + 1 > emitted { tail = "(\(lineNo - offset + 1 - emitted) more lines)\n" }
        if hitCap { tail += "(scanned first \(scanCap) of \(size) bytes)\n" }
        return out.isEmpty && tail.isEmpty ? "(empty file)" : out + tail
    }

    /// Per-line decoding for the streaming reader, mirroring the in-memory
    /// path: strict UTF-8 first, then Latin-1 (which maps every byte, so it
    /// never fails), then lossy UTF-8 as a last resort. Lines are safe to
    /// decode independently because 0x0A can never appear inside a
    /// multi-byte UTF-8 sequence.
    private static func decodeLine(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .isoLatin1) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: write

    static let write = Tool(
        spec: ToolSpec(name: "write", description: "Create or overwrite a file. Prefer edit for existing files.", parameters: [
            "type": "object",
            "properties": ["file_path": ["type": "string"], "content": ["type": "string"]],
            "required": ["file_path", "content"],
        ]),
        category: .write
    ) { args, ctx in
        guard let p = args.str("file_path"), let content = args.str("content")
        else { throw ToolError.missing("file_path/content") }
        let path = try ctx.resolveChecked(p)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw ToolError.failed("\(p) resolves to a directory, not a file")
        }
        let existed = FileManager.default.fileExists(atPath: path)
        let beforeData = FileManager.default.contents(atPath: path) ?? Data()
        // Non-UTF-8 files cannot round-trip as text; keep the review diff
        // honest with a byte-count marker instead of an empty string.
        let before: String
        var restorable = true
        if let text = String(data: beforeData, encoding: .utf8) { before = text }
        else if beforeData.isEmpty { before = "" }
        else { before = "(non-UTF-8 content, \(beforeData.count) bytes)"; restorable = false }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let added = DiffEngine.lineCount(content)
        ctx.recordChange(FileChange(path: path, before: before, after: content, turn: ctx.depth,
                                    created: !existed, restorable: restorable))
        return "wrote \(path) (+\(added) lines)"
    }

    // MARK: edit

    static let edit = Tool(
        spec: ToolSpec(name: "edit", description: "Replace an exact string in a file. old_string must match exactly once unless replace_all.", parameters: [
            "type": "object",
            "properties": [
                "file_path": ["type": "string"],
                "old_string": ["type": "string"],
                "new_string": ["type": "string"],
                "replace_all": ["type": "boolean"],
            ],
            "required": ["file_path", "old_string", "new_string"],
        ]),
        category: .write
    ) { args, ctx in
        guard let p = args.str("file_path"), let old = args.str("old_string"), let new = args.str("new_string")
        else { throw ToolError.missing("file_path/old_string/new_string") }
        // An empty needle matches between every character: with replace_all
        // the replacement would be injected through the whole file.
        guard !old.isEmpty else { throw ToolError.failed("old_string cannot be empty") }
        let path = try ctx.resolveChecked(p)
        guard let data = FileManager.default.contents(atPath: path),
              var text = String(data: data, encoding: .utf8) else { throw ToolError.failed("cannot read \(p)") }
        let occurrences = text.components(separatedBy: old).count - 1
        if occurrences == 0 { throw ToolError.failed("old_string not found in \(p)") }
        if occurrences > 1 && !args.bool("replace_all") {
            throw ToolError.failed("old_string matches \(occurrences) times; make it unique or set replace_all")
        }
        text = text.replacingOccurrences(of: old, with: new)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        // edit only runs on UTF-8 text it decoded above, so `before` is exact.
        ctx.recordChange(FileChange(path: path, before: String(data: data, encoding: .utf8) ?? "",
                                    after: text, turn: ctx.depth, created: false, restorable: true))
        return "edited \(path) (\(occurrences) replacement\(occurrences > 1 ? "s" : ""))"
    }

    // MARK: grep

    static let grep = Tool(
        spec: ToolSpec(name: "grep", description: "Search file contents with a POSIX extended regex (grep -E). Faster than reading whole trees.", parameters: [
            "type": "object",
            "properties": [
                "pattern": ["type": "string"],
                "path": ["type": "string", "description": "Directory or file (default workspace)"],
                "glob": ["type": "string", "description": "Filename filter like *.swift"],
                "case_insensitive": ["type": "boolean"],
            ],
            "required": ["pattern"],
        ]),
        category: .read
    ) { args, ctx in
        guard let pat = args.str("pattern") else { throw ToolError.missing("pattern") }
        let root = try ctx.resolveChecked(args.str("path") ?? ".")
        let fileRx = args.str("glob").map { Wildcard.regex($0) }
        let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".dsh-proper"]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { return "no matches" }
        let deadline = Date().addingTimeInterval(20)
        var paths: [(relative: String, full: String)]
        var exhausted = false
        if isDirectory.boolValue {
            let result = Self.enumeratedPaths(root: root, context: ctx, skipDirs: skipDirs, limit: 20_000, deadline: deadline)
            paths = result.0; exhausted = result.1
        } else {
            paths = [(URL(fileURLWithPath: root).lastPathComponent, root)]
        }
        // Matching runs in /usr/bin/grep rather than NSRegularExpression: its
        // matcher is DFA-based, so a catastrophic pattern like (a+)+$ cannot
        // wedge the turn, and captureAsync enforces a hard timeout anyway.
        // Files are pre-filtered here (confinement, glob) and passed as
        // relative paths so output stays short. There is no size cut: grep
        // streams, so a large file costs time, not memory, and dropping it
        // silently would report "no matches" for a file that does match.
        var files: [String] = []
        for (relative, full) in paths {
            if Date() > deadline { exhausted = true; break }
            guard (try? ctx.resolveChecked(full)) != nil else { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let name = (relative as NSString).lastPathComponent
            if let fileRx, fileRx.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) == nil { continue }
            files.append(relative)
        }
        if files.isEmpty { return "no matches" }
        let known = Set(files)
        let baseArgs = ["-E", "-n", "-H", "-I", "--binary-files=without-match"]
            + (args.bool("case_insensitive") ? ["-i"] : [])
        // Relative paths are resolved against this directory; when `path` is a
        // single file, `root` is that file and cannot be a working directory.
        let cwd = isDirectory.boolValue ? root : (root as NSString).deletingLastPathComponent
        var matches: [String] = []
        var limited = false
        // Batch by argv size: 20k paths would exceed ARG_MAX in one call.
        var batch: [String] = []
        var batchBytes = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let remaining = max(1, deadline.timeIntervalSinceNow)
            let result = try await Shell.captureAsync(
                executable: URL(fileURLWithPath: "/usr/bin/grep"),
                arguments: baseArgs + ["-e", pat, "--"] + batch,
                cwd: cwd, timeout: remaining, maxOutputBytes: 4_000_000)
            batch = []; batchBytes = 0
            if result.timedOut { throw ToolError.failed("grep exceeded 20s") }
            // Exit 1 means no match; 2 means the pattern (or a file) was bad.
            if result.status == 2 {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ToolError.failed(detail.isEmpty ? "invalid pattern" : detail)
            }
            for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                // Output is "<path>:<line>:<text>". A path may itself contain
                // colons, so pick the first split whose prefix is a file we
                // passed and whose remainder starts with a line number.
                guard let (path, lineNo, text) = Self.splitGrepLine(line, known: known) else { continue }
                matches.append("\(path):\(lineNo): \(text.prefix(300))")
                if matches.count >= 200 { limited = true; return }
            }
            if result.outputLimited { limited = true }
        }
        for f in files {
            if Date() > deadline { exhausted = true; break }
            if matches.count >= 200 { limited = true; break }
            batch.append(f); batchBytes += f.utf8.count + 1
            if batchBytes > 180_000 { try await flush() }
        }
        // Always run the pending batch — including when the deadline cut the
        // loop short, or the matches from files already queued would be lost.
        // It is under the argv budget, so this is one bounded grep call.
        if matches.count < 200 { try await flush() }
        let note = limited ? "\n(truncated at 200 matches)"
            : exhausted ? "\n(search budget exhausted; narrow the path or pattern)" : ""
        return matches.isEmpty ? "no matches" : matches.joined(separator: "\n") + note
    }

    /// Split a `grep -n -H` output line into (path, line number, text),
    /// disambiguating paths that contain colons against the exact set of
    /// paths that were searched.
    private static func splitGrepLine(_ line: Substring, known: Set<String>) -> (String, String, String)? {
        var idx = line.startIndex
        while idx < line.endIndex {
            guard line[idx] == ":" else { idx = line.index(after: idx); continue }
            let candidate = String(line[line.startIndex..<idx])
            if known.contains(candidate) {
                var j = line.index(after: idx)
                let digitsStart = j
                while j < line.endIndex, line[j].isNumber { j = line.index(after: j) }
                if j > digitsStart, j < line.endIndex, line[j] == ":" {
                    return (candidate, String(line[digitsStart..<j]), String(line[line.index(after: j)...]))
                }
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    // MARK: glob

    static let glob = Tool(
        spec: ToolSpec(name: "glob", description: "Find files by wildcard pattern, e.g. **/*.swift", parameters: [
            "type": "object",
            "properties": [
                "pattern": ["type": "string"],
                "path": ["type": "string", "description": "Root directory (default workspace)"],
            ],
            "required": ["pattern"],
        ]),
        category: .read
    ) { args, ctx in
        guard let pat = args.str("pattern") else { throw ToolError.missing("pattern") }
        let root = try ctx.resolveChecked(args.str("path") ?? ".")
        let rx = Wildcard.regex(pat)
        var found: [String] = []
        let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".dsh-proper"]
        let paths = Self.enumeratedPaths(root: root, context: ctx, skipDirs: skipDirs,
                                         limit: 20_000, deadline: Date().addingTimeInterval(20)).0
        for (relative, _) in paths {
            if rx.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) != nil {
                found.append(relative)
                if found.count >= 500 { break }
            }
        }
        return found.isEmpty ? "no files match" : found.sorted().joined(separator: "\n")
    }

    // MARK: web

    static let webFetch = Tool(
        spec: ToolSpec(name: "web_fetch", description: "Fetch a URL and return its text content.", parameters: [
            "type": "object",
            "properties": ["url": ["type": "string"], "raw": ["type": "boolean", "description": "Return raw HTML"]],
            "required": ["url"],
        ]),
        category: .read
    ) { args, _ in
        guard let u = args.str("url"), let url = URL(string: u) else { throw ToolError.missing("url") }
        let response = try await Self.fetchPinned(url, cap: 2_000_000)
        guard (200..<300).contains(response.status) else {
            throw ToolError.failed("HTTP \(response.status) from \(response.url.absoluteString)")
        }
        var text = response.body
        let isHTML = (response.headers["content-type"] ?? "").contains("html")
        if isHTML && !args.bool("raw") { text = WebText.htmlToText(text) }
        if text.count > 50_000 { text = String(text.prefix(50_000)) + "\n(truncated)" }
        return text.isEmpty ? "(empty response)" : text
    }

    struct WebResponse {
        var status: Int
        var url: URL
        var headers: [String: String]
        var body: String
    }

    /// First blank-line terminator in either CRLF or bare-LF form. The two
    /// separators never overlap, so the earlier match wins.
    private static func headerSeparator(in s: Substring) -> Range<String.Index>? {
        let crlf = s.range(of: "\r\n\r\n")
        let lf = s.range(of: "\n\n")
        switch (crlf, lf) {
        case let (a?, b?): return a.lowerBound < b.lowerBound ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// True when `s` opens with an HTTP status line ("HTTP/x.y NNN ..."),
    /// distinguishing an interim response block from body bytes that happen
    /// to start with "HTTP/".
    private static func looksLikeStatusLine(_ s: Substring) -> Bool {
        guard s.hasPrefix("HTTP/") else { return false }
        let line = s.prefix { $0 != "\r" && $0 != "\n" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0].count > 5,
              parts[1].count == 3, parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }
        return true
    }

    /// True when `block` (a status line plus header lines, no terminator) is
    /// an interim 1xx response. curl emits 100 Continue / 103 Early Hints as
    /// their own whole messages before the final response, and only 1xx codes
    /// are ever interim. Keying on the code — rather than on the next block
    /// looking like a status line — means a body that merely begins with text
    /// like "HTTP/1.1 200 OK" (a raw HTTP capture, a log) is never swallowed.
    private static func isInterimBlock(_ block: Substring) -> Bool {
        let lines = block.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        guard let statusLine = lines.first, looksLikeStatusLine(statusLine),
              let code = statusLine.split(separator: " ").dropFirst().first,
              code.count == 3, (100..<200).contains(Int(code) ?? 0) else { return false }
        // Any header lines must be well-formed; zero headers is valid (a bare
        // "HTTP/1.1 100 Continue" block).
        return lines.dropFirst().allSatisfy { $0.contains(":") }
    }

    /// The only way the app's tools reach the network: every hop (including
    /// redirects) is resolved, checked against non-public ranges, and pinned.
    static func fetchPinned(_ initial: URL, cap: Int) async throws -> WebResponse {
        var url = initial
        var visited = Set<String>()
        for _ in 0...5 {
            guard visited.insert(url.absoluteString).inserted else { throw ToolError.failed("redirect loop") }
            let (host, addresses) = try await publicAddresses(for: url)
            guard !addresses.isEmpty else { throw ToolError.failed("cannot resolve host \(host)") }
            let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
            // Pin EVERY validated address, not just the first: on a dual-stack
            // host where the first address is unreachable, curl can then fall
            // through to the next instead of failing outright. All entries are
            // already vetted as public by publicAddresses().
            let resolves = addresses.flatMap { address -> [String] in
                let pinned = address.contains(":") ? "[\(address)]" : address
                return ["--resolve", "\(host):\(port):\(pinned)"]
            }
            let args = [
                "--disable", "--silent", "--show-error", "--http1.1", "--noproxy", "*",
                // --globoff: curl otherwise expands [a-z]/{a,b} in the URL
                // (query strings included) into one request per expansion and
                // concatenates the bodies; bracketed query params like
                // ?filter[status]=x fail outright with "bad range in URL".
                "--globoff",
                "--connect-timeout", "10", "--max-time", "30", "--max-filesize", "\(cap)",
                "--user-agent", "Mozilla/5.0 (Macintosh) dsh-proper/0.2",
            ] + resolves + [
                "--dump-header", "-", "--output", "-", url.absoluteString,
            ]
            let result = try await Shell.captureAsync(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                                                       arguments: args, timeout: 32,
                                                       maxOutputBytes: cap + 64_000)
            guard !result.timedOut else { throw ToolError.failed("web request exceeded 30s") }
            guard result.status == 0 || result.outputLimited else {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                throw ToolError.failed("web request failed: \(detail.prefix(500))")
            }
            // --dump-header - prepends EVERY response's headers to the body
            // on stdout: 100 Continue and 103 Early Hints arrive as their own
            // blocks before the final response. Walk the blocks — each ends
            // at a blank line — and skip one only when its own status line is
            // 1xx. The first non-1xx block is the final response: everything
            // after its terminator is the body, even if it starts with text
            // that looks like another HTTP message.
            var cursor = result.stdout.startIndex
            var headerText = ""
            var body = ""
            var foundSplit = false
            while let sep = Self.headerSeparator(in: result.stdout[cursor...]) {
                let block = result.stdout[cursor..<sep.lowerBound]
                if Self.isInterimBlock(block) {
                    cursor = sep.upperBound
                    continue
                }
                headerText = String(block)
                body = String(result.stdout[sep.upperBound...])
                foundSplit = true
                break
            }
            guard foundSplit else {
                throw ToolError.failed("web response has no HTTP headers")
            }
            guard headerText.utf8.count <= 64_000 else { throw ToolError.failed("web response headers exceed 64KB") }
            // Normalize CRLF (and tolerate bare-LF header blocks) before
            // splitting; a stray CR would otherwise survive into values.
            let lines = headerText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
            guard let statusLine = lines.first,
                  let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                throw ToolError.failed("web response has an invalid status line")
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[name] = value
            }
            if (300..<400).contains(status), let location = headers["location"],
               let next = URL(string: location, relativeTo: url)?.absoluteURL {
                url = next
                continue
            }
            let data = Data(body.utf8)
            return WebResponse(status: status, url: url, headers: headers,
                               body: String(decoding: data.prefix(cap), as: UTF8.self))
        }
        throw ToolError.failed("too many redirects")
    }

    /// http(s) only; rejects credentials, local/internal hostnames, IP
    /// literals in any notation, and hosts that RESOLVE to private,
    /// loopback, link-local, or otherwise non-public addresses.
    private static func publicAddresses(for url: URL) async throws -> (String, [String]) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil
        else { throw ToolError.failed("only http/https URLs without credentials are allowed") }
        let connectionHost = host
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            throw ToolError.failed("local/internal hosts are not allowed")
        }
        if host.contains(":") { throw ToolError.failed("IPv6 literal hosts are not allowed") }
        // `--resolve` must byte-match the host curl parses out of the URL.
        // Plain ASCII DNS names (including punycode) always match; an IDN
        // or percent-encoded host may not, and a silent mismatch would
        // fall back to live DNS and reopen the rebinding window.
        guard !host.contains(".."), host.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
        }) else { throw ToolError.failed("invalid host \(host)") }
        // DNS resolution catches every literal notation getaddrinfo accepts
        // (127.1, 0x7f000001, 0177.0.0.1, decimal) plus real DNS names that
        // resolve to non-public space.
        let addrs = await resolvedAddresses(host)
        guard !addrs.isEmpty else { throw ToolError.failed("cannot resolve host \(host)") }
        for a in addrs where isBlockedAddress(a) {
            throw ToolError.failed("host \(host) resolves to a non-public address (\(a))")
        }
        return (connectionHost, addrs)
    }

    private static let dnsQueue = DispatchQueue(label: "dsh.web.dns", qos: .userInitiated)

    /// Numeric addresses for a host via getaddrinfo (canonical form).
    /// getaddrinfo is synchronous and can block for the resolver's full retry
    /// cycle, so it never runs on the Swift cooperative pool.
    private static func resolvedAddresses(_ host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            dnsQueue.async { continuation.resume(returning: resolveHost(host)) }
        }
    }

    private static func resolveHost(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf,
                           socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    /// True for loopback, private, link-local, CGNAT, benchmark, multicast,
    /// reserved, and unspecified addresses in either family.
    static func isBlockedAddress(_ rawAddress: String) -> Bool {
        let addr = rawAddress.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawAddress
        var v4 = in_addr()
        if addr.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return isBlockedIPv4(b)
        }
        var v6 = in6_addr()
        if addr.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return true }                    // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isBlockedIPv4(Array(b[12..<16]))                     // ::ffff:a.b.c.d
            }
            if b[0..<12].allSatisfy({ $0 == 0 }) {
                return isBlockedIPv4(Array(b[12..<16]))
            }
            if Array(b[0..<12]) == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
                return isBlockedIPv4(Array(b[12..<16]))                     // 64:ff9b::/96
            }
            if Array(b[0..<6]) == [0x00, 0x64, 0xff, 0x9b, 0, 1] { return true }
            if b[0] == 0x01 && b[1..<8].allSatisfy({ $0 == 0 }) { return true }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] <= 0x01 { return true }
            if b[0] == 0x20 && b[1] == 0x02 {
                return isBlockedIPv4(Array(b[2..<6]))                       // 2002::/16
            }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return true }
            if b[0] == 0x3f && (b[1] & 0xf0) == 0xf0 { return true }
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }         // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }                        // fc00::/7 ULA
            if b[0] == 0xff { return true }                                 // multicast
            return false
        }
        return true // unparseable → block
    }

    private static func isBlockedIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        let (a, c) = (b[0], b[1])
        return a == 0 || a == 10 || a == 127 || (a == 100 && (64...127).contains(c))
            || (a == 169 && c == 254) || (a == 172 && (16...31).contains(c))
            || (a == 192 && c == 168) || (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2))
            || (a == 192 && c == 88 && b[2] == 99)
            || (a == 198 && (c == 18 || c == 19)) || a >= 224
            || (a == 198 && c == 51 && b[2] == 100) || (a == 203 && c == 0 && b[2] == 113)
    }

    static let webSearch = Tool(
        spec: ToolSpec(name: "web_search", description: "Search the web (DuckDuckGo). Returns titles, URLs, snippets.", parameters: [
            "type": "object",
            "properties": ["query": ["type": "string"], "limit": ["type": "integer"]],
            "required": ["query"],
        ]),
        category: .read
    ) { args, _ in
        guard let q = args.str("query") else { throw ToolError.missing("query") }
        return try await WebText.search(query: q, limit: min(max(args.int("limit") ?? 8, 1), 15))
    }

    // MARK: schedule_*

    static let scheduleCreate = Tool(
        spec: ToolSpec(name: "schedule_create", description: "Create a recurring or one-shot automation task that runs a prompt on schedule.", parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "prompt": ["type": "string", "description": "The prompt that runs each time"],
                "interval_seconds": ["type": "integer"],
                "daily": ["type": "object", "properties": ["time": ["type": "string"], "time_zone": ["type": "string"]]],
                "weekly": ["type": "object", "properties": ["time": ["type": "string"], "time_zone": ["type": "string"], "weekdays": ["type": "array", "items": ["type": "integer"], "description": "Required: 1-7, 1=Sunday"]], "required": ["time", "weekdays"]],
                "at": ["type": "string", "description": "ISO8601 one-shot time"],
            ],
            "required": ["title", "prompt"],
        ]),
        category: .meta
    ) { args, ctx in
        guard let sched = ctx.scheduler else { throw ToolError.failed("scheduler unavailable") }
        guard let title = args.str("title"), let prompt = args.str("prompt") else { throw ToolError.missing("title/prompt") }
        var kinds = 0
        if args.int("interval_seconds") != nil { kinds += 1 }
        if args["weekly"] != nil { kinds += 1 }
        if args["daily"] != nil { kinds += 1 }
        if args.str("at") != nil { kinds += 1 }
        guard kinds == 1 else { throw ToolError.failed("specify exactly one of: interval_seconds, daily, weekly, at") }
        var created: [AutomationTask] = []
        if let sec = args.int("interval_seconds") {
            guard sec >= 60 else { throw ToolError.failed("interval_seconds must be >= 60") }
            created.append(try sched.add(title: title, prompt: prompt, workspace: ctx.workspace, schedule: .interval(seconds: sec)))
        }
        if let raw = args["weekly"] {
            guard let w = raw as? [String: Any] else { throw ToolError.failed("weekly must be an object") }
            guard let t = w["time"] as? String else { throw ToolError.failed("weekly.time is required (HH:MM)") }
            let (h, m) = try Self.parseTime(t)
            let weekdays = (w["weekdays"] as? [NSNumber])?.map { $0.intValue } ?? (w["weekdays"] as? [Int]) ?? []
            guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { throw ToolError.failed("weekly.weekdays is required and must be in 1...7 (1=Sunday)") }
            for wd in Set(weekdays).sorted() {
                created.append(try sched.add(title: title, prompt: prompt, workspace: ctx.workspace,
                                         schedule: .weekly(weekday: wd, hour: h, minute: m, tz: w["time_zone"] as? String ?? TimeZone.current.identifier)))
            }
        }
        if let raw = args["daily"] {
            guard let d = raw as? [String: Any] else { throw ToolError.failed("daily must be an object") }
            guard let t = d["time"] as? String else { throw ToolError.failed("daily.time is required (HH:MM)") }
            let (h, m) = try Self.parseTime(t)
            created.append(try sched.add(title: title, prompt: prompt, workspace: ctx.workspace, schedule: .daily(hour: h, minute: m, tz: d["time_zone"] as? String ?? TimeZone.current.identifier)))
        }
        if let at = args.str("at") {
            guard let d = ISO8601DateFormatter().date(from: at) else { throw ToolError.failed("at must be ISO8601") }
            created.append(try sched.add(title: title, prompt: prompt, workspace: ctx.workspace, schedule: .once(at: d)))
        }
        guard let first = created.first else { throw ToolError.failed("need one of: interval_seconds, daily, weekly, at") }
        return "Created '\(title)', \(first.schedule.summary). Task id \(first.id.uuidString)." + (created.count > 1 ? " (\(created.count) tasks, one per weekday)" : "")
    }

    static let scheduleList = Tool(
        spec: ToolSpec(name: "schedule_list", description: "List automation tasks.", parameters: ["type": "object", "properties": [:]]),
        category: .read
    ) { _, ctx in
        guard let sched = ctx.scheduler else { throw ToolError.failed("scheduler unavailable") }
        let tasks = sched.tasks
        if tasks.isEmpty { return "no scheduled tasks" }
        return tasks.map { "\($0.enabled ? "on " : "off") \($0.title) | \($0.schedule.summary) | next: \($0.nextFire?.description ?? "-") | \($0.runs.count) runs | id \($0.id.uuidString)" }.joined(separator: "\n")
    }

    static let scheduleDelete = Tool(
        spec: ToolSpec(name: "schedule_delete", description: "Delete an automation task by id.", parameters: [
            "type": "object", "properties": ["id": ["type": "string"]], "required": ["id"],
        ]),
        category: .meta
    ) { args, ctx in
        guard let sched = ctx.scheduler, let id = args.str("id"), let uuid = UUID(uuidString: id)
        else { throw ToolError.missing("id") }
        guard sched.remove(id: uuid) else { throw ToolError.failed("no scheduled task with id \(uuid.uuidString)") }
        return "deleted"
    }

    private static func parseTime(_ t: String) throws -> (Int, Int) {
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            throw ToolError.failed("time must be HH:MM (00:00-23:59), got \(t)")
        }
        return (parts[0], parts[1])
    }

    // MARK: subagent

    static let subagent = Tool(
        spec: ToolSpec(name: "subagent", description: "Spawn a child agent with its own prompt and tool access. Returns its final answer. Use for parallelizable independent work.", parameters: [
            "type": "object",
            "properties": [
                "prompt": ["type": "string"],
                "max_turns": ["type": "integer", "description": "Default 15"],
            ],
            "required": ["prompt"],
        ]),
        category: .meta
    ) { args, ctx in
        guard let prompt = args.str("prompt") else { throw ToolError.missing("prompt") }
        guard ctx.depth < 1 else { throw ToolError.failed("subagents cannot spawn subagents") }
        guard let make = ctx.makeSubloop else { throw ToolError.failed("subagent unavailable") }
        var sub = ctx
        sub.depth = ctx.depth + 1
        sub.recordChange = ctx.recordChange
        let loop = make()
        return try await loop.runHeadless(prompt: prompt, ctx: sub, maxTurns: min(args.int("max_turns") ?? 15, 40))
    }

    // MARK: plugin_manager

    static let pluginManager = Tool(
        spec: ToolSpec(name: "plugin_manager", description: "Manage plugins: list, install_bundle (from a local dir), enable, disable, uninstall, transpile (JS bundle to native Swift).", parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["list", "install_bundle", "enable", "disable", "uninstall", "transpile"]],
                "name": ["type": "string", "description": "plugin id for enable/disable/uninstall/transpile"],
                "path": ["type": "string", "description": "source dir for install_bundle"],
            ],
            "required": ["action"],
        ]),
        category: .meta
    ) { args, ctx in
        guard let pe = ctx.plugins, let action = args.str("action") else { throw ToolError.missing("action") }
        switch action {
        case "list": return pe.describeForAgent()
        case "install_bundle":
            guard let p = args.str("path") else { throw ToolError.missing("path") }
            return try pe.install(from: URL(fileURLWithPath: ctx.resolveExternal(p)))
        case "enable", "disable":
            guard let n = args.str("name") else { throw ToolError.missing("name") }
            try pe.setEnabled(n, action == "enable")
            return "\(action)d \(n)"
        case "uninstall":
            guard let n = args.str("name") else { throw ToolError.missing("name") }
            try pe.uninstall(n); return "uninstalled \(n)"
        case "transpile":
            guard let n = args.str("name") else { throw ToolError.missing("name") }
            return try await pe.transpileToNative(name: n)
        default: throw ToolError.failed("unknown action \(action)")
        }
    }
}
