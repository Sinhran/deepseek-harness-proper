import Foundation

// MARK: - Wire types (DeepSeek / OpenAI-compatible API)

enum Role: String, Codable { case system, user, assistant, tool }

struct WireMessage: Codable {
    var role: Role
    var content: String? = nil
    var reasoning_content: String? = nil
    var tool_calls: [WireToolCall]? = nil
    var tool_call_id: String? = nil
    var name: String? = nil
}

struct WireToolCall: Codable {
    var id: String
    var type: String = "function"
    var function: WireFunction
    struct WireFunction: Codable { var name: String; var arguments: String }
}

struct ToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any] // JSONSchema object

    var wire: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

// MARK: - UI-level model

enum StepStatus: String, Codable { case pending, running, ok, denied, error, waiting }

enum StepKind: String, Codable { case tool, approval, note }

struct Step: Codable, Identifiable {
    var id = UUID()
    var kind: StepKind = .tool
    var name: String
    var payload: String = ""
    var result: String = ""
    var status: StepStatus = .pending
    var durationMS: Int = 0
    var expanded: Bool = false
}

struct Message: Codable, Identifiable {
    var id = UUID()
    var role: Role
    var content: String = ""
    var reasoning: String = ""
    var steps: [Step] = []
    var time = Date()
    var turn: Int = 0
}

struct FileChange: Codable, Identifiable {
    var id = UUID()
    var path: String
    var before: String
    var after: String
    var turn: Int
    var time = Date()
    /// The agent created this file (it did not exist before). Lets Rewind
    /// delete it instead of leaving an empty file. Nil in records written
    /// before this field existed: treated as "not known to be created".
    var created: Bool? = nil
    /// `before` holds the real prior text. False when the prior file was not
    /// UTF-8 and `before` is only a placeholder: Rewind must not write it back.
    var restorable: Bool? = nil

    init(path: String, before: String, after: String, turn: Int,
         created: Bool? = nil, restorable: Bool? = nil) {
        self.path = path; self.before = before; self.after = after; self.turn = turn
        self.created = created; self.restorable = restorable
    }
}

struct Session: Codable, Identifiable {
    var id = UUID()
    var title: String
    var created = Date()
    var updated = Date()
    var workspace: String
    var model: String = ""
    var messages: [Message] = []
    var wire: [WireMessage] = []
    var changes: [FileChange] = []
    var scheduledTaskID: UUID? = nil
    var running: Bool = false // transient, not persisted meaningfully
}

// MARK: - Automation

struct TaskRun: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var sessionID: UUID
    var status: TaskRunStatus = .running
    /// Failure detail, set when status is .error.
    var message: String? = nil

    /// Decodes the legacy free-form status strings written before TaskRunStatus
    /// existed: "ok", "running", "error", and "error: <detail>".
    enum TaskRunStatus: String, Codable {
        case running, ok, error

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "ok": self = .ok
            case "running": self = .running
            // "error" and the legacy "error: <detail>" form.
            default: self = .error
            }
        }
    }
}

enum Schedule: Codable, Equatable {
    case interval(seconds: Int)
    case daily(hour: Int, minute: Int, tz: String)
    case weekly(weekday: Int, hour: Int, minute: Int, tz: String)
    case once(at: Date)

    var summary: String {
        switch self {
        case .interval(let s): return "Every \(s >= 3600 ? "\(s/3600)h" : s >= 60 ? "\(s/60)m" : "\(s)s")"
        case .daily(let h, let m, let tz): return String(format: "Daily at %02d:%02d (%@)", h, m, tz)
        case .weekly(let d, let h, let m, let tz):
            let days = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let day = (1...7).contains(d) ? days[d] : "invalid day \(d)"
            return String(format: "Weekly on %@ at %02d:%02d (%@)", day, h, m, tz)
        case .once(let d):
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            return "Once at \(f.string(from: d))"
        }
    }

