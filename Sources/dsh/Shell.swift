import Foundation
import Darwin

// MARK: - Shell runner

enum Shell {
    /// Drain a pipe on a background queue so a chatty child never blocks on a
    /// full pipe buffer while the parent waits for exit. Keeps only the last
    /// `cap` bytes so a runaway child cannot exhaust memory, and always
    /// consumes input so the child never blocks on a full pipe.
    static func drain(_ handle: FileHandle, into box: OutputBuffer, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.readData(ofLength: 65_536)
                if chunk.isEmpty { break } // EOF, or the read end was closed
                box.append(chunk)
            }
            group.leave()
        }
    }
    /// Bounded tail buffer for command output.
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []
        private var total = 0
        private var received = 0
        private var overflowed = false
        private let cap: Int
        private let byteLimit: Int?
        private let onLimit: () -> Void
        init(cap: Int, byteLimit: Int? = nil, onLimit: @escaping () -> Void = {}) {
            self.cap = cap; self.byteLimit = byteLimit; self.onLimit = onLimit
        }
        func append(_ d: Data) {
            lock.lock()
            received += d.count
            let shouldStop = !overflowed && byteLimit.map { received > $0 } == true
            if shouldStop { overflowed = true }
            chunks.append(d); total += d.count
            var excess = total - cap
            while excess > 0, let first = chunks.first {
                if first.count <= excess { total -= first.count; chunks.removeFirst(); excess -= first.count }
                else { chunks[0] = first.subdata(in: excess..<first.count); total -= excess; excess = 0 }
            }
            lock.unlock()
            if shouldStop { onLimit() }
        }
        func data() -> Data {
            lock.lock(); defer { lock.unlock() }
            var out = Data(); out.reserveCapacity(total)
            for c in chunks { out.append(c) }
            return out
        }
        var exceededLimit: Bool {
            lock.lock(); defer { lock.unlock() }
            return overflowed
        }
    }
    final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func install(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { Shell.killTree(process) }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { Shell.killTree(process) }
        }
        func finish() {
            lock.lock(); process = nil; lock.unlock()
        }
    }

    /// Terminate the process and its current descendants so inherited pipes close.
    static func killTree(_ proc: Process, after grace: TimeInterval = 2) {
        let pids = processTree(proc.processIdentifier)
        // Record each descendant's start time: after the grace period a pid
        // may have exited and been reused by an unrelated process, which
        // must never receive the delayed SIGKILL.
        let children = pids.dropFirst().map { ($0, startTime(of: $0)) }
        for (pid, _) in children.reversed() { kill(pid, SIGTERM) }
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            for (pid, started) in children {
                guard let started, startTime(of: pid) == started else { continue }
                kill(pid, SIGKILL)
            }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }

    /// Process start time (seconds, microseconds), or nil if the pid is gone.
    /// Together with the pid this identifies one process instance.
    static func startTime(of pid: pid_t) -> [UInt64]? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return [info.pbi_start_tvsec, info.pbi_start_tvusec]
    }

    private static func processTree(_ root: pid_t) -> [pid_t] {
        var pids = [root], seen: Set<pid_t> = [root], cursor = 0
        while cursor < pids.count && pids.count < 32_768 {
            let parent = pids[cursor]
            cursor += 1
            var children = [pid_t](repeating: 0, count: 4096)
            let bytes = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }
            guard bytes > 0 else { continue }
            let count = min(Int(bytes) / MemoryLayout<pid_t>.stride, children.count)
            for child in children.prefix(count) where child > 0 && seen.insert(child).inserted {
                pids.append(child)
            }
        }
        return pids
    }

    struct ProcessResult {
        var stdout: String
        var stderr: String
        var status: Int32
        var timedOut: Bool
        var drained: Bool
        var outputLimited: Bool
    }

    static func sanitizedEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let secretMarkers = ["SECRET", "PASSWORD", "PASSWD", "PASSPHRASE", "TOKEN",
                             "API_KEY", "APIKEY", "PRIVATE_KEY", "CREDENTIAL",
                             "ACCESS_KEY", "SESSION_TOKEN", "AUTH_TOKEN"]
        // Not secrets, but capability or code-injection vectors no spawned
        // shell should inherit: the user's live ssh-agent (authentication +
        // exfil channel), dyld interposition, shell startup files that run
        // in non-interactive shells, and runtime flags that inject code
        // into every interpreter the command launches.
        let blockedExact: Set<String> = [
            "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_ASKPASS", "GIT_ASKPASS",
            "GIT_SSH_COMMAND", "GIT_SSH", "BASH_ENV", "ENV", "ZDOTDIR",
            "SHELLOPTS", "BASHOPTS", "PROMPT_COMMAND",
            "NODE_OPTIONS", "PYTHONSTARTUP", "PYTHONINSPECT",
            "RUBYOPT", "PERL5OPT", "PERLLIB", "PERL5LIB",
            "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS",
        ]
        let blockedPrefixes = ["DYLD_"]
        var out: [String: String] = [:]
        out.reserveCapacity(env.count + 1)
        for (key, value) in env {
            let upper = key.uppercased()
            if secretMarkers.contains(where: upper.contains) { continue }
            if blockedExact.contains(upper) { continue }
            if blockedPrefixes.contains(where: { upper.hasPrefix($0) }) { continue }
            out[key] = value
        }
        out["TERM"] = "dumb"
        return out
    }

    static func capture(executable: URL, arguments: [String], cwd: String? = nil,
                        input: Data? = nil, timeout: TimeInterval,
                        maxOutputBytes: Int? = nil,
                        control: ProcessControl? = nil) throws -> ProcessResult {
        let proc = Process(), out = Pipe(), err = Pipe()
        let inp = input == nil ? nil : Pipe()
        proc.executableURL = executable
        proc.arguments = arguments
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        proc.environment = sanitizedEnvironment()
        if let inp { proc.standardInput = inp } else { proc.standardInput = FileHandle.nullDevice }
        proc.standardOutput = out; proc.standardError = err
        try proc.run()
        control?.install(proc)
        let oBox = OutputBuffer(cap: 4_000_000, byteLimit: maxOutputBytes,
                                onLimit: { control?.cancel() })
        let eBox = OutputBuffer(cap: 1_000_000)
        let group = DispatchGroup()
        drain(out.fileHandleForReading, into: oBox, group: group)
        drain(err.fileHandleForReading, into: eBox, group: group)
        if let input, let handle = inp?.fileHandleForWriting {
            DispatchQueue.global(qos: .utility).async {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = proc.isRunning
        if timedOut { killTree(proc) }
        proc.waitUntilExit()
        control?.finish()
        let drained = group.wait(timeout: .now() + 3) == .success
        // Lossy decode: a strict UTF-8 decode returns nil for ONE invalid
        // byte (a Latin-1 line, or the tail cap cutting a multi-byte
        // character) and would discard the entire output — grep then
        // reported "no matches" for files that matched.
        return ProcessResult(
            stdout: String(decoding: oBox.data(), as: UTF8.self),
            stderr: String(decoding: eBox.data(), as: UTF8.self),
            status: proc.terminationStatus,
            timedOut: timedOut,
            drained: drained,
            outputLimited: oBox.exceededLimit
        )
    }

    private static func combined(_ result: ProcessResult, timeout: TimeInterval,
                                includeStatus: Bool) -> String {
        var output = result.stdout
        if !result.stderr.isEmpty { output += (output.isEmpty ? "" : "\n") + result.stderr }
        if result.timedOut { output += "\n(killed: exceeded \(Int(timeout))s)" }
        if !result.drained { output += "\n(output may be incomplete: pipe holders still running)" }
        if includeStatus && result.status != 0 { output += "\n(exit \(result.status))" }
        if output.count > 100_000 { output = String(output.suffix(100_000)) + "\n(output truncated to last 100KB)" }
        return output.isEmpty ? "(no output)" : output
    }

    /// Dedicated pool for blocking process work. Swift's cooperative pool
    /// is sized to the core count, and capture() parks a thread in
    /// Thread.sleep / DispatchGroup.wait for the life of every command —
    /// enough concurrent bash calls, fetches, or extractions would starve
    /// every other task. GCD queues scale past the core count, so all
    /// subprocess waits hop here instead of occupying pool threads.
    static let blockingQueue = DispatchQueue(label: "dsh.blocking",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    static func captureAsync(executable: URL, arguments: [String], cwd: String? = nil,
                             input: Data? = nil, timeout: TimeInterval,
                             maxOutputBytes: Int? = nil) async throws -> ProcessResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                blockingQueue.async {
                    do {
                        continuation.resume(returning: try capture(
                            executable: executable, arguments: arguments, cwd: cwd,
                            input: input, timeout: timeout, maxOutputBytes: maxOutputBytes,
                            control: control))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Runs `command` with zsh. `sandbox` confines it (nil only for the
    /// app's own fixed commands, never for model- or plugin-chosen ones).
    static func run(_ command: String, cwd: String, timeout: TimeInterval,
                    sandbox: SandboxPolicy?) async throws -> String {
        let (exe, args) = try launch(command, sandbox)
        let result = try await captureAsync(executable: exe, arguments: args, cwd: cwd, timeout: timeout)
        return annotate(combined(result, timeout: timeout, includeStatus: true), result, sandbox)
    }

    static func runSync(_ command: String, cwd: String, timeout: TimeInterval,
                        sandbox: SandboxPolicy?) throws -> String {
        let (exe, args) = try launch(command, sandbox)
        let result = try capture(executable: exe, arguments: args, cwd: cwd, timeout: timeout)
        return annotate(combined(result, timeout: timeout, includeStatus: false), result, sandbox)
    }

    private static func launch(_ command: String, _ sandbox: SandboxPolicy?) throws -> (URL, [String]) {
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        guard let sandbox, sandbox.isConfined else { return (zsh, ["-c", command]) }
        // Fail closed: a broken sandbox must not silently become no sandbox.
        guard SandboxPolicy.isAvailable else { throw ToolError.failed(SandboxPolicy.unavailableMessage) }
        return sandbox.wrap(zsh, ["-c", command])
    }

    private static func annotate(_ text: String, _ result: ProcessResult, _ sandbox: SandboxPolicy?) -> String {
        guard let sandbox, result.status != 0,
              let hint = SandboxPolicy.denialHint(for: result.stdout + result.stderr, policy: sandbox) else { return text }
        return text + "\n" + hint
    }
}

// MARK: - Wildcard → regex

enum Wildcard {
    private static let neverMatches = try! NSRegularExpression(pattern: "a^")

    static func regex(_ pattern: String) -> NSRegularExpression {
        var rx = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex && pattern[after] == "/" {
                        rx += "(?:.*/)?"; i = pattern.index(after: after)
                    } else {
                        rx += ".*"; i = after
                    }
                } else { rx += "[^/]*"; i = next }
            } else if c == "?" { rx += "[^/]"; i = pattern.index(after: i) }
            else { rx += NSRegularExpression.escapedPattern(for: String(c)); i = pattern.index(after: i) }
        }
        return (try? NSRegularExpression(pattern: "^\(rx)$")) ?? Self.neverMatches
    }
}
