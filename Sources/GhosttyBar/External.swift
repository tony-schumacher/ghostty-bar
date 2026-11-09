// External sources: commands from ~/.config/ghosttybar/sources.json that print agent sessions as JSON
// (tmux panes, other machines, bots, ...). Each source becomes its own group after the Ghostty windows.
// GhosttyBar itself makes no network connections; whatever a command does is up to the command.
//
//   {"sources": [{"name": "build-server", "command": "~/bin/tmux-source.sh me@build", "interval": 5, "timeout": 4}]}
//
// The command prints one JSON object:
//   {"items": [{"id": "a", "title": "...", "state": "busy|idle|waiting|plain",
//               "since": 1794200000, "subtitle": "...", "url": "..."}], "error": null}
import AppKit

struct SourceConfig: Equatable, Sendable {
    let name: String
    let command: String
    let interval: TimeInterval   // seconds between runs, min 2, default 5
    let timeout: TimeInterval    // seconds before the command is killed, default 4
}

struct ExternalItem: Equatable, Sendable {
    let id: String
    let title: String
    let state: String            // busy | idle | waiting | plain
    let since: Double?
    let subtitle: String?
    let url: String?
}

/// One run of a source command. `items == nil`: the source is offline (`error` says why, short).
struct SourceResult: Sendable {
    let items: [ExternalItem]?
    let error: String?
    var detail: String? = nil    // longer reason for the log (stderr, exit code)
}

/// Separator inside external ids and group ids (never part of a source name typed in JSON in practice).
let extSep = "\u{1f}"
let extPrefix = "ext" + extSep

func externalID(_ source: String, _ item: String) -> String { extPrefix + source + extSep + item }
func externalGroupID(_ source: String) -> String { extPrefix + source }
func isExternalID(_ id: String) -> Bool { id.hasPrefix(extPrefix) }
/// Source name of an external id, nil for Ghostty ids.
func externalSource(ofID id: String) -> String? {
    guard isExternalID(id) else { return nil }
    let rest = id.dropFirst(extPrefix.count)
    guard let r = rest.range(of: extSep) else { return nil }
    return String(rest[..<r.lowerBound])
}

extension ExternalItem {
    /// As a row in the list. "waiting" is idle + bell, like a Ghostty tab that rang the bell.
    func tab(source: String, index: Int, now: Date) -> Tab {
        let (state, bell): (TabState, Bool) = switch self.state {
        case "busy": (.busy, false)
        case "idle": (.idle, false)
        case "waiting": (.idle, true)
        default: (.plain, false)
        }
        // A timestamp from the future (clock skew between machines) is clamped to now.
        let date = since.map { min(Date(timeIntervalSince1970: $0), now) }
        return Tab(windowID: externalGroupID(source), id: externalID(source, id), index: index,
                   selected: false, inFrontWindow: false, title: title, state: state, bell: bell,
                   directory: subtitle ?? "", source: source, url: url, since: date)
    }
}

