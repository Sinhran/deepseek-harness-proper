import Foundation

/// How far shell commands chosen by the model (and commands plugins run)
/// may reach. Enforced by the kernel through Seatbelt (`sandbox-exec`), so
/// it holds even after a command is approved: approval decides *whether*
/// a command runs, the sandbox decides *what it can touch*.
enum SandboxMode: String, Codable, CaseIterable {
    case readOnly, workspaceWrite, fullAccess

    var label: String {
        switch self {
        case .readOnly: return "Read-only"
        case .workspaceWrite: return "Workspace only"
        case .fullAccess: return "Full access (no sandbox)"
        }
    }
    var detail: String {
        switch self {
        case .readOnly: return "Commands can read files but not change any."
        case .workspaceWrite: return "Commands can change files only in the workspace and temporary folders."
        case .fullAccess: return "Commands can change anything your account can. Not recommended."
        }
    }
}

struct SandboxPolicy: Equatable {
    var mode: SandboxMode
    /// Writable besides the temporary folders (workspace-write only).
    var writableRoots: [String]
    var network: Bool = true
    var protectSecrets: Bool = true

    var isConfined: Bool { mode != .fullAccess }

    /// The policy for commands run on behalf of the agent in `workspace`,
    /// from the user's settings. `extraRoots` adds writable folders (a
    /// plugin's own directory).
    static func current(workspace: String, mode: SandboxMode? = nil, extraRoots: [String] = []) -> SandboxPolicy {
        let s = Settings.shared
        return SandboxPolicy(mode: mode ?? s.sandboxMode, writableRoots: [workspace] + extraRoots,
                             network: s.sandboxNetwork, protectSecrets: s.sandboxProtectSecrets)
    }

    /// Credentials and private data, relative to home. Denied for reading
    /// and writing even inside a workspace-write sandbox. Anything that
    /// genuinely needs one of these (git over SSH, gh) asks to run outside.
    static let protectedPaths: [(path: String, isFile: Bool)] = [
        (".ssh", false), (".gnupg", false), (".aws", false), (".azure", false),
        (".config/gcloud", false), (".config/gh", false),
        (".netrc", true), (".git-credentials", true), (".pypirc", true),
        ("Library/Keychains", false), ("Library/Cookies", false),
        ("Library/Mail", false), ("Library/Messages", false), ("Library/Safari", false),
        ("Library/Application Support/Google/Chrome", false),
        ("Library/Application Support/Firefox", false),
        ("Library/Application Support/BraveSoftware", false),
        ("Library/Application Support/Arc", false),
        ("Library/Application Support/dsh-proper", false),
    ]

    /// Seatbelt profile. Allow by default, then: deny all writes except the
    /// writable roots and temp areas, deny the protected paths entirely,
    /// and optionally deny IP networking.
    func profile(home: String = NSHomeDirectory()) -> String {
        var forms = ["(version 1)", "(allow default)", "(deny file-write*)"]
        var writable = ["(literal \(Self.sbpl("/dev/null")))"]
        if mode == .workspaceWrite {
            let roots = writableRoots + Self.tempRoots
            for root in Set(roots.map(Self.canonical)).sorted() {
                writable.append("(subpath \(Self.sbpl(root)))")
            }
        }
        forms.append("(allow file-write* \(writable.joined(separator: " ")))")
        if protectSecrets {
            let filters = Self.protectedPaths.map { entry -> String in
                let full = Self.canonical((home as NSString).appendingPathComponent(entry.path))
                return entry.isFile ? "(literal \(Self.sbpl(full)))" : "(subpath \(Self.sbpl(full)))"
            }
            // Later rules win in SBPL, so this also beats a workspace that
            // happens to contain one of these paths.
            forms.append("(deny file-read* file-write* \(filters.joined(separator: " ")))")
        }
        if !network {
            forms.append("(deny network-outbound (remote ip))")
            forms.append("(deny network-inbound (local ip))")
        }
        return forms.joined(separator: " ")
    }

    /// The command line that runs `executable arguments` under this policy.
    func wrap(_ executable: URL, _ arguments: [String]) -> (URL, [String]) {
        guard isConfined else { return (executable, arguments) }
        return (Self.sandboxExec, ["-p", profile(), executable.path] + arguments)
    }

    static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// Temporary areas tools expect to write: /tmp, the per-user temp dir,
    /// and the per-user cache dir (clang/swift module caches live there).
    static var tempRoots: [String] {
        var roots = ["/private/tmp", NSTemporaryDirectory()]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            roots.append(String(cString: buffer))
        }
        return roots
    }

    /// Seatbelt matches real paths: /tmp is /private/tmp, and so on.
    static func canonical(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if let real = realpath(p, nil) { p = String(cString: real); free(real) }
        else if p.hasPrefix("/tmp/") || p == "/tmp" { p = "/private" + p }
        else if p.hasPrefix("/var/") { p = "/private" + p }
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// An SBPL string literal.
    static func sbpl(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether Seatbelt works here, probed once with a real profile. When it
    /// doesn't, confined commands are refused, never run unconfined.
    static let isAvailable: Bool = {
        guard FileManager.default.isExecutableFile(atPath: sandboxExec.path) else { return false }
        let probe = SandboxPolicy(mode: .readOnly, writableRoots: [])
        let (exe, args) = probe.wrap(URL(fileURLWithPath: "/usr/bin/true"), [])
        let p = Process()
        p.executableURL = exe; p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    static let unavailableMessage = "The sandbox isn't working on this Mac (sandbox-exec failed), so the command was blocked instead of running unconfined. To run commands without it, set Settings → Sandbox to Full access."

    /// A note for the model when a confined command likely hit the sandbox,
    /// so it knows to ask instead of retrying blindly.
    static func denialHint(for output: String, policy: SandboxPolicy) -> String? {
        guard policy.isConfined, output.range(of: "operation not permitted", options: .caseInsensitive) != nil
            || output.contains("Couldn't connect to server") && !policy.network else { return nil }
        var reach = policy.mode == .readOnly
            ? "it can't change any files" : "it can change files only in the workspace and temporary folders"
        if policy.protectSecrets { reach += ", can't read credentials (~/.ssh, ~/.aws, Keychains, browser data)" }
        if !policy.network { reach += ", and has no network access" }
        return "[sandbox] This command runs sandboxed: \(reach). If the task really needs more, retry with \"unsandboxed\": true. That asks the user to approve this one command outside the sandbox."
    }
}
