import Foundation
import JavaScriptCore

// JavaScriptCore has no public interrupt API, but the framework exports an
// execution-time limit that terminates a runaway script and lets the queue
// continue. Without it a plugin's `while(true){}` wedges its serial queue for
// the life of the process: kill() can only mark the runtime dead, because
// evaluateScript never returns.
//
// This is an unsupported symbol. It is resolved with dlsym rather than linked
// by name, so a JavaScriptCore build without it degrades to "no limit" (and
// the PluginEngine load watchdog) instead of failing to launch.
private typealias JSShouldTerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
private typealias SetExecutionTimeLimitFn = @convention(c) (JSContextGroupRef?, Double,
                                                           JSShouldTerminateCallback?, UnsafeMutableRawPointer?) -> Void

private let setExecutionTimeLimit: SetExecutionTimeLimitFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
          let sym = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(sym, to: SetExecutionTimeLimitFn.self)
}()

// MARK: - JSRuntime: one JSVirtualMachine per JS plugin on a serial queue

final class JSRuntime: @unchecked Sendable { // all JS state is touched only on its serial queue
    let pluginID: String
    let dir: URL
    let queue = DispatchQueue(label: "dsh.plugin.js", qos: .utility)
    private var vm: JSVirtualMachine?
    private var ctx: JSContext?
    private let gate = NSLock()
    private var _disposed = false
    private var _startDone = false
    weak var engine: PluginEngine?
    /// Exception text captured by the context handler during a tool call.
    /// Touched only on the plugin's serial queue (handler, start, invokeTool).
    private var pendingException: String?
    /// True while start() is evaluating the plugin's own source, so the
    /// exception handler can tell a load failure from a tool-call failure.
    /// Touched only on the plugin's serial queue.
    private var loading = true

    var disposed: Bool { gate.lock(); defer { gate.unlock() }; return _disposed }
    var startCompleted: Bool { gate.lock(); defer { gate.unlock() }; return _startDone }

    init(pluginID: String, dir: URL, engine: PluginEngine) {
        self.pluginID = pluginID; self.dir = dir; self.engine = engine
    }

    func dispose() {
        // Async: dispose may be requested while the plugin queue is busy (or
        // from it); a sync hop here deadlocks behind a running handler.
        kill()
    }

    /// Mark dead from any thread. JSC exposes no interrupt API, so a running
    /// evaluateScript cannot be stopped; the VM is abandoned and every
    /// subsequent operation gates on `disposed`.
    func kill() {
        gate.lock(); _disposed = true; gate.unlock()
        queue.async { [weak self] in self?.ctx = nil; self?.vm = nil }
    }

    private var acceptsCallbacks: Bool {
        !disposed && (engine?.isCurrent(self) ?? false)
    }

    private var stateFile: URL { dir.appendingPathComponent("state.json") }