/// Reads the config, runs each source on its interval (off the main thread, one run in flight per source)
/// and hands results to the app on main. Without a config file it does nothing but a cheap stat every 2 s.
@MainActor
final class ExternalSources {
    /// ~/.config/ghosttybar/sources.json, or the file named by GHOSTTYBAR_SOURCES.
    static var configURL: URL {
        if let p = ProcessInfo.processInfo.environment["GHOSTTYBAR_SOURCES"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghosttybar/sources.json")
    }

    /// Configured source names in order (also called with [] when the config file is removed).
    var onConfig: (([String]) -> Void)?
    var onResult: ((String, SourceResult) -> Void)?

    private(set) var configs: [SourceConfig] = []
    private let demo: Bool
    private var configStamp: String?          // mtime + size of the config file, nil = absent
    private var checkedOnce = false
    private var lastConfigCheck = Date.distantPast
    private var lastRun: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var lastLogged: [String: String] = [:]
    private let queue = DispatchQueue(label: "GhosttyBar.external", qos: .utility, attributes: .concurrent)

    /// Demo mode shows a fixture source, unless GHOSTTYBAR_SOURCES names a config to try out.
    init(demo: Bool) {
        self.demo = demo && ProcessInfo.processInfo.environment["GHOSTTYBAR_SOURCES"] == nil
    }

    /// Called from the app's poll timer (every 0.7 s). Cheap when nothing is due.
    func tick(now: Date = Date()) {
        if demo { demoTick(now); return }
        if now.timeIntervalSince(lastConfigCheck) >= 2 {
            lastConfigCheck = now
            checkConfig()
        }
        for c in configs where !inFlight.contains(c.name) {
            if let last = lastRun[c.name], now.timeIntervalSince(last) < c.interval { continue }
            start(c, now: now)
        }
    }

    // MARK: config

    private func checkConfig() {
        let path = Self.configURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = attrs.map { a in
            "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\((a[.size] as? Int) ?? 0)"
        }
        guard !checkedOnce || stamp != configStamp else { return }
        let first = !checkedOnce
        checkedOnce = true
        configStamp = stamp
        guard stamp != nil else {
            if !configs.isEmpty || first {
                if !configs.isEmpty { log("External sources: \(path) removed") }
                apply([])
            }
            return
        }
        do {
            let data = try Data(contentsOf: Self.configURL)
            let parsed = try Self.parseConfig(data)
            log("External sources: \(parsed.map(\.name).joined(separator: ", ").ifEmpty("none")) from \(path)")
            apply(parsed)
        } catch {
            log("External sources: ignoring \(path): \(error)")   // keep the previous sources
        }
    }

    private func apply(_ new: [SourceConfig]) {
        let names = Set(new.map(\.name))
        // A changed command or interval runs right away; removed sources are forgotten.
        for old in configs where !new.contains(old) { lastRun[old.name] = nil }
        lastRun = lastRun.filter { names.contains($0.key) }
        configs = new
        onConfig?(new.map(\.name))
    }

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    nonisolated static func parseConfig(_ data: Data) throws -> [SourceConfig] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["sources"] as? [[String: Any]] else {
            throw ConfigError(description: "expected {\"sources\": [...]}")
        }
        var out: [SourceConfig] = []
        for (i, s) in list.enumerated() {
            guard let name = (s["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !name.contains(extSep) else {
                throw ConfigError(description: "source \(i + 1): \"name\" missing")
            }
            guard let command = s["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigError(description: "source \"\(name)\": \"command\" missing")
            }
            guard !out.contains(where: { $0.name == name }) else {
                throw ConfigError(description: "source name \"\(name)\" used twice")
            }
            let interval = max(2, (s["interval"] as? NSNumber)?.doubleValue ?? 5)
            let timeout = min(60, max(0.5, (s["timeout"] as? NSNumber)?.doubleValue ?? 4))
            out.append(SourceConfig(name: name, command: command, interval: interval, timeout: timeout))
        }
        return out
    }

    // MARK: running

