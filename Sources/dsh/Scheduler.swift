import Foundation

/// Automation: fires scheduled agent runs in the background.
final class Scheduler {
    static let shared = Scheduler()
    private let lock = NSLock()
    private var _tasks: [AutomationTask] = []
    var tasks: [AutomationTask] { lock.lock(); defer { lock.unlock() }; return _tasks }
    private func mutate(_ body: (inout [AutomationTask]) -> Void) {
        lock.lock(); body(&_tasks); lock.unlock()
    }
    private func mutateRet<T>(_ body: (inout [AutomationTask]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&_tasks)
    }
    private var timer: DispatchSourceTimer?
    /// In-memory claim set: a task id sits here between "due" and "dispatched"
    /// so a second queued tick cannot fire it twice. Never persisted, so a
    /// crash automatically releases every claim.
    private var claimedIDs = Set<UUID>()
    private let io = DispatchQueue(label: "dsh.sched", qos: .utility)
    var onChange: () -> Void = {}
    /// Injected by the UI layer so scheduled runs can open sessions.
    var runTask: ((AutomationTask) -> UUID?)? = nil

    private let enc = JSONEncoder(); private let dec = JSONDecoder()

    private init() {
        enc.dateEncodingStrategy = .iso8601; dec.dateDecodingStrategy = .iso8601
        load()
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.schedule(deadline: .now() + 10, repeating: 15)
        timer?.setEventHandler { [weak self] in self?.tick() }
        timer?.resume()
    }

    private var backupFile: URL { Settings.tasksFile.appendingPathExtension("bak") }
    private func load() {
        let decoded = (try? Data(contentsOf: Settings.tasksFile)).flatMap { try? dec.decode([AutomationTask].self, from: $0) }
            ?? (try? Data(contentsOf: backupFile)).flatMap { try? dec.decode([AutomationTask].self, from: $0) }
        guard var t = decoded else { return }
        let now = Date()
        for i in t.indices {
            // A persisted "running" run means the app died mid-run.
            for j in t[i].runs.indices where t[i].runs[j].status == .running {
                t[i].runs[j].status = .error
                t[i].runs[j].message = "interrupted: app quit mid-run"
            }
            if t[i].nextFire == nil {
                t[i].nextFire = t[i].schedule.nextFire()
                if case .once = t[i].schedule, t[i].nextFire == nil { t[i].enabled = false }
            } else if case .interval(let interval) = t[i].schedule, interval > 0 {
                // Preserve phase: advance the stored fire time by whole
                // intervals instead of restarting the cadence at load time.
                var next = t[i].nextFire!
                if next <= now {
                    let span = TimeInterval(interval)
                    let steps = floor(now.timeIntervalSince(next) / span) + 1
                    next = next.addingTimeInterval(steps * span)
                }
                t[i].nextFire = next
            }
        }
        _tasks = t
    }

    private func persist() {
        io.async {
            // Snapshot on the serial queue, not the caller's thread: two
            // callers on different threads could otherwise enqueue their
            // snapshots out of order and land the older list last.
            let snapshot = self.tasks
            guard let d = try? self.enc.encode(snapshot) else { return }
            // Only back up a file that still decodes. If the live file is
            // corrupt (crash mid-write, disk error), copying it over .bak
            // would destroy the last good copy — exactly the one load() falls
            // back to. Leave the existing backup alone in that case.
            if let existing = try? Data(contentsOf: Settings.tasksFile),
               (try? self.dec.decode([AutomationTask].self, from: existing)) != nil {
                try? existing.write(to: self.backupFile, options: .atomic)
            }
            try? d.write(to: Settings.tasksFile, options: .atomic)
        }
    }

    @discardableResult
    func add(title: String, prompt: String, workspace: String, schedule: Schedule) throws -> AutomationTask {
        // One `now` for both checks: validating and then computing nextFire
        // against two different instants let a near-future `.once` pass
        // validation and produce a nil nextFire.
        let now = Date()
        guard schedule.isValid(at: now),
              let next = schedule.nextFire(after: now) else {
            throw ToolError.failed("invalid schedule: \(schedule.summary)")
        }
        var t = AutomationTask(title: title, prompt: prompt, workspace: workspace, schedule: schedule)
        t.nextFire = next
        mutate { $0.append(t) }; persist(); onChange()
        return t
    }

