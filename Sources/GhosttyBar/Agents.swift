// Agent activity of Claude Code tabs: background subagents and dynamic workflows running in the session,
// read from Claude Code's local session files (read-only). For each tab GhosttyBar knows the pid of the
// foreground process; for a `claude` process Claude Code keeps
//
//   <config>/sessions/<pid>.json                                    {"sessionId", "cwd", ...}
//   <config>/projects/<encoded cwd>/<sessionId>/subagents/agent-<id>.jsonl (+ .meta.json)   Agent tool
//   .../<sessionId>/subagents/workflows/<runId>/journal.jsonl       workflow agents started / finished
//   .../<sessionId>/workflows/<runId>.json                          written when the workflow ends
//   .../<sessionId>/workflows/scripts/<name>-<runId>.js             the workflow's script (its name)
//
// <config> is $CLAUDE_CONFIG_DIR or ~/.claude. Missing or malformed files simply mean "no activity".
// Only stat/readdir and small reads; runs off the main thread (see ScriptRunner in Ghostty.swift).
import Foundation

struct WorkflowRun: Equatable, Sendable {
    let name: String
    let phase: String?
    let running: Int     // agents started and not finished yet
}

/// What runs in the background of one Claude Code session right now.
struct AgentActivity: Equatable, Sendable {
    var workflows: [WorkflowRun] = []   // most recently active first
    var agents = 0                      // Agent-tool subagents writing in the last 90 s
    var agentLabel: String?             // their description, when exactly one runs

    var isEmpty: Bool { workflows.isEmpty && agents == 0 }

    /// "⚙ onepager-r4 · Build · 5 running", "⚙ 2 agents", "⚙ 1 agent · Find prior blurbs".
    var text: String {
        var parts: [String] = []
        if let w = workflows.first {
            parts.append(w.name)
            if let p = w.phase, !p.isEmpty { parts.append(p) }
            if w.running > 0 { parts.append("\(w.running) running") }
            if workflows.count > 1 { parts.append("+\(workflows.count - 1) workflow\(workflows.count > 2 ? "s" : "")") }
            if agents > 0 { parts.append("+\(agents) agent\(agents > 1 ? "s" : "")") }
        } else if agents == 1 {
            parts.append("1 agent")
            if let l = agentLabel, !l.isEmpty { parts.append(l.count > 40 ? String(l.prefix(39)) + "…" : l) }
        } else if agents > 1 {
            parts.append("\(agents) agents")
        }
        return "⚙ " + parts.joined(separator: " · ")
    }

    var json: [String: Any] {
        var o: [String: Any] = [
            "workflows": workflows.map { w -> [String: Any] in
                var d: [String: Any] = ["name": w.name, "running": w.running]
                if let p = w.phase { d["phase"] = p }
                return d
            },
            "agents": agents,
            "text": text,
        ]
        if let l = agentLabel { o["agentLabel"] = l }
        return o
    }
}

/// Reads activity per pid. Not thread-safe: confine to one queue. Results are cached for `minInterval`.
final class AgentReader {
    static let minInterval: TimeInterval = 2
    static let agentWindow: TimeInterval = 90         // a subagent counts while its transcript moved this recently
    static let workflowWindow: TimeInterval = 15 * 60 // a run without any write for this long counts as dead
    static let maxRunDirs = 5
    static let maxJournalBytes = 8_000_000

    struct Session { let id: String; let cwd: String; let dir: URL?; let status: String? }

    /// Per pid: the session's own busy/idle status (used when the title has no Claude Code glyph)
    /// and its background activity.
    struct Info: Equatable, Sendable {
        var busy: Bool?                 // nil: status unknown
        var activity: AgentActivity?
    }

    let configDir: URL
    private let fm = FileManager.default
    private var cache: [Int32: (at: Date, info: Info?)] = [:]
    private var sessionDirs: [String: (dir: URL?, checked: Date)] = [:]
    private var journals: [String: (mtime: TimeInterval, size: Int64, parsed: (Int, String?))] = [:]
    private var names: [String: String] = [:]

    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        if let p = env["CLAUDE_CONFIG_DIR"], !p.isEmpty {
            configDir = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
    }