    private func start(_ c: SourceConfig, now: Date) {
        inFlight.insert(c.name)
        lastRun[c.name] = now
        queue.async { [weak self] in
            let result = Self.run(c)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight.remove(c.name)
                    // Dropped when the source was removed or changed while the command ran.
                    guard self.configs.contains(c) else { return }
                    self.logChange(c.name, result)
                    self.onResult?(c.name, result)
                }
            }
        }
    }

    private func logChange(_ name: String, _ r: SourceResult) {
        let msg = r.items == nil ? "offline: \([r.error, r.detail].compactMap { $0 }.joined(separator: ", "))" : "ok"
        guard lastLogged[name] != msg else { return }
        if lastLogged[name] != nil || r.items == nil { log("External source \(name): \(msg)") }
        lastLogged[name] = msg
    }

    /// Runs the command via /bin/sh -c with stdout/stderr going to temp files (not pipes: a background
    /// process the command leaves behind, such as an ssh ControlPersist master, must not keep us waiting).
    nonisolated static func run(_ c: SourceConfig) -> SourceResult {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ghosttybar-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard fm.createFile(atPath: outURL.path, contents: nil), fm.createFile(atPath: errURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
            return SourceResult(items: nil, error: "offline", detail: "cannot create temp files")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", c.command]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        // Apps started by launchd or Finder get a minimal PATH; add the usual Homebrew locations.
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.split(separator: ":").contains(Substring($0)) }
        env["PATH"] = (extra + [path]).joined(separator: ":")
        p.environment = env
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            try? out.close(); try? err.close()
            return SourceResult(items: nil, error: "offline", detail: "\(error.localizedDescription)")
        }
        try? out.close(); try? err.close()   // the child has its own descriptors

        if done.wait(timeout: .now() + c.timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            return SourceResult(items: nil, error: "timed out", detail: "after \(c.timeout) s")
        }
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        let stderr = readHead(errURL)
        var r = parseOutput(data)
        if r.items == nil {
            r.detail = [r.detail, p.terminationStatus != 0 ? "exit \(p.terminationStatus)" : nil, stderr]
                .compactMap { $0 }.joined(separator: ", ")
        } else if r.items != nil, p.terminationStatus != 0 {
            // Valid JSON but a failing exit status: trust the status.
            return SourceResult(items: nil, error: "offline", detail: "exit \(p.terminationStatus)\(stderr.map { ", \($0)" } ?? "")")
        }
        return r
    }

    nonisolated private static func readHead(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        let s = String(decoding: d.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return s.isEmpty ? nil : s
    }

    /// Parses a command's stdout. Items without id, title or a known state are skipped.
    nonisolated static func parseOutput(_ data: Data) -> SourceResult {
        guard data.count <= 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SourceResult(items: nil, error: "offline", detail: data.isEmpty ? "no output" : "invalid JSON")
        }
        if let e = root["error"] as? String {
            let msg = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { return SourceResult(items: nil, error: shortError(msg), detail: msg) }
        }
        guard let list = root["items"] as? [[String: Any]] else {
            return SourceResult(items: nil, error: "offline", detail: "no \"items\" array")
        }
        let states: Set<String> = ["busy", "idle", "waiting", "plain"]
        var seen: Set<String> = []
        var items: [ExternalItem] = []
        for o in list {
            let id: String? = switch o["id"] {
            case let s as String: s
            case let n as NSNumber: n.stringValue
            default: nil
            }
            guard let id, !id.isEmpty, !seen.contains(id),
                  let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let state = o["state"] as? String, states.contains(state) else { continue }
            seen.insert(id)
            let subtitle = (o["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let url = (o["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            items.append(ExternalItem(id: id, title: title, state: state,
                                      since: (o["since"] as? NSNumber)?.doubleValue,
                                      subtitle: subtitle, url: url))
        }
        return SourceResult(items: items, error: nil)
    }

    nonisolated static func shortError(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }

    // MARK: demo

    /// `--demo`: one fixture source, no commands, no config file.
    private var demoStart: Date?
    private func demoTick(_ now: Date) {
        let name = "build-server"
        if demoStart == nil {
            demoStart = now
            configs = [SourceConfig(name: name, command: "", interval: 5, timeout: 4)]
            onConfig?([name])
        }
        if let last = lastRun[name], now.timeIntervalSince(last) < 5 { return }
        lastRun[name] = now
        let t0 = demoStart!.timeIntervalSince1970
        onResult?(name, SourceResult(items: [
            ExternalItem(id: "nightly", title: "nightly e2e suite", state: "busy", since: t0 - 7 * 60,
                         subtitle: "ci", url: nil),
            ExternalItem(id: "release", title: "release checklist", state: "waiting", since: t0 - 2 * 60,
                         subtitle: "deploy", url: nil),
        ], error: nil))
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