    /// Rejects schedules that would fire every tick or never compute a sane
    /// next fire (zero/negative intervals, out-of-range clock fields).
    var isValid: Bool { isValid(at: Date()) }

    /// Validation against an explicit instant. Scheduler.add validates and
    /// computes nextFire from the SAME `now`, so a one-shot time that is
    /// only seconds away cannot pass validation and then compute a nil
    /// nextFire (which left an enabled task that never fired).
    func isValid(at now: Date) -> Bool {
        func tzOK(_ tz: String) -> Bool { TimeZone(identifier: tz) != nil }
        switch self {
        case .interval(let s): return s >= 60
        case .daily(let h, let m, let tz): return (0...23).contains(h) && (0...59).contains(m) && tzOK(tz)
        case .weekly(let d, let h, let m, let tz): return (1...7).contains(d) && (0...23).contains(h) && (0...59).contains(m) && tzOK(tz)
        case .once(let d): return d > now
        }
    }

    func nextFire(after now: Date = Date()) -> Date? {
        switch self {
        case .interval(let s): return now.addingTimeInterval(TimeInterval(s))
        case .once(let d): return d > now ? d : nil
        case .daily(let h, let m, let tz):
            return Self.next(hour: h, minute: m, tz: tz, weekday: nil, after: now)
        case .weekly(let wd, let h, let m, let tz):
            return Self.next(hour: h, minute: m, tz: tz, weekday: wd, after: now)
        }
    }

    private static func next(hour: Int, minute: Int, tz: String, weekday: Int?, after now: Date) -> Date? {
        var cal = Calendar.current
        if let zone = TimeZone(identifier: tz) { cal.timeZone = zone }
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            var comps = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard let candidate = cal.date(from: comps), candidate > now else { continue }
            if let wd = weekday, cal.component(.weekday, from: candidate) != wd { continue }
            return candidate
        }
        return nil
    }
}

struct AutomationTask: Codable, Identifiable {
    var id = UUID()
    var title: String
    var prompt: String
    var workspace: String
    var schedule: Schedule
    var enabled = true
    var nextFire: Date?
    var runs: [TaskRun] = []
}

// MARK: - Plugins

enum PluginKind: String, Codable { case js, native, manifest }

struct PluginRecord: Codable, Identifiable {
    var id: String          // directory name
    var name: String
    var version: String = ""
    var desc: String = ""
    var kind: PluginKind
    /// New bundles start disabled: dropping a folder into the plugins dir is
    /// arbitrary code at next launch, so it takes an explicit trust action.
    var enabled = false
    var broken: String? = nil // error string if load failed
}

// MARK: - Misc

struct Attachment: Codable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    var name: String
    var kind: String // "text" | "pdf" | "image" | "doc" | "sheet"
    var extractedText: String = ""
}

enum Autonomy: String, Codable, CaseIterable {
    case ask, autoRead, autoWrite, full
    var label: String {
        switch self {
        case .ask: return "Ask for everything"
        case .autoRead: return "Auto-approve reads"
        case .autoWrite: return "Auto-approve reads + writes"
        case .full: return "Full autonomy"
        }
    }
    /// The lesser of `self` and `cap` (cases are declared least to most
    /// permissive). A nil cap leaves the level unchanged.
    func capped(at cap: Autonomy?) -> Autonomy {
        guard let cap,
              let mine = Self.allCases.firstIndex(of: self),
              let limit = Self.allCases.firstIndex(of: cap) else { return self }
        return Self.allCases[min(mine, limit)]
    }
}

// MARK: - JSON helpers (tool args are arbitrary JSON)

enum JSON {
    static func object(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d),
              let dict = o as? [String: Any] else { return [:] }
        return dict
    }
    static func string(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "\(o)" }
        return s
    }
    static func compact(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: d, encoding: .utf8) else { return "\(o)" }
        return s
    }
}

extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
