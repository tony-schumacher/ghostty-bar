// Ghostty access: tab list via AppleScript (in-process NSAppleScript), title parsing, focus.
import AppKit

let ghosttyBundleID = "com.mitchellh.ghostty"

enum TabState { case busy, idle, plain }

struct Tab: Equatable {
    let windowID: String
    let id: String
    let index: Int
    let selected: Bool
    let inFrontWindow: Bool
    /// The one tab you are actually in: selected in Ghostty's front window (every window has a selected tab).
    var focused: Bool { selected && inFrontWindow }
    let title: String
    let state: TabState
    let bell: Bool         // title carried Ghostty's 🔔 (bell rang, e.g. Claude asks for permission/input)
    let directory: String  // ~-shortened; for external items the subtitle
    /// External items only (see External.swift): source name, link opened on click, and the source's own
    /// timestamp (busy: start, idle/waiting: when it finished). nil for Ghostty tabs.
    var source: String? = nil
    var url: String? = nil
    var since: Date? = nil
    /// Ghostty tabs only: pid of the tab's foreground process, and what runs in the background of the
    /// Claude Code session in it (subagents, workflows; see Agents.swift). Not part of the unread logic.
    var pid: Int32? = nil
    var agents: AgentActivity? = nil

    var isExternal: Bool { source != nil }

    func with(selected: Bool, inFrontWindow: Bool) -> Tab {
        Tab(windowID: windowID, id: id, index: index, selected: selected, inFrontWindow: inFrontWindow,
            title: title, state: state, bell: bell, directory: directory, source: source, url: url, since: since,
            pid: pid, agents: agents)
    }
}

/// Where tabs come from: the real Ghostty (AppleScript) or the `--demo` fixtures.
@MainActor
protocol TabSource: AnyObject {
    /// The terminal is running (never query it otherwise: AppleScript would launch it).
    var isRunning: Bool { get }
    /// The terminal is the frontmost app (its visible tab can count as "looked at").
    var isFrontmost: Bool { get }
    /// Running instances of the terminal app. AppleScript reaches only one of them, so with more than
    /// one (e.g. after `open -n`) the tabs of the others are missing from the list.
    var instanceCount: Int { get }
    /// Tab list, delivered on main. [] when not running, nil on an error (caller keeps its state).
    func fetchTabs(_ done: @escaping @MainActor @Sendable ([Tab]?) -> Void)
    /// Bring the tab to the front. `minimizeOthers`: then minimize every other terminal window.
    func focus(_ tab: Tab, minimizeOthers: Bool)
}

private let fieldSep = "\u{1f}"
private let rowSep = "\u{1e}"

/// Bulk property reads per window (one Apple Event per property instead of ~7 per tab).
/// Falls back to a per-tab directory read when the bulk read doesn't line up. Hard 3 s timeout.
/// Windows are taken as one snapshot of id references and each is read in its own `try`: a window that
/// closes mid-read is skipped instead of failing the whole list ("Can't get item 3 of every window").
private let listScript = """
with timeout of 3 seconds
    tell application id "\(ghosttyBundleID)"
        set out to ""
        set fs to (ASCII character 31)
        set rs to (ASCII character 30)
        set frontId to ""
        try
            set frontId to id of front window
        end try
        repeat with w in (get every window)
          try
            set wid to id of w
            set tids to id of tabs of w
            set tidx to index of tabs of w
            set tsel to selected of tabs of w
            set tnames to name of tabs of w
            set n to count of tids
            set dirs to {}
            try
                set dirs to working directory of focused terminal of tabs of w
            end try
            if (count of dirs) is not n then
                set dirs to {}
                repeat with t in tabs of w
                    set d to ""
                    try
                        set d to working directory of focused terminal of t
                    end try
                    set end of dirs to d
                end repeat
            end if
            set pids to {}
            try
                set pids to pid of focused terminal of tabs of w
            end try
            if (count of pids) is not n then
                set pids to {}
                repeat with t in tabs of w
                    set p to 0
                    try
                        set p to pid of focused terminal of t
                    end try
                    set end of pids to p
                end repeat
            end if
            set isFront to (wid is frontId)
            repeat with i from 1 to n
                set d to item i of dirs
                if d is missing value then set d to ""
                set p to item i of pids
                if p is missing value then set p to 0
                set out to out & wid & fs & (item i of tids) & fs & (item i of tidx) & fs & (item i of tsel) & fs & (item i of tnames) & fs & d & fs & isFront & fs & p & rs
            end repeat
          end try
        end repeat
        return out
    end tell
end timeout
"""

