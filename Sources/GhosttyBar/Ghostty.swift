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
    let title: String
    let state: TabState
    let bell: Bool         // title carried Ghostty's 🔔 (bell rang, e.g. Claude asks for permission/input)
    let directory: String  // ~-shortened; for external items the subtitle
    /// External items only (see External.swift): source name, link opened on click, and the source's own
    /// timestamp (busy: start, idle/waiting: when it finished). nil for Ghostty tabs.
    var source: String? = nil
    var url: String? = nil
    var since: Date? = nil

    var isExternal: Bool { source != nil }

    func with(selected: Bool, inFrontWindow: Bool) -> Tab {
        Tab(windowID: windowID, id: id, index: index, selected: selected, inFrontWindow: inFrontWindow,
            title: title, state: state, bell: bell, directory: directory, source: source, url: url, since: since)
    }
}

/// Where tabs come from: the real Ghostty (AppleScript) or the `--demo` fixtures.
@MainActor
protocol TabSource: AnyObject {
    /// The terminal is running (never query it otherwise: AppleScript would launch it).
    var isRunning: Bool { get }
    /// The terminal is the frontmost app (its visible tab can count as "looked at").
    var isFrontmost: Bool { get }
    /// Tab list, delivered on main. [] when not running, nil on an error (caller keeps its state).
    func fetchTabs(_ done: @escaping @MainActor @Sendable ([Tab]?) -> Void)
    /// Bring the tab to the front.
    func focus(_ tab: Tab)
}

private let fieldSep = "\u{1f}"
private let rowSep = "\u{1e}"

/// Bulk property reads per window (one Apple Event per property instead of ~7 per tab).
/// Falls back to a per-tab directory read when the bulk read doesn't line up. Hard 3 s timeout.
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
        repeat with w in windows
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
            set isFront to (wid is frontId)
            repeat with i from 1 to n
                set d to item i of dirs
                if d is missing value then set d to ""
                set out to out & wid & fs & (item i of tids) & fs & (item i of tidx) & fs & (item i of tsel) & fs & (item i of tnames) & fs & d & fs & isFront & rs
            end repeat
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

private func parseTabs(_ out: String) -> [Tab] {
    var tabs: [Tab] = []
    for row in out.components(separatedBy: rowSep) where !row.isEmpty {
        let f = row.components(separatedBy: fieldSep)
        guard f.count == 7 else { continue }
        let (title, state, bell) = parseTitle(f[4])
        tabs.append(Tab(windowID: f[0], id: f[1], index: Int(f[2]) ?? 0,
                        selected: f[3] == "true", inFrontWindow: f[6] == "true",
                        title: title, state: state, bell: bell, directory: shortDir(f[5])))
    }
    return tabs
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

    /// Skips when the previous fetch is still running (no stacking). nil e.g. when a tab closed
    /// mid-query or Automation permission is missing (-1743).
    func fetchTabs(_ done: @escaping @MainActor @Sendable ([Tab]?) -> Void) {
        guard isRunning else { done([]); return }
        guard !inFlight else { return }
        inFlight = true
        runner.list { [weak self] out in
            self?.inFlight = false
            done(out.map(parseTabs))
        }
    }

    func focus(_ tab: Tab) {
        runner.run("""
        with timeout of 3 seconds
            tell application id "\(ghosttyBundleID)"
                set w to window id "\(asQuoted(tab.windowID))"
                activate window w
                select tab (first tab of w whose id is "\(asQuoted(tab.id))")
                activate
            end tell
        end timeout
        """)
    }
}

/// NSAppleScript is not thread-safe, so it is confined to one serial background queue.
/// The list script is compiled once.
private final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GhosttyBar.applescript", qos: .utility)
    // queue-confined state
    private var compiledList: NSAppleScript?
    private var lastErrorLogged: String?

    func list(_ done: @escaping @MainActor @Sendable (String?) -> Void) {
        queue.async { [self] in
            let out = runList()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(out) } }
        }
    }

    func run(_ source: String) {
        queue.async { [self] in
            if let script = NSAppleScript(source: source) { _ = execute(script) }
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
