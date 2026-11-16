import Foundation
import Security

// MARK: - Keychain

enum Keychain {
    static func get(_ key: String) -> String? { lookup(key).0 }
    /// Like `get`, but keeps the status, so callers can tell "no item yet"
    /// (errSecItemNotFound) from "access denied or Keychain locked".
    static func lookup(_ key: String) -> (String?, OSStatus) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "dsh-proper",
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &item)
        guard st == errSecSuccess else { return (nil, st) }
        guard let d = item as? Data else { return (nil, errSecDecode) }
        return (String(data: d, encoding: .utf8), st)
    }
    /// Returns the Security framework status so callers can surface a
    /// failed write instead of silently losing the secret. A delete of an
    /// absent item counts as success.
    @discardableResult
    static func set(_ key: String, _ value: String) -> OSStatus {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "dsh-proper",
                                kSecAttrAccount as String: key]
        guard let data = value.data(using: .utf8) else { return errSecParam }
        if value.isEmpty {
            let st = SecItemDelete(q as CFDictionary)
            if st != errSecSuccess && st != errSecItemNotFound { NSLog("Keychain delete failed: %d", st) }
            return st == errSecItemNotFound ? errSecSuccess : st
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let st = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if st == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            // Explicit on new items; the search query stays attribute-free so
            // items created by earlier versions still match for update/delete.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addSt = SecItemAdd(add as CFDictionary, nil)
            if addSt != errSecSuccess { NSLog("Keychain add failed: %d", addSt); return addSt }
            return errSecSuccess
        }
        if st != errSecSuccess { NSLog("Keychain update failed: %d", st) }
        return st
    }
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...360
    static let inspectorWidthRange: ClosedRange<CGFloat> = 240...400
    /// XCTest runs must never touch the real Keychain, defaults, or home dir.
    static var isTestRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    /// Default workspace: strictly inside the home directory but never the
    /// home directory itself — defaulting to $HOME would make the file tools'
    /// "confined to the workspace" model no confinement at all.
    static var defaultWorkspaceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dsh-workspace")
    }
    private let d = UserDefaults.standard
    private var previewModel = ""

    var sidebarWidth: CGFloat {
        get { paneWidth("sidebarWidth", default: 264, range: Self.sidebarWidthRange) }
        set { setPaneWidth(newValue, key: "sidebarWidth", range: Self.sidebarWidthRange) }
    }
    var inspectorWidth: CGFloat {
        get { paneWidth("inspectorWidth", default: 300, range: Self.inspectorWidthRange) }
        set { setPaneWidth(newValue, key: "inspectorWidth", range: Self.inspectorWidthRange) }
    }
    private func paneWidth(_ key: String, default value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard !Preview.enabled else { return value }
        let saved = d.double(forKey: key)
        guard saved.isFinite, saved > 0 else { return value }
        return min(range.upperBound, max(range.lowerBound, CGFloat(saved)))
    }
    private func setPaneWidth(_ value: CGFloat, key: String, range: ClosedRange<CGFloat>) {
        guard !Preview.enabled, value.isFinite else { return }
        d.set(Double(min(range.upperBound, max(range.lowerBound, value))), forKey: key)
    }

    /// Last Keychain write failure, surfaced in Settings → Models & API.
    private(set) var keychainError: String?

    var apiKey: String {
        get {
            if Preview.enabled { return "preview-key-not-a-secret" }
            if Self.isTestRun { return "" } // never read the real Keychain from tests
            return Keychain.get("deepseek_api_key") ?? ""
        }
        set {
            guard !Preview.enabled && !Self.isTestRun else { return }
            let st = Keychain.set("deepseek_api_key", newValue)
            keychainError = st == errSecSuccess ? nil
                : "Keychain error \(st): the API key may not have been saved."
        }
    }
    var baseURL: String {
        get {
            if Preview.enabled { return "https://preview.harness.invalid/v1" }
            if Self.isTestRun { return "https://api.deepseek.com" }
            return d.string(forKey: "baseURL") ?? "https://api.deepseek.com"
        }
        set { if !Preview.enabled && !Self.isTestRun { d.set(newValue, forKey: "baseURL") } }
    }
    var model: String {
        get { Preview.enabled ? previewModel : d.string(forKey: "model") ?? "" }
        set { if Preview.enabled { previewModel = newValue } else { d.set(newValue, forKey: "model") } }
    }
    var agentProfile: String { // standard | minimal | ptc | cordis (upstream dsh presets)
        get {
            let v = d.string(forKey: "agentProfile") ?? "standard"
            return AgentProfiles.all.contains(where: { $0.id == v }) ? v : "standard"
        }
        set { d.set(newValue, forKey: "agentProfile") }
    }
    var autonomy: Autonomy {
        get { Autonomy(rawValue: d.string(forKey: "autonomy") ?? "autoRead") ?? .autoRead }
        set { d.set(newValue.rawValue, forKey: "autonomy") }
    }
    var workspace: String {
        get {
            if Preview.enabled || Self.isTestRun { return FileManager.default.currentDirectoryPath }
            if let saved = d.string(forKey: "workspace"), !saved.isEmpty { return saved }
            // Fresh install: a dedicated folder, not the whole home directory.
            try? FileManager.default.createDirectory(at: Self.defaultWorkspaceURL, withIntermediateDirectories: true)
            return Self.defaultWorkspaceURL.path
        }
        set { if !Preview.enabled && !Self.isTestRun { d.set(newValue, forKey: "workspace") } }
    }
    var appearance: String { // "System" | "Light" | "Dark"
        get { d.string(forKey: "appearance") ?? "System" }
        set { d.set(newValue, forKey: "appearance") }
    }
    /// Explicit isolation for tests and probes: when set, all support state
    /// (plugins, sessions, automations) lives here instead of the real
    /// Application Support dir, regardless of the XCTest environment probe.
    static var supportDirOverride: URL? = nil
    static var supportDir: URL {
        if let o = supportDirOverride {
            try? FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
            return o
        }
        // Preview fixtures and tests never touch real plugins, sessions, or automations.
        if Preview.enabled || Self.isTestRun {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HarnessPreview-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // A sandbox or a misconfigured image can omit the Application Support
        // URL; trapping at launch is worse than degrading to a temp dir.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("dsh-proper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var pluginsDir: URL {
        let dir = supportDir.appendingPathComponent("plugins")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var sessionsDir: URL {
        let dir = supportDir.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var tasksFile: URL { supportDir.appendingPathComponent("automations.json") }
}

// MARK: - SessionStore

final class SessionStore {
    static let shared = SessionStore()
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()
    /// All disk I/O happens on this serial queue; `sessions` mutations are
    /// additionally serialized by `sessionsLock` since callers are not
    /// confined to the main thread.
    private let io = DispatchQueue(label: "dsh.store.io", qos: .utility)
    private var pending: [UUID: Session] = [:]
    private var pendingIndexOrder: [UUID]? = nil
    private var saveScheduled = false
    private var flushFailures = 0
    /// Session array access is lock-guarded: UI reads on the main thread
    /// while automation/test paths can touch the store from elsewhere.
    /// The getter returns a snapshot (COW makes reads cheap).
    private var _sessions: [Session] = []
    private let sessionsLock = NSLock()
    var sessions: [Session] {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        return _sessions
    }
    private func updateSessions(_ body: (inout [Session]) -> Void) {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        body(&_sessions)
    }
    private func updateSessionsRet<T>(_ body: (inout [Session]) -> T) -> T {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        return body(&_sessions)
    }

    /// Sessions found on disk that can't be decrypted right now, with the
    /// reason. Their files are left untouched; the UI tells the user.
    var undecryptable: [UUID: String] {
        flagsLock.lock(); defer { flagsLock.unlock() }
        return _undecryptable
    }
    private var _undecryptable: [UUID: String] = [:]
    /// Sessions loaded from pre-encryption plaintext files; re-saved
    /// (encrypted) right after launch.
    private var legacyIDs = Set<UUID>()
    private let flagsLock = NSLock()

    private init() {
        enc.dateEncodingStrategy = .iso8601; dec.dateDecodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        loadIndex()
        // Encrypt plaintext sessions from older versions now, instead of
        // leaving them readable until each is next edited.
        flagsLock.lock(); let legacy = legacyIDs; legacyIDs.removeAll(); flagsLock.unlock()
        for s in sessions where legacy.contains(s.id) { save(s) }
    }

    private var indexFile: URL { Settings.sessionsDir.appendingPathComponent("index.json") }

    private func report(_ msg: String) {
        NSLog("SessionStore: %@", msg)
    }

    private func loadIndex() {
        // Sessions stored one file each; index keeps order + titles for the sidebar.
        var loaded: [Session] = []
        var seen = Set<UUID>()
        if let data = try? Data(contentsOf: indexFile),
           let order = try? dec.decode([UUID].self, from: data) {
            for id in order {
                if let s = load(id) { loaded.append(s); seen.insert(id) }
            }
        }
        // pick up orphan files not in index
        if let files = try? FileManager.default.contentsOfDirectory(atPath: Settings.sessionsDir.path) {
            for f in files where f.hasSuffix(".json") && f != "index.json" {
                let idStr = String(f.dropLast(5))
                if let id = UUID(uuidString: idStr), !seen.contains(id),
                   let s = load(id) { loaded.append(s) }
            }
        }
        _sessions = loaded.sorted { $0.updated > $1.updated }
    }

    private func file(_ id: UUID) -> URL { Settings.sessionsDir.appendingPathComponent("\(id.uuidString).json") }

    /// Moves an undecodable session file out of the scan path so it stops
    /// masquerading as a missing session, and reports it.
    private func quarantine(_ u: URL, _ id: UUID?) {
        let qdir = Settings.sessionsDir.appendingPathComponent("quarantine")
        try? FileManager.default.createDirectory(at: qdir, withIntermediateDirectories: true)
        let name = (id?.uuidString ?? u.deletingPathExtension().lastPathComponent) + "-\(Int(Date().timeIntervalSince1970)).json"
        let dest = qdir.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: u, to: dest)
            report("quarantined corrupt session file \(u.lastPathComponent) -> quarantine/\(name)")
        } catch {
            report("could not quarantine corrupt session \(u.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func load(_ id: UUID) -> Session? {
        let u = file(id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        guard let raw = try? Data(contentsOf: u) else {
            report("session \(id) unreadable; quarantined")
            quarantine(u, id)
            return nil
        }
        let data: Data
        var legacy = false
        switch SessionCipher.open(raw) {
        case .decrypted(let d):
            data = d
        case .legacyPlaintext(let d):
            data = d; legacy = true
        case .undecryptable(let reason):
            // Not corrupt: leave the file where it is so it can be opened
            // once the key is available again.
            report("session \(id) can't be decrypted: \(reason); left in place")
            flagsLock.lock(); _undecryptable[id] = reason; flagsLock.unlock()
            return nil
        }
        do {
            let s = try dec.decode(Session.self, from: data)
            flagsLock.lock()
            _undecryptable[id] = nil
            if legacy { legacyIDs.insert(id) }
            flagsLock.unlock()
            return s
        }
        catch {
            report("session \(id) is corrupt (\(error.localizedDescription)); quarantined")
            quarantine(u, id)
            return nil
        }
    }

    func save(_ s: Session) {
        // A stale save for a deleted session must not resurrect its file
        // (loadIndex re-imports orphan files). Callers insert before saving.
        let (tracked, order) = updateSessionsRet { list -> (Bool, [UUID]) in
            let tracked = list.contains { $0.id == s.id }
            return (tracked, tracked ? list.map { $0.id } : [])
        }
        guard tracked else { return }
        var copy = s; copy.running = false
        io.async {
            self.pending[s.id] = copy
            self.pendingIndexOrder = order
            self.scheduleFlushLocked()
        }
    }

    /// Coalesces rapid saves: at most one write per 0.5s per store.
    private func scheduleFlushLocked() {
        guard !saveScheduled else { return }
        saveScheduled = true
        io.asyncAfter(deadline: .now() + 0.5) { self.flushPending() }
    }

    /// Must run on `io`.
    private func flushPending() {
        saveScheduled = false
        let batch = pending; pending.removeAll()
        let order = pendingIndexOrder; pendingIndexOrder = nil
        var failed: [UUID: Session] = [:]
        for (id, s) in batch {
            do {
                // Never falls back to plaintext: if the key is unavailable
                // the write fails and stays queued for retry.
                try SessionCipher.seal(enc.encode(s)).write(to: file(id), options: .atomic)
            } catch {
                failed[id] = s
                report("session \(id) save failed: \(error.localizedDescription)")
            }
        }
        if !failed.isEmpty {
            pending.merge(failed) { _, latest in latest }
            pendingIndexOrder = order
            flushFailures += 1
            // Bounded retry: a persistently failing disk (full, read-only)
            // must not spin a write attempt every 0.5s forever. Pending
            // writes stay queued and the next save() reschedules a flush.
            if flushFailures <= 3 {
                scheduleFlushLocked()
            } else {
                report("session writes still failing after \(flushFailures) attempts; retrying on next save")
            }
            return
        }
        flushFailures = 0
        if let order {
            do {
                try enc.encode(order).write(to: indexFile, options: .atomic)
            } catch {
                pendingIndexOrder = order
                report("session index save failed: \(error.localizedDescription)")
                scheduleFlushLocked()
            }
        }
    }

    /// Synchronously persist all pending writes. Call on quit/teardown.
    func flush() {
        io.sync { self.flushPending() }
    }

    func newSession(workspace: String) -> Session {
        var s = Session(title: "New session", workspace: workspace, model: Settings.shared.model)
        s.systemPromptInit()
        updateSessions { $0.insert(s, at: 0) }
        save(s)
        return s
    }

    /// Persist a session that has been held only in memory (a fresh blank
    /// from ⌘N) once it sees activity. No-op if already tracked.
    func adopt(_ s: Session) {
        updateSessions {
            if !$0.contains(where: { $0.id == s.id }) {
                $0.insert(s, at: 0)
            }
        }
        save(s)
    }

    func delete(_ id: UUID) {
        let order = updateSessionsRet { list -> [UUID] in
            list.removeAll { $0.id == id }
            return list.map { $0.id }
        }
        io.async {
            // Drop any queued save first: it would otherwise resurrect the file.
            self.pending.removeValue(forKey: id)
            self.pendingIndexOrder = order
            self.scheduleFlushLocked()
            do { try FileManager.default.removeItem(at: self.file(id)) }
            catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileNoSuchFileError {}
            catch { self.report("session delete failed: \(error.localizedDescription)") }
        }
    }

    func touch(_ s: Session) {
        updateSessions { list in
            if let i = list.firstIndex(where: { $0.id == s.id }) {
                list[i] = s
                list.sort { $0.updated > $1.updated }
            }
        }
        save(s)
    }
}

extension Session {
    mutating func systemPromptInit() {
        systemPromptInit(model: Settings.shared.model)
    }
    /// System prompt from the active upstream agent profile (standard,
    /// minimal, ptc, cordis). The persona prefix is the profile's verbatim
    /// text with {{model}} substituted; a `complete` persona (minimal) is
    /// the whole prompt, otherwise native workspace/guideline context plus
    /// the profile's skill budget follow.
    mutating func systemPromptInit(model: String) {
        let ws = workspace
        let profile = AgentProfiles.profile(id: Settings.shared.agentProfile)
        let persona = profile.personaPrefix.replacingOccurrences(
            of: "{{model}}", with: model.isEmpty ? "unknown model" : model)
        if profile.personaComplete {
            wire = [WireMessage(role: .system, content: persona)]
            return
        }
        var skills = PluginEngine.shared.skillBlocks()
        // instructionsMaxBytes is a byte budget, not a character count.
        if let cap = profile.instructionsMaxBytes, skills.utf8.count > cap {
            skills = String(decoding: skills.utf8.prefix(cap), as: UTF8.self)
        }
        var lines = [persona, "", "Workspace: \(ws)"]
        if profile.hasTimeContext {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            lines += ["", "Current time: \(f.string(from: Date()))"]
        }
        lines += ["",
            "Capabilities: \(AgentProfiles.capabilitySummary(profile)).",
            "File changes you make appear in the user's Review pane automatically.",
            "",
            "Guidelines:",
            "- Prefer tools over prose. Verify claims by running commands.",
            "- Keep answers tight. When you modify code, run the build/tests."]
        if !skills.isEmpty { lines += ["", skills] }
        wire = [WireMessage(role: .system, content: lines.joined(separator: "\n"))]
    }
}
