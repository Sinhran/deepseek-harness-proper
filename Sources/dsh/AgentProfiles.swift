import Foundation

/// Agent profiles vendored verbatim from the official DeepSeek Harness repo.
///
/// Source: https://github.com/deepseek-ai/deepseek-harness
/// commit fcc0ad462172522aaf5c93a7b2e01f6b9f0b0159 (master, 2026-11-04)
/// packages/bundle/web-app/presets/{standard,minimal,ptc,cordis}.patch.yml
///
/// The raw YAML lives in Resources/AgentProfiles/*.patch.yml (copied into the
/// app bundle) and is parsed at launch, so the structs below always reflect
/// the upstream files rather than a copy. AgentProfileYAML is the embedded
/// fallback for builds where the resources are not reachable.
enum AgentProfiles {

    /// Profiles that fail to parse are dropped; if none survive, this safe
    /// fallback keeps the app usable without ever enabling write tools.
    private static let fallbackProfile = Profile(
        id: "fallback", order: 999,
        personaPrefix: "You are a careful coding assistant.",
        personaComplete: false,
        instructionsMaxBytes: nil, hasTimeContext: false,
        plugins: [], nativeTools: ["read", "grep", "glob"],
        unsupportedTools: [], rawYAML: "")

    /// Bundled resource first (the shipped source of truth), embedded copy
    /// second (dev binaries without a resource bundle), nil last.
    private static func yamlSource(_ name: String) -> String {
        let file = "\(name).patch.yml"
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("AgentProfiles"),
           let s = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) {
            return s
        }
        switch name {
        case "standard": return AgentProfileYAML.standard
        case "minimal": return AgentProfileYAML.minimal
        case "ptc": return AgentProfileYAML.ptc
        default: return AgentProfileYAML.cordis
        }
    }

    static let all: [Profile] = {
        let raws = [yamlSource("standard"), yamlSource("minimal"),
                    yamlSource("ptc"), yamlSource("cordis")]
        var profiles = raws.compactMap { parse(yaml: $0) }.sorted { $0.order < $1.order }
        if profiles.isEmpty { profiles = [fallbackProfile] }
        return profiles
    }()

    static func profile(id: String) -> Profile {
        all.first { $0.id == id } ?? all.first { $0.id == "standard" } ?? fallbackProfile
    }

    struct PluginRow {
        var id: String
        var name: String
        var disabled: Bool
        /// Raw `disabled` value, kept so unknown gates can be reported.
        var disabledExpr: YVal? = nil
        /// Raw config subtree for targeted extraction (persona text, fs flags...).
        var config: YVal?
        /// Rows nested inside a `cordis:group` row (planning, delegation...).
        var children: [PluginRow] = []
    }

    struct Profile {
        var id: String
        var order: Int
        var personaPrefix: String
        var personaComplete: Bool
        var instructionsMaxBytes: Int?
        var hasTimeContext: Bool
        var plugins: [PluginRow]
        /// Native tool names this profile enables (subset of Tools.all() specs).
        var nativeTools: Set<String>
        /// Enabled upstream rows with no native equivalent.
        var unsupportedTools: [String]
        var rawYAML: String
    }

    // MARK: - Extraction

    static func parse(yaml: String) -> Profile? {
        guard let doc = YMini.parse(yaml),
              case .seq(let top) = doc, let first = top.first,
              case .map(let pairs) = first,
              let insert = pairs.first(where: { $0.key == "insert" })?.value,
              case .seq(let rows) = insert, let preset = rows.first,
              case .map(let presetPairs) = preset,
              let config = presetPairs.first(where: { $0.key == "config" })?.value,
              case .map(let cfgPairs) = config,
              cfgPairs.contains(where: { $0.key == "id" }) else { return nil }
        // Last-wins on duplicate keys: a malformed preset must fail closed at
        // the row level, never trap the dictionary constructor at launch.
        let cfg = Dictionary(cfgPairs, uniquingKeysWith: { _, last in last })
        guard let id = cfg.string("id"), let order = cfg.int("order"),
              case .seq(let pluginVals) = cfg.value("plugins") else { return nil }
        let plugins = pluginVals.compactMap { parseRow($0) }
        func row(_ id: String) -> PluginRow? { plugins.first { $0.id == id } }
        func enabled(_ id: String) -> Bool { row(id).map { !$0.disabled } ?? false }
        let personaCfg = row("persona")?.config?.mapPairs ?? [:]
        let fsCfg = row("tool-fs")?.config?.mapPairs ?? [:]
        let webCfg = row("tool-web")?.config?.mapPairs ?? [:]
        var tools = Set<String>()
        var unsupported: [String] = []
        /// Upstream capability flags are opt-out: an absent key means the
        /// plugin default (enabled). A present-but-unparseable value fails
        /// closed, and quoted "false" must not read as enabled.
        func flag(_ m: [String: YVal], _ k: String) -> Bool {
            guard let v = m[k] else { return true }
            switch v {
            case .bool(let b): return b
            case .string(let s):
                switch s.lowercased() {
                case "true": return true
                case "false": return false
                default: return false
                }
            case .int(let n): return n != 0
            default: return false
            }
        }
        if enabled("tool-bash") || enabled("tool-pwsh") { tools.insert("bash") }
        if let persist = row("persistent-shell"), !persist.disabled { tools.insert("bash") }
        if enabled("tool-fs") {
            if flag(fsCfg, "read") { tools.insert("read") }
            if flag(fsCfg, "write") { tools.insert("write") }
            if flag(fsCfg, "edit") { tools.insert("edit") }
        }
        if enabled("tool-fs-search") { tools.insert("grep"); tools.insert("glob") }
        if enabled("tool-schedule") {
            tools.insert("schedule_create"); tools.insert("schedule_list"); tools.insert("schedule_delete")
        }
        if let delegation = row("delegation"), !delegation.disabled,
           delegation.children.contains(where: { ($0.id == "tool-subagent") && !$0.disabled }) {
            tools.insert("subagent")
        }
        if enabled("tool-web") {
            if flag(webCfg, "fetch") { tools.insert("web_fetch") }
            if flag(webCfg, "search") { tools.insert("web_search") }
        }
        if enabled("tool-plugin-manager") || enabled("tool-plugin-market") {
            tools.insert("plugin_manager")
        }
        // Rows that enable something with no native counterpart. Skill rows
        // (skill-filesystem, tool-skill) and `present` are capabilities, not
        // tools: skills render into the system prompt and file changes always
        // surface in the Review pane, so they need no gate and are not listed.
        let toolish: Set<String> = ["tool-jobs", "command-goal", "tool-goal",
            "tool-ask-user", "tool-todo", "tool-executor-ptc", "tool-cordis",
            "tool-workflow", "workflow-ptc", "tool-subagent-fork",
            "tool-subagent-control", "compaction", "compaction-basic",
            "command-compact", "tool-result-pruner"]
        func collect(_ rows: [PluginRow]) {
            for r in rows {
                if !r.disabled && toolish.contains(r.id) { unsupported.append(r.id) }
                // An unrecognized gate fails closed; say so rather than letting
                // the row vanish from Settings with no explanation.
                if let gate = unknownGate(r.disabledExpr) {
                    unsupported.append("\(r.id) (unknown gate: \(gate))")
                }
                collect(r.children)
            }
        }
        collect(plugins)
        return Profile(
            id: id, order: order,
            personaPrefix: (personaCfg["prefix"]?.stringValue) ?? "",
            personaComplete: (personaCfg["complete"]?.boolValue) ?? false,
            instructionsMaxBytes: row("agent-instructions")?.config?.mapPairs["maxBytes"]?.intValue,
            hasTimeContext: enabled("time-context"),
            plugins: plugins,
            nativeTools: tools,
            unsupportedTools: unsupported.sorted(),
            rawYAML: yaml)
    }

    /// One-line capability summary for Settings, e.g. "bash, read/write/edit, search, web, schedule, subagent".
    static func capabilitySummary(_ p: Profile) -> String {
        var parts: [String] = []
        let t = p.nativeTools
        if t.contains("bash") { parts.append("shell") }
        let rw = ["read", "write", "edit"].filter { t.contains($0) }
        if !rw.isEmpty { parts.append(rw.joined(separator: "/")) }
        if t.contains("grep") { parts.append("search") }
        if t.contains("web_fetch") { parts.append("web") }
        if t.contains("schedule_create") { parts.append("schedule") }
        if t.contains("subagent") { parts.append("subagent") }
        if t.contains("plugin_manager") { parts.append("plugins") }
        if parts.isEmpty { parts.append("shell only") }
        return parts.joined(separator: ", ")
    }

    private static func parseRow(_ v: YVal) -> PluginRow? {
        guard case .map(let pairs) = v else { return nil }
        func str(_ k: String) -> String { pairs.first(where: { $0.key == k })?.value.stringValue ?? "" }
        let id = str("id")
        guard !id.isEmpty else { return nil }
        let name = str("name")
        let disabledValue = pairs.first(where: { $0.key == "disabled" })?.value
        let disabled = evaluateDisabled(disabledValue)
        let config = pairs.first(where: { $0.key == "config" })?.value
        var children: [PluginRow] = []
        if case .seq(let items) = config {
            children = items.compactMap { parseRow($0) }
        }
        return PluginRow(id: id, name: name, disabled: disabled, disabledExpr: disabledValue,
                         config: config, children: children)
    }

    /// Evaluates upstream `disabled` conditions for this macOS app context.
    /// The app always runs inside a profile on macOS, so platform and
    /// profile-context expressions resolve statically.
    ///
    /// Returns true when the row should be DISABLED. An absent `disabled` key
    /// means enabled (false). A present-but-unrecognized expression returns
    /// true, so an unknown gate can never silently turn a row on.
    /// The raw expression of a `disabled` gate this app does not understand,
    /// or nil when the value is absent/known. Surfaced in Settings so a new
    /// upstream gate does not silently disable a row with no explanation.
    static func unknownGate(_ v: YVal?) -> String? {
        guard case .string(let s)? = v else { return nil }
        var expr = s
        if expr.hasPrefix("!!js") { expr = String(expr.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        if expr.count >= 2 {
            let f = expr.first!, l = expr.last!
            if (f == "\"" && l == "\"") || (f == "'" && l == "'") { expr = String(expr.dropFirst().dropLast()) }
        }
        let known: Set<String> = ["true", "false",
            "process.platform === 'win32'", "process.platform !== 'win32'",
            "!ctx.get('profileContext')"]
        return known.contains(expr) ? nil : expr
    }

    static func evaluateDisabled(_ v: YVal?) -> Bool {
        guard let v else { return false }
        switch v {
        case .bool(let b): return b
        case .string(let s):
            var expr = s
            if expr.hasPrefix("!!js") { expr = String(expr.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            // Strip one wrapping quote pair only: a blanket trim would eat the
            // quotes inside expressions like process.platform === 'win32'.
            if expr.count >= 2 {
                let f = expr.first!, l = expr.last!
                if (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                    expr = String(expr.dropFirst().dropLast())
                }
            }
            if expr == "true" { return true }
            if expr == "false" { return false }
            if expr == "process.platform === 'win32'" { return false }
            if expr == "process.platform !== 'win32'" { return true }
            if expr == "!ctx.get('profileContext')" { return false }
            return true // unknown expression: disable the row
        default: return true // malformed value: disable the row
        }
    }
}

// MARK: - Minimal YAML subset parser

/// Just enough YAML for the vendored preset patches: nested maps, sequences
/// of maps/scalars, `|`/`|-`/`>`/`>-` literal blocks, `!!js` scalars,
/// quoted strings, bools, ints, and full-line comments.
enum YVal {
    case string(String)
    case bool(Bool)
    case int(Int)
    case seq([YVal])
    case map([(key: String, value: YVal)])

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        default: return ""
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? { if case .int(let n) = self { return n }; return nil }
    var mapPairs: [String: YVal] {
        guard case .map(let p) = self else { return [:] }
        return Dictionary(p, uniquingKeysWith: { _, last in last })
    }
    func string(_ k: String) -> String? { mapPairs[k]?.stringValue }
}

enum YMini {
    static func parse(_ text: String) -> YVal? {
        var p = Parser(lines: text.components(separatedBy: "\n"))
        return p.parseBlock(minIndent: 0)
    }

    struct Parser {
        var lines: [String]
        var i = 0

        mutating func peek() -> (indent: Int, text: String)? {
            var j = i
            while j < lines.count {
                let raw = lines[j]
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { j += 1; continue }
                return (indentOf(raw), t)
            }
            return nil
        }

        mutating func parseBlock(minIndent: Int) -> YVal? {
            guard let n = peek(), n.indent >= minIndent else { return nil }
            if n.text == "-" || n.text.hasPrefix("- ") { return parseSeq(indent: n.indent) }
            return parseMap(indent: n.indent)
        }

        /// Index of the `key:` colon in a line/seq item, or nil when the
        /// text is a plain scalar. A colon only splits a pair when it is
        /// followed by a space or end-of-line and sits outside quotes —
        /// so `- http://x`, `key:value`, and `- "a: b"` stay scalars.
        func pairColon(_ s: String) -> String.Index? {
            var quote: Character? = nil
            var i = s.startIndex
            while i < s.endIndex {
                let c = s[i]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ":" {
                    let n = s.index(after: i)
                    if n == s.endIndex || s[n] == " " { return i }
                }
                i = s.index(after: i)
            }
            return nil
        }

        mutating func parseMap(indent: Int) -> YVal? {
            var pairs: [(key: String, value: YVal)] = []
            while let n = peek(), n.indent == indent, !n.text.hasPrefix("- ") && n.text != "-" {
                i = advancePastComments(i)
                let raw = lines[i]; i += 1
                let t = raw.trimmingCharacters(in: .whitespaces)
                guard let ci = pairColon(t) else { continue }
                let key = String(t[..<ci]).trimmingCharacters(in: .whitespaces)
                let rest = String(t[t.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    if let c = peek(), c.indent > indent {
                        pairs.append((key, parseBlock(minIndent: c.indent) ?? .string("")))
                    } else {
                        pairs.append((key, .string("")))
                    }
                } else if rest == "|" || rest == "|-" || rest == ">" || rest == ">-" {
                    pairs.append((key, parseLiteral(style: rest, parentIndent: indent)))
                } else {
                    pairs.append((key, scalar(rest)))
                }
            }
            return .map(pairs)
        }

        mutating func parseSeq(indent: Int) -> YVal {
            var items: [YVal] = []
            while let n = peek(), n.indent == indent, n.text == "-" || n.text.hasPrefix("- ") {
                i = advancePastComments(i)
                let raw = lines[i]; i += 1
                let t = raw.trimmingCharacters(in: .whitespaces)
                let rest = t == "-" ? "" : String(t.dropFirst(2))
                if rest.isEmpty {
                    if let c = peek(), c.indent > indent {
                        items.append(parseBlock(minIndent: c.indent) ?? .string(""))
                    } else { items.append(.string("")) }
                    continue
                }
                if let ci = pairColon(rest) {
                    let key = String(rest[..<ci]).trimmingCharacters(in: .whitespaces)
                    // A `- ` item with no space before the key and no quoted
                    // colon inside the key starts an inline map.
                    if !key.isEmpty && (!key.contains(" ") || key.hasPrefix("\"") || key.hasPrefix("'")) {
                        var pairs: [(key: String, value: YVal)] = []
                        let v = String(rest[rest.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                        if v.isEmpty {
                            if let c = peek(), c.indent > indent {
                                pairs.append((key, parseBlock(minIndent: c.indent) ?? .string("")))
                            } else { pairs.append((key, .string(""))) }
                        } else if v == "|" || v == "|-" || v == ">" || v == ">-" {
                            // The literal's parent is the key column, not
                            // the literal's own first-line indent.
                            pairs.append((key, parseLiteral(style: v, parentIndent: indent + 2)))
                        } else {
                            pairs.append((key, scalar(v)))
                        }
                        // Continuation pairs are detected after the value is
                        // consumed: peeking earlier would read a literal's
                        // own first line as the continuation indent.
                        if let ci2 = peek().flatMap({ $0.indent > indent ? $0.indent : nil }),
                           let m = parseContinuation(indent: ci2) {
                            pairs += m
                        }
                        items.append(.map(pairs))
                        continue
                    }
                }
                items.append(scalar(rest))
            }
            return .seq(items)
        }

        /// Further `key: value` pairs of the same inline map, at a deeper indent.
        mutating func parseContinuation(indent: Int) -> [(key: String, value: YVal)]? {
            guard let n = peek(), n.indent == indent, !n.text.hasPrefix("- ") else { return nil }
            if case .map(let pairs) = parseMap(indent: indent) { return pairs }
            return nil
        }

        mutating func parseLiteral(style: String, parentIndent: Int) -> YVal {
            var buf: [String] = []
            var litIndent: Int?
            while i < lines.count {
                let raw = lines[i]
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { buf.append(""); i += 1; continue }
                let ind = indentOf(raw)
                if ind <= parentIndent { break }
                litIndent = litIndent ?? ind
                buf.append(String(raw.dropFirst(min(litIndent!, raw.count))))
                i += 1
            }
            while buf.last == "" { buf.removeLast() }
            if style.hasPrefix(">") {
                // Folded: single newlines become spaces, blank lines stay.
                var out = "", prevBlank = true
                for (k, line) in buf.enumerated() {
                    if line.isEmpty { out += "\n"; prevBlank = true; continue }
                    if k > 0 && !prevBlank { out += " " }
                    out += line; prevBlank = false
                }
                return .string(out)
            }
            return .string(buf.joined(separator: "\n"))
        }

        func indentOf(_ s: String) -> Int {
            var n = 0
            for c in s { if c == " " { n += 1 } else { break } }
            return n
        }

        func advancePastComments(_ j: Int) -> Int {
            var k = j
            while k < lines.count {
                let t = lines[k].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { k += 1; continue }
                break
            }
            return k
        }

        func scalar(_ s: String) -> YVal {
            var v = s
            if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) ||
               (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
                v = String(v.dropFirst().dropLast())
                return .string(v)
            }
            if v == "true" { return .bool(true) }
            if v == "false" { return .bool(false) }
            if let n = Int(v) { return .int(n) }
            return .string(v)
        }
    }
}

extension Dictionary where Key == String, Value == YVal {
    func string(_ k: String) -> String? {
        guard let v = self[k] else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }
    func int(_ k: String) -> Int? {
        guard let v = self[k] else { return nil }
        if case .int(let n) = v { return n }
        return nil
    }
    func value(_ k: String) -> YVal? { self[k] }
}