private let busyGlyphs: Set<Unicode.Scalar> = ["◐", "◑", "◒", "◓"]
private let idleGlyphs: Set<Unicode.Scalar> = ["✳", "✻", "✽", "✶", "✢"]

/// Returns (clean title, state, bell). Classifies by the first code point, so a trailing variation
/// selector (e.g. "✳\u{FE0F}") doesn't hide the glyph.
/// The ✳-family is only Claude Code's idle glyph: it says nothing about whether you looked at the tab.
/// A leading 🔔 (Ghostty's bell marker) is stripped from the title but reported as `bell`.
func parseTitle(_ raw: String) -> (String, TabState, Bool) {
    var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var bell = false
    if title.hasPrefix("🔔") {
        bell = true
        title = String(title.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let first = title.unicodeScalars.first else { return ("Terminal", .plain, bell) }
    let rest = String(String.UnicodeScalarView(title.unicodeScalars.dropFirst()))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if busyGlyphs.contains(first) || (0x2800...0x28FF).contains(first.value) {
        return (rest.isEmpty ? "Claude" : rest, .busy, bell)
    }
    if idleGlyphs.contains(first) {
        return (rest.isEmpty ? "Claude" : rest, .idle, bell)
    }
    return (title, .plain, bell)
}

func shortDir(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
    return path
}

private func asQuoted(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func parseTabs(_ out: String) -> [Tab] {
    var tabs: [Tab] = []
    for row in out.components(separatedBy: rowSep) where !row.isEmpty {
        let f = row.components(separatedBy: fieldSep)
        guard f.count == 8 else { continue }
        let (title, state, bell) = parseTitle(f[4])
        let pid = Int32(f[7]).flatMap { $0 > 0 ? $0 : nil }
        tabs.append(Tab(windowID: f[0], id: f[1], index: Int(f[2]) ?? 0,
                        selected: f[3] == "true", inFrontWindow: f[6] == "true",
                        title: title, state: state, bell: bell, directory: shortDir(f[5]), pid: pid))
    }
    return tabs
}

/// Fills in `agents` from the pids (file reads, call off the main thread). A tab whose title carries no
/// Claude Code glyph (renamed tab) takes busy/idle from its session file; a title glyph always wins.
func attachAgents(_ tabs: [Tab], reader: AgentReader) -> [Tab] {
    let info = reader.info(for: tabs.compactMap(\.pid))
    guard !info.isEmpty else { return tabs }
    return tabs.map { t in
        guard let i = t.pid.flatMap({ info[$0] }) else { return t }
        var state = t.state
        if state == .plain, let busy = i.busy { state = busy ? .busy : .idle }
        var out = Tab(windowID: t.windowID, id: t.id, index: t.index, selected: t.selected,
                      inFrontWindow: t.inFrontWindow, title: t.title, state: state, bell: t.bell,
                      directory: t.directory, pid: t.pid)
        out.agents = i.activity
        return out
    }
}

/// One synchronous tab read for `--dump-agents` (before the app runs; blocks the caller).
/// nil when Ghostty is not running or the script failed (the error goes to stderr).
func fetchTabsOnce() -> [Tab]? {
    guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == ghosttyBundleID }) else {
        return nil
    }
    var error: NSDictionary?
    let result = NSAppleScript(source: listScript)?.executeAndReturnError(&error)
    if let error { log("AppleScript error: \(error)"); return nil }
    return parseTabs(result?.stringValue ?? "")
}

/// The real Ghostty. The main thread never blocks on it: all AppleScript runs in `ScriptRunner`.
@MainActor
final class GhosttyClient: TabSource {
    private let runner = ScriptRunner()
    private var inFlight = false

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == ghosttyBundleID }
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ghosttyBundleID
    }

    var instanceCount: Int {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == ghosttyBundleID }.count
    }

    /// Skips when the previous fetch is still running (no stacking). nil e.g. when a tab closed
    /// mid-query or Automation permission is missing (-1743).
    func fetchTabs(_ done: @escaping @MainActor @Sendable ([Tab]?) -> Void) {
        guard isRunning else { done([]); return }
        guard !inFlight else { return }
        inFlight = true
        runner.list { [weak self] tabs in
            self?.inFlight = false
            done(tabs)
        }
    }

    func focus(_ tab: Tab, minimizeOthers: Bool) {
        let pid = minimizeOthers
            ? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == ghosttyBundleID }?.processIdentifier
            : nil
        runner.run("""
        with timeout of 3 seconds
            tell application id "\(ghosttyBundleID)"
                set w to window id "\(asQuoted(tab.windowID))"
                activate window w
                select tab (first tab of w whose id is "\(asQuoted(tab.id))")
                activate
            end tell
        end timeout
        """) {
            if let pid { minimizeOtherWindows(pid: pid) }
        }
    }
}