    /// Info for each pid that runs a Claude Code session; other pids are left out.
    func info(for pids: [Int32], now: Date = Date()) -> [Int32: Info] {
        let wanted = Set(pids)
        cache = cache.filter { wanted.contains($0.key) }
        guard isDir(configDir.path) else { return [:] }
        var out: [Int32: Info] = [:]
        for pid in wanted where pid > 0 {
            let i: Info?
            if let c = cache[pid], now.timeIntervalSince(c.at) < Self.minInterval {
                i = c.info
            } else {
                i = session(pid: pid, now: now).map { s in
                    Info(busy: s.status == "busy" ? true : s.status == "idle" ? false : nil, activity: read(s, now: now))
                }
                cache[pid] = (now, i)
            }
            if let i { out[pid] = i }
        }
        return out
    }

    /// Activity for each pid that has some.
    func activity(for pids: [Int32], now: Date = Date()) -> [Int32: AgentActivity] {
        info(for: pids, now: now).compactMapValues(\.activity)
    }

    /// The Claude Code session of a process, nil when the pid is not a running `claude`.
    func session(pid: Int32, now: Date = Date()) -> Session? {
        let file = configDir.appendingPathComponent("sessions/\(pid).json")
        guard let data = smallRead(file.path, max: 256_000),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["sessionId"] as? String, isSafeName(id) else { return nil }
        if let p = (o["pid"] as? NSNumber)?.int32Value, p != pid { return nil }
        let cwd = o["cwd"] as? String ?? ""
        return Session(id: id, cwd: cwd, dir: sessionDir(id: id, cwd: cwd, now: now), status: o["status"] as? String)
    }

    private func read(_ s: Session, now: Date) -> AgentActivity? {
        guard let dir = s.dir else { return nil }
        var a = AgentActivity()
        a.workflows = workflows(dir, now: now)
        (a.agents, a.agentLabel) = plainAgents(dir.appendingPathComponent("subagents"), now: now)
        return a.isEmpty ? nil : a
    }

    // MARK: session dir