    private func storeLoad() -> [String: String] {
        guard let d = try? Data(contentsOf: stateFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }
    private func storeSave(_ o: [String: String]) {
        try? JSON.compact(o).write(to: stateFile, atomically: true, encoding: .utf8)
    }

    func start(source: String, entryPath: String) {
        guard !disposed else { return }
        defer {
            gate.lock(); _startDone = true; gate.unlock()
            engine?.runtimeDidChange(self)
        }
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else { return }
        self.vm = vm; self.ctx = ctx
        let pid = pluginID, dir = self.dir
        let isActive: () -> Bool = { [weak self] in self?.acceptsCallbacks ?? false }
        // Bound every script this VM runs: a plugin's infinite loop must not
        // hold its queue forever. The callback returning true terminates the
        // script with a "JavaScript execution terminated" exception, which the
        // load path below reports as a broken plugin.
        if let setLimit = setExecutionTimeLimit,
           let group = ctx.jsGlobalContextRef.map({ JSContextGetGroup($0) }) {
            setLimit(group, 20, { _, _ in true }, nil)
        }

        // Load-time exceptions only. A tool handler that throws (ENOENT from
        // fs.readFileSync, a validation error) is a normal tool failure and
        // must not disable the plugin; invokeTool reports it to the model
        // instead. The handler always runs (it also catches async timer
        // exceptions), but only marks the plugin broken while start() is
        // evaluating the plugin's own source.
        ctx.exceptionHandler = { [weak self] _, ex in
            guard let self else { return }
            let message = ex?.toString() ?? "exception"
            if self.loading {
                guard self.acceptsCallbacks else { return }
                self.engine?.markBroken(pid, "JS: \(message)", runtime: self)
            } else {
                self.pendingException = message
            }
        }

        // ---- native bridges ----
        // Paths that escape the plugin dir resolve to nil: reads miss,
        // writes/deletes fail, and the plugin root itself can never be
        // deleted through the bridge.
        let fsRead: @convention(block) (String) -> String? = { path in
            guard isActive() else { return nil }
            guard let p = Self.resolve(path, in: dir) else { return nil }
            return try? String(contentsOfFile: p.path, encoding: .utf8)
        }
        let fsReadBin: @convention(block) (String) -> String? = { path in
            guard isActive() else { return nil }
            guard let p = Self.resolve(path, in: dir) else { return nil }
            return FileManager.default.contents(atPath: p.path)?.base64EncodedString()
        }
        let fsWrite: @convention(block) (String, String) -> Bool = { path, content in
            guard isActive() else { return false }
            guard let p = Self.resolve(path, in: dir) else { return false }
            try? FileManager.default.createDirectory(atPath: p.deletingLastPathComponent().path, withIntermediateDirectories: true)
            do { try content.write(to: p, atomically: true, encoding: .utf8); return true }
            catch { return false }
        }
        let fsExists: @convention(block) (String) -> Bool = { path in
            guard isActive() else { return false }
            guard let p = Self.resolve(path, in: dir) else { return false }
            return FileManager.default.fileExists(atPath: p.path)
        }
        let fsList: @convention(block) (String) -> [String] = { path in
            guard isActive() else { return [] }
            guard let p = Self.resolve(path, in: dir) else { return [] }
            return (try? FileManager.default.contentsOfDirectory(atPath: p.path)) ?? []
        }
        let fsMkdir: @convention(block) (String) -> Bool = { path in
            guard isActive() else { return false }
            guard let p = Self.resolve(path, in: dir) else { return false }
            return (try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)) != nil
        }
        let fsDelete: @convention(block) (String) -> Bool = { path in
            guard isActive() else { return false }
            guard let p = Self.resolve(path, in: dir), p.path != dir.path else { return false }
            return (try? FileManager.default.removeItem(at: p)) != nil
        }
        let fsIsDirectory: @convention(block) (String) -> Bool = { path in
            guard isActive(), let p = Self.resolve(path, in: dir) else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: p.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        // Returns (output, denied). A denial is reported to JS as a thrown
        // error rather than an empty string, so a plugin (and the model reading
        // its tool result) can tell "permission denied" from "printed nothing".
        let exec: @convention(block) (String, NSNumber) -> NSArray = { cmd, timeout in
            guard isActive() else { return ["", false] }
            // Plugin shell follows the same approval rule as the bash tool:
            // it runs only when the autonomy level needs no approval for
            // shell (Full autonomy). Enabling a plugin is a trust action,
            // but it does not by itself grant shell access.
            guard !Tools.category(.shell, needsApproval: Settings.shared.autonomy) else {
                NSLog("[plugin:%@] shell denied: Tool permissions require approval for shell", pid)
                return ["", true]
            }
            // Callers pass Node-style milliseconds; runSync takes seconds.
            let out = (try? Shell.runSync(cmd, cwd: dir.path, timeout: timeout.doubleValue / 1000)) ?? ""
            return [out, false]
        }
        let logFn: @convention(block) (String) -> Void = { msg in
            guard isActive() else { return }
            NSLog("[plugin:%@] %@", pid, msg)
        }
        let regTool: @convention(block) (String) -> Void = { [weak self] spec in
            guard isActive(), let engine = self?.engine else { return }
            engine.registerTool(pluginID: pid, specJSON: spec)
        }
        let regCmd: @convention(block) (String, String) -> Void = { [weak self] n, t in
            guard isActive(), let engine = self?.engine else { return }
            engine.registerCommand(pluginID: pid, name: n, template: t)
        }
        let regSkill: @convention(block) (String, String) -> Void = { [weak self] n, md in
            guard isActive(), let engine = self?.engine else { return }
            engine.registerSkill(pluginID: pid, name: n, markdown: md)
        }
        let storeGet: @convention(block) (String) -> String? = { [weak self] k in
            guard let self, isActive() else { return nil }
            return self.storeLoad()[k]
        }
        let storeSet: @convention(block) (String, String) -> Void = { [weak self] k, v in
            guard let self, isActive() else { return }
            var o = self.storeLoad(); o[k] = v; self.storeSave(o)
        }
        let configJSON: @convention(block) () -> String = {
            guard isActive() else { return "{}" }
            let u = dir.appendingPathComponent("plugin.json")
            let m = (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return JSON.compact(m?["config"] ?? [:])
        }
        let setTimer: @convention(block) (NSNumber, NSNumber) -> NSNumber = { [weak self] cbID, ms in
            guard let self, isActive(), ms.doubleValue.isFinite else { return 0 }
            let delay = min(max(ms.doubleValue / 1000, 0), 86_400)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, isActive() else { return }
                self.ctx?.evaluateScript("__dshFireTimer(\(cbID.intValue))")
            }
            return 1
        }

        ctx.setObject(fsRead, forKeyedSubscript: "__fsRead" as NSString)
        ctx.setObject(fsReadBin, forKeyedSubscript: "__fsReadBin" as NSString)
        ctx.setObject(fsWrite, forKeyedSubscript: "__fsWrite" as NSString)
        ctx.setObject(fsExists, forKeyedSubscript: "__fsExists" as NSString)
        ctx.setObject(fsList, forKeyedSubscript: "__fsList" as NSString)
        ctx.setObject(fsMkdir, forKeyedSubscript: "__fsMkdir" as NSString)
        ctx.setObject(fsDelete, forKeyedSubscript: "__fsDelete" as NSString)
        ctx.setObject(fsIsDirectory, forKeyedSubscript: "__fsIsDirectory" as NSString)
        ctx.setObject(exec, forKeyedSubscript: "__exec" as NSString)
        ctx.setObject(logFn, forKeyedSubscript: "__log" as NSString)
        ctx.setObject(regTool, forKeyedSubscript: "__registerTool" as NSString)
        ctx.setObject(regCmd, forKeyedSubscript: "__registerCommand" as NSString)
        ctx.setObject(regSkill, forKeyedSubscript: "__registerSkill" as NSString)
        ctx.setObject(storeGet, forKeyedSubscript: "__storeGet" as NSString)
        ctx.setObject(storeSet, forKeyedSubscript: "__storeSet" as NSString)
        ctx.setObject(configJSON, forKeyedSubscript: "__configJSON" as NSString)
        ctx.setObject(setTimer, forKeyedSubscript: "__setTimer" as NSString)
        ctx.setObject(dir.path, forKeyedSubscript: "__pluginDir" as NSString)
        ctx.setObject(entryPath, forKeyedSubscript: "__entryPath" as NSString)

        ctx.evaluateScript(Self.prelude)
        ctx.evaluateScript(source)
        if !disposed { ctx.evaluateScript("__dshApply()") }
        self.loading = false
    }

    /// Plugin filesystem is confined to the plugin directory. Escapes resolve
    /// to nil; the plugin root itself is a valid target for reads but is
    /// guarded separately for delete.
    private static func resolve(_ path: String, in dir: URL) -> URL? {
        PluginEngine.confined(dir, path)
    }

    /// Encode a Swift string as a JSON string literal safe to embed in JS source.
    static func jsLiteral(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let out = String(data: d, encoding: .utf8), out.count >= 2 else { return "\"\"" }
        return String(out.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Invoke a registered JS tool handler. Runs on the plugin's queue with a
    /// timeout: JSC cannot interrupt a running script, so on timeout the
    /// runtime is killed (abandoned) and the caller gets an error rather than
    /// hanging on a wedged serial queue forever.
    func invokeTool(name: String, args: String) async throws -> String {
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let ctx = self.ctx, !self.disposed else {
                    if once.claim() { cont.resume(throwing: ToolError.failed("plugin \(self.pluginID) not running")) }
                    return
                }
                self.pendingException = nil
                let v = ctx.evaluateScript("__dshInvoke(\(Self.jsLiteral(name)), \(Self.jsLiteral(args)))")
                let result: Result<String, Error>
                // The exceptionHandler consumes ctx.exception, so the thrown
                // text arrives through pendingException; ctx.exception is the
                // fallback for the no-handler case.
                let thrown = self.pendingException ?? ctx.exception?.toString()
                self.pendingException = nil
                ctx.exception = nil
                if let thrown { result = .failure(ToolError.failed(thrown)) }
                else { result = .success(v?.toString() ?? "") }
                if once.claim() { cont.resume(with: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                if once.claim() {
                    self.engine?.markBroken(self.pluginID, "tool \(name) timed out", runtime: self)
                    self.kill()
                    cont.resume(throwing: ToolError.failed("plugin \(self.pluginID) tool \(name) timed out"))
                }
            }
        }
    }

    // MARK: prelude

    /// The cordis-flavored shim: CJS module system, node-builtin polyfills, ctx object.
    static let prelude = """
    var __dshTools = {}, __dshTimers = {};
    var module = { exports: {} };
    var exports = module.exports;
    var console = {
      log: function(){ __log(Array.prototype.map.call(arguments, String).join(' ')); },
      warn: function(){ __log('warn: ' + Array.prototype.map.call(arguments, String).join(' ')); },
      error: function(){ __log('error: ' + Array.prototype.map.call(arguments, String).join(' ')); }
    };
    var process = { env: {}, cwd: function(){ return __pluginDir; }, argv: ['dsh-plugin'] };

    function __pathJoin(){
      var parts = Array.prototype.slice.call(arguments).filter(function(p){ return p && p.length; });
      var out = parts.join('/').replace(/\\/+/g, '/');
      var abs = out.charAt(0) === '/';
      var segs = out.split('/'); var stack = [];
      for (var i=0;i<segs.length;i++){ var s=segs[i];
        if (!s || s==='.') continue;
        if (s==='..') { if (stack.length && stack[stack.length-1]!=='..') stack.pop(); else if(!abs) stack.push('..'); }
        else stack.push(s);
      }
      return (abs?'/':'') + stack.join('/') || (abs?'/':'.');
    }
    var path = {
      join: __pathJoin,
      resolve: function(){ var a = Array.prototype.slice.call(arguments); a.unshift(process.cwd()); return __pathJoin.apply(null, a); },
      dirname: function(p){ var i = p.lastIndexOf('/'); return i <= 0 ? (p.charAt(0)==='/'?'/':'.') : p.substring(0,i); },
      basename: function(p, ext){ var b = p.substring(p.lastIndexOf('/')+1); if (ext && b.slice(-ext.length)===ext) b = b.slice(0,-ext.length); return b; },
      extname: function(p){ var b = p.substring(p.lastIndexOf('/')+1); var i = b.lastIndexOf('.'); return i>0 ? b.slice(i) : ''; },
      isAbsolute: function(p){ return p.charAt(0)==='/'; },
      normalize: __pathJoin
    };

    var fs = {
      readFileSync: function(p, enc){ var b = __fsReadBin(p); if (enc==='base64') return b||'';
        var t = __fsRead(p); if (t===null) throw new Error('ENOENT: '+p); return t; },
      writeFileSync: function(p, c){ if(!__fsWrite(p, String(c))) throw new Error('write failed: '+p); },
      appendFileSync: function(p, c){ var t = __fsRead(p)||''; if(!__fsWrite(p, t+String(c))) throw new Error('append failed'); },
      existsSync: function(p){ return !!__fsExists(p); },
      readdirSync: function(p){ return __fsList(p); },
      mkdirSync: function(p, o){ if(!__fsMkdir(p)) throw new Error('mkdir failed: '+p); },
      unlinkSync: function(p){ if(!__fsDelete(p)) throw new Error('unlink failed: '+p); },
      rmSync: function(p, o){ if(!__fsDelete(p)) throw new Error('rm failed: '+p); },
      statSync: function(p){ if(!__fsExists(p)) throw new Error('ENOENT: '+p);
        var directory = !!__fsIsDirectory(p);
        return { isDirectory: function(){ return directory; }, isFile: function(){ return !directory; } }; }
    };
    var os = { homedir: function(){ return __pluginDir; }, tmpdir: function(){ return '/tmp'; },
      platform: function(){ return 'darwin'; }, arch: function(){ return 'arm64'; }, EOL: '\\n' };
    // __exec returns [output, denied]; a denial must not look like empty output.
    function __execChecked(cmd, timeout){
      var r = __exec(cmd, timeout);
      if (r[1]) throw new Error('EACCES: shell access denied by tool permissions');
      return r[0];
    }
    var child_process = {
      execSync: function(cmd, o){ var t = (o && o.timeout) || 60000; return __execChecked(cmd, t); }
    };

    var __requireCache = {};
    function __loadFile(p){
      var src = __fsRead(p);
      if (src === null) return null;
      var m = { exports: {} };
      var fn = new Function('module','exports','require','__filename','__dirname',
        src + '\\n//# sourceURL=' + p);
      fn(m, m.exports, function(n){ return require.call({dir:path.dirname(p)}, n); }, p, path.dirname(p));
      return m.exports;
    }
    function require(name){
      if (name==='fs') return fs; if (name==='path') return path; if (name==='os') return os;
      if (name==='child_process') return child_process; if (name==='process') return process;
      var base = (this && this.dir) || __pluginDir;
      var tries = [];
      if (name.charAt(0)==='.') {
        tries = [__pathJoin(base,name), __pathJoin(base,name+'.js'), __pathJoin(base,name,'index.js')];
      } else {
        var d = base;
        for (var i=0;i<8;i++){
          tries.push(__pathJoin(d,'node_modules',name,'index.js'));
          tries.push(__pathJoin(d,'node_modules',name+'.js'));
          var pj = __pathJoin(d,'node_modules',name,'package.json');
          var pjSrc = __fsRead(pj);
          if (pjSrc) { try { var main = JSON.parse(pjSrc).main||'index.js';
            tries.push(__pathJoin(d,'node_modules',name,main)); } catch(e){} }
          d = path.dirname(d);
        }
      }
      for (var i=0;i<tries.length;i++){
        var p = tries[i];
        if (__requireCache[p]) return __requireCache[p];
        if (!__fsExists(p)) continue;
        if (p.slice(-5)==='.json') { var j = JSON.parse(__fsRead(p)); __requireCache[p]=j; return j; }
        var out = __loadFile(p);
        if (out !== null) { __requireCache[p]=out; return out; }
      }
      throw new Error('Cannot find module: ' + name);
    }

    function __dshTimerDelay(ms, fallback, repeat){
      var value = Number(ms);
      if (!isFinite(value)) value = fallback;
      return Math.min(Math.max(value, repeat ? 1 : 0), 86400000);
    }
    function __dshSchedule(fn, ms, repeat){
      if (typeof fn !== 'function') throw new TypeError('timer callback must be a function');
      var id = __dshNextTimer();
      var timer = { fn: fn, repeat: repeat, delay: __dshTimerDelay(ms, repeat ? 1000 : 0, repeat) };
      __dshTimers[id] = timer; __setTimer(id, timer.delay); return id;
    }
    function setTimeout(fn, ms){ return __dshSchedule(fn, ms, false); }
    function setInterval(fn, ms){ return __dshSchedule(fn, ms, true); }
    function clearTimeout(id){ delete __dshTimers[id]; }
    function clearInterval(id){ clearTimeout(id); }
    var __dshTimerSeq = 1000;
    function __dshNextTimer(){ return ++__dshTimerSeq; }
    function __dshFireTimer(id){
      var timer = __dshTimers[id]; if (!timer) return;
      if (!timer.repeat) delete __dshTimers[id];
      try { timer.fn(); }
      finally { if (timer.repeat && __dshTimers[id] === timer) __setTimer(id, timer.delay); }
    }

    // ---- cordis-flavored ctx ----
    var ctx = {
      tool: function(spec, fn){ if (typeof spec==='string') spec={name:spec,description:'',parameters:{type:'object',properties:{}}};
        __dshTools[spec.name]=fn; __registerTool(JSON.stringify(spec)); },
      command: function(name, template){ __registerCommand(name, template); },
      skill: function(name, markdown){ __registerSkill(name, markdown); },
      log: function(m){ __log(String(m)); },
      shell: function(cmd, timeout){ return __execChecked(cmd, timeout||60000); },
      store: {
        get: function(k){ var v=__storeGet(k); return v===null||v===undefined?undefined:JSON.parse(v); },
        set: function(k,v){ __storeSet(k, JSON.stringify(v===undefined?null:v)); }
      },
      config: JSON.parse(__configJSON()||'{}'),
      dir: __pluginDir
    };

    function __dshApply(){
      var e = module.exports;
      if (typeof e === 'function') { e(ctx); }
      else if (e && typeof e.apply==='function') { e.apply(ctx); }
      else if (e && e.default && typeof e.default==='function') { e.default(ctx); }
      else if (typeof globalThis.apply==='function') { globalThis.apply(ctx); }
    }
    function __dshInvoke(name, argsJSON){
      var fn = __dshTools[name]; if (!fn) throw new Error('no tool '+name);
      var args = JSON.parse(argsJSON||'{}');
      var out = fn(args, ctx);
      return (out===undefined||out===null)?'':(typeof out==='string'?out:JSON.stringify(out));
    }
    """

    // Synchronous variant for inside-JS shell calls.
    deinit { }

    /// One-shot latch so a tool call resumes exactly once (queue result or
    /// timeout watchdog, whichever fires first).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true; return true
        }
    }
}