/// Focus mode: minimize every standard window of the app except its main window (the one the
/// focus script just raised). Native tab groups count as one window. Needs Accessibility
/// permission; without it nothing happens. Runs on the script queue, after the focus script.
private func minimizeOtherWindows(pid: pid_t) {
    guard AXIsProcessTrusted() else { return }
    let app = AXUIElementCreateApplication(pid)
    func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    // Ghostty raises the window asynchronously; wait until it is main (max ~0.5 s).
    var main: AXUIElement?
    for _ in 0..<10 {
        if let m = attr(app, kAXMainWindowAttribute), CFGetTypeID(m) == AXUIElementGetTypeID() {
            main = (m as! AXUIElement)
            break
        }
        usleep(50_000)
    }
    guard let main, let list = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return }
    for w in list where !CFEqual(w, main) {
        guard attr(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              attr(w, kAXMinimizedAttribute) as? Bool != true else { continue }
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
}

/// NSAppleScript is not thread-safe, so it is confined to one serial background queue.
/// The list script is compiled once.
private final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GhosttyBar.applescript", qos: .utility)
    // queue-confined state
    private var compiledList: NSAppleScript?
    private var lastErrorLogged: String?
    private let agents = AgentReader()

    /// Tab list with agent activity, both read here on the background queue.
    func list(_ done: @escaping @MainActor @Sendable ([Tab]?) -> Void) {
        queue.async { [self] in
            let tabs = runList().map { attachAgents(parseTabs($0), reader: agents) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(tabs) } }
        }
    }


    /// `then` runs on the same queue right after the script.
    func run(_ source: String, then: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if let script = NSAppleScript(source: source) { _ = execute(script) }
            then?()
        }
    }

    // MARK: queue-only

    private func runList() -> String? {
        if compiledList == nil {
            let s = NSAppleScript(source: listScript)
            var err: NSDictionary?
            if s?.compileAndReturnError(&err) == true { compiledList = s } else {
                logOnce("AppleScript compile error: \(err ?? [:])")
                return nil
            }
        }
        return execute(compiledList!)
    }

    private func execute(_ script: NSAppleScript) -> String? {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            logOnce("AppleScript error: \(error)")
            return nil
        }
        lastErrorLogged = nil
        return result.stringValue ?? ""
    }

    private func logOnce(_ msg: String) {
        if msg != lastErrorLogged {
            log(msg)
            lastErrorLogged = msg
        }
    }
}