    /// projects/<cwd with "/" and "." as "-">/<sessionId>; else one scan of projects/*/<sessionId>.
    /// A miss is retried after 30 s (the directory appears with the first subagent).
    private func sessionDir(id: String, cwd: String, now: Date) -> URL? {
        if let c = sessionDirs[id] {
            if let d = c.dir, isDir(d.path) { return d }
            if c.dir == nil && now.timeIntervalSince(c.checked) < 30 { return nil }
        }
        let projects = configDir.appendingPathComponent("projects")
        var found: URL?
        if !cwd.isEmpty {
            let enc = String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
            let d = projects.appendingPathComponent(enc).appendingPathComponent(id)
            if isDir(d.path) { found = d }
        }
        if found == nil {
            for p in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
                let d = projects.appendingPathComponent(p).appendingPathComponent(id)
                if isDir(d.path) { found = d; break }
            }
        }
        sessionDirs[id] = (found, now)
        if sessionDirs.count > 200 { sessionDirs = sessionDirs.filter { $0.key == id } }
        return found
    }

    // MARK: workflows

    private func workflows(_ dir: URL, now: Date) -> [WorkflowRun] {
        let runsDir = dir.appendingPathComponent("subagents/workflows")
        guard let runs = try? fm.contentsOfDirectory(atPath: runsDir.path), !runs.isEmpty else { return [] }
        // Ended runs have a status file; one readdir instead of a stat per run.
        let statusDir = dir.appendingPathComponent("workflows")
        let ended = Set(((try? fm.contentsOfDirectory(atPath: statusDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let open = runs.filter { !ended.contains($0) && isSafeName($0) }
            .compactMap { r -> (String, TimeInterval)? in
                mtime(runsDir.appendingPathComponent(r).path).map { (r, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxRunDirs)
        var out: [(WorkflowRun, TimeInterval)] = []
        for (runId, _) in open {
            let runDir = runsDir.appendingPathComponent(runId)
            let journal = runDir.appendingPathComponent("journal.jsonl")
            guard mtime(journal.path) != nil else { continue }
            // Alive: something in the run directory was written recently (guards against crashed runs).
            let files = (try? fm.contentsOfDirectory(atPath: runDir.path)) ?? []
            let newest = files.compactMap { mtime(runDir.appendingPathComponent($0).path) }.max() ?? 0
            guard now.timeIntervalSince1970 - newest < Self.workflowWindow else { continue }
            let (running, phase) = parseJournal(journal)
            out.append((WorkflowRun(name: workflowName(dir, runId: runId), phase: phase, running: running), newest))
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// (running agents, current phase). "started" opens an agent; any later event with its agentId
    /// ("result", "failed", ...) closes it. Phase: of the newest still-running agent, else the last started.
    private func parseJournal(_ url: URL) -> (Int, String?) {
        let path = url.path
        guard let a = try? fm.attributesOfItem(atPath: path),
              let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (a[.size] as? NSNumber)?.int64Value else { return (0, nil) }
        if let c = journals[path], c.mtime == m, c.size == size { return c.parsed }
        var parsed: (Int, String?) = (0, nil)
        if size <= Self.maxJournalBytes, let data = try? Data(contentsOf: url) {
            var started: [(id: String, phase: String?)] = []
            var finished: Set<String> = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = o["type"] as? String, let id = o["agentId"] as? String else { continue }
                if type == "started" {
                    started.append((id, o["phase"] as? String))
                    finished.remove(id)
                } else {
                    finished.insert(id)
                }
            }
            let running = started.filter { !finished.contains($0.id) }
            let ids = Set(running.map(\.id))
            parsed = (ids.count, running.last?.phase ?? started.last?.phase)
        }
        if journals.count > 50 { journals = [:] }
        journals[path] = (m, size, parsed)
        return parsed
    }

    /// From workflows/scripts/<name>-<runId>.js; the run id when there is no script file.
    private func workflowName(_ dir: URL, runId: String) -> String {
        if let n = names[runId] { return n }
        let suffix = "-\(runId).js"
        let scripts = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("workflows/scripts").path)) ?? []
        guard let f = scripts.first(where: { $0.hasSuffix(suffix) && $0.count > suffix.count }) else { return runId }
        let n = String(f.dropLast(suffix.count))
        if names.count > 500 { names = [:] }
        names[runId] = n
        return n
    }

    // MARK: Agent-tool subagents

    private func plainAgents(_ dir: URL, now: Date) -> (Int, String?) {
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return (0, nil) }
        let cutoff = now.timeIntervalSince1970 - Self.agentWindow
        let live = files.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .filter { (mtime(dir.appendingPathComponent($0).path) ?? 0) >= cutoff }
        guard live.count == 1 else { return (live.count, nil) }
        let meta = dir.appendingPathComponent(String(live[0].dropLast(6)) + ".meta.json")
        let label = smallRead(meta.path, max: 64_000)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["description"] as? String }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (1, label?.isEmpty == false ? label : nil)
    }

    // MARK: file helpers

    private func mtime(_ path: String) -> TimeInterval? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
    }

    private func isDir(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func smallRead(_ path: String, max: Int) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: max + 1), d.count <= max else { return nil }
        return d
    }

    /// Ids from files used as path components: no separators, no "..".
    private func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.count < 200 && !s.contains("/") && s != "." && s != ".."
    }
}

/// `--dump-agents`: prints the Ghostty tabs with their Claude Code session and agent activity as JSON
/// to stdout. Exit status 1 when Ghostty is not running or cannot be queried.
func dumpAgents() -> Int32 {
    let reader = AgentReader()
    guard let raw = fetchTabsOnce() else {
        FileHandle.standardError.write("Ghostty is not running, or GhosttyBar may not control it (Automation permission)\n"
            .data(using: .utf8)!)
        return 1
    }
    let tabs = attachAgents(raw, reader: reader)
    let act = reader.activity(for: tabs.compactMap(\.pid))
    var windows: [String] = []
    let rows: [[String: Any]] = tabs.map { t in
        if !windows.contains(t.windowID) { windows.append(t.windowID) }
        let state = switch t.state { case .busy: "busy"; case .idle: "idle"; case .plain: "plain" }
        var o: [String: Any] = ["window": (windows.firstIndex(of: t.windowID) ?? 0) + 1, "tab": t.index,
                                "title": t.title, "directory": t.directory, "state": state]
        if let pid = t.pid {
            o["pid"] = pid
            if let s = reader.session(pid: pid) {
                o["sessionId"] = s.id
                if let st = s.status { o["sessionStatus"] = st }
                if let d = s.dir { o["sessionDir"] = d.path }
            }
            if let a = act[pid] { o["activity"] = a.json }
        }
        return o
    }
    let root: [String: Any] = ["claudeConfigDir": reader.configDir.path, "tabs": rows]
    guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
        return 1
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    return 0
}