    /// Block until pending persists land. Tests (and teardown) call this
    /// after add/remove: persist() is async, so a fast exit would otherwise
    /// leave automations.json stale.
    func flush() { io.sync {} }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let removed = mutateRet { list -> Bool in
            let count = list.count
            list.removeAll { $0.id == id }
            return count != list.count
        }
        _ = mutateRet { _ in claimedIDs.remove(id) }
        guard removed else { return false }
        persist(); onChange()
        return true
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        mutate { list in
            if let i = list.firstIndex(where: { $0.id == id }) {
                let next = on ? list[i].schedule.nextFire() : nil
                list[i].enabled = on && next != nil
                list[i].nextFire = next
            }
        }
        if !on { _ = mutateRet { _ in claimedIDs.remove(id) } }
        persist(); onChange()
    }

    private func tick() {
        let now = Date()
        // Atomically claim each due task under the lock: two queued ticks can
        // never dispatch the same fire. fire() releases the claim if the run
        // cannot start so a not-ready task is retried rather than lost.
        let due = mutateRet { list -> [AutomationTask] in
            var out: [AutomationTask] = []
            for t in list {
                guard t.enabled, !claimedIDs.contains(t.id),
                      let nf = t.nextFire, nf <= now else { continue }
                claimedIDs.insert(t.id)
                out.append(t)
            }
            return out
        }
        for t in due {
            DispatchQueue.main.async { [weak self] in self?.fire(t) }
        }
        if !due.isEmpty { onChange() }
    }

    private func isClaimed(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return claimedIDs.contains(id)
    }

    private func fire(_ task: AutomationTask) {
        // Revalidate: the task may have been deleted/disabled/unclaimed since
        // the tick snapshot.
        guard let current = tasks.first(where: { $0.id == task.id }),
              current.enabled, isClaimed(task.id) else { return }
        // Overlap policy: skip. A run still in flight (slow agent, short
        // interval) means this fire is dropped and the task advances to its
        // next slot, so runs never stack up in the same workspace.
        if current.runs.last?.status == .running {
            mutate { list in
                if let i = list.firstIndex(where: { $0.id == task.id }) {
                    list[i].nextFire = list[i].schedule.nextFire(after: Date())
                }
            }
            _ = mutateRet { _ in claimedIDs.remove(task.id) }
            persist(); onChange()
            return
        }
        guard let sessionID = runTask?(current) else {
            // Dispatch could not start (model catalog not ready, no API
            // key). Back off instead of re-firing on every 15s tick until
            // the process exits; the task still runs once things recover.
            mutate { list in
                if let i = list.firstIndex(where: { $0.id == task.id }) {
                    list[i].nextFire = Date().addingTimeInterval(300)
                }
            }
            _ = mutateRet { _ in claimedIDs.remove(task.id) }
            persist()
            return
        }
        mutate { list in
            if let i = list.firstIndex(where: { $0.id == task.id }) {
                if case .once = list[i].schedule {
                    list[i].enabled = false
                    list[i].nextFire = nil
                } else {
                    list[i].nextFire = list[i].schedule.nextFire(after: Date())
                }
                list[i].runs.append(TaskRun(sessionID: sessionID, status: .running))
                if list[i].runs.count > 50 { list[i].runs.removeFirst(list[i].runs.count - 50) }
            }
        }
        _ = mutateRet { _ in claimedIDs.remove(task.id) }
        persist(); onChange()
    }

    func recordResult(taskID: UUID, sessionID: UUID, error: String?) {
        mutate { list in
            if let i = list.firstIndex(where: { $0.id == taskID }),
               let j = list[i].runs.lastIndex(where: { $0.sessionID == sessionID }) {
                list[i].runs[j].status = error == nil ? .ok : .error
                list[i].runs[j].message = error
            }
        }
        persist(); onChange()
    }
}
