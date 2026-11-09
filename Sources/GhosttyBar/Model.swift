// Shared state: tab list + read/unread logic (published to the SwiftUI window) and persisted settings.
import AppKit
import Combine

/// What a row shows. Precedence: unread > busy > read > plain.
enum Status { case unread, busy, read, plain }

/// A tab that has something for you that you haven't looked at yet.
struct UnreadMark: Codable, Equatable {
    var since: Date
    var bell: Bool  // true: the tab rang the bell (Claude wants input), false: Claude finished (busy → idle)
}

/// A titled block of rows: one Ghostty window, or one external source.
struct TabGroup {
    let id: String
    let title: String?   // nil: no header (a single Ghostty window and nothing else)
    let note: String?    // external source problem, shown after the title ("offline")
    let tabs: [Tab]
    let dim: Bool        // offline source: last known items, dimmed
}

/// Latest state of one external source.
struct ExternalGroup: Equatable {
    let name: String
    var items: [Tab] = []
    var error: String?   // non-nil: offline, `items` are the last known ones
}

@MainActor
final class TabModel: ObservableObject {
    /// Ghostty tabs followed by the items of all external sources (in config order).
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var unread: [String: UnreadMark] = [:]
    @Published private(set) var busySince: [String: Date] = [:]
    @Published private(set) var running = false
    @Published private(set) var external: [ExternalGroup] = []
    @Published var opacity: Double = 1.0
    @Published var unreadOnly = false

    private let settings: AppSettings
    private var ghosttyTabs: [Tab] = []
    private var lastState: [String: TabState] = [:]
    private var lastBell: [String: Bool] = [:]
    /// Tab that is currently the visible one (frontmost Ghostty, front window, selected) and since when.
    private var visibleTab: String?
    private var visibleSince = Date.distantFuture
    /// Continuous visibility needed to count as "looked at" (filters flicking past with ⌘⇧[ / ⌘⇧]).
    static let dwell: TimeInterval = 0.6
    /// Tabs jumped to via GhosttyBar, with time; edges for them are ignored for `jumpGrace`
    /// (a fetch already in flight may carry a snapshot from before the jump).
    private var jumpedAt: [String: Date] = [:]
    static let jumpGrace: TimeInterval = 4
    /// busySince value for tabs first seen already working (real start unknown, no time shown).
    static let unknownStart = Date(timeIntervalSince1970: 0)

    init(settings: AppSettings) {
        self.settings = settings
        unread = settings.unread
        busySince = settings.busySince
        unreadOnly = settings.unreadOnly
        // External items keep their last state across restarts, so a change while GhosttyBar was not
        // running still counts as an edge, and an item you already read stays read.
        for (id, v) in settings.externalLast {
            lastState[id] = v == "busy" ? .busy : v == "plain" ? .plain : .idle
            lastBell[id] = v == "waiting"
        }
    }

    /// Applies one Ghostty poll result. `fresh == nil` = AppleScript error (keep tabs and marks, but still
    /// track whether Ghostty runs, so a denied/pending permission shows "No tabs", not "Ghostty not running").
    /// `running` = Ghostty is running. `front` = Ghostty was frontmost for the whole fetch (caller ANDs
    /// before and after the snapshot).
    /// Returns whether anything visible changed and which tabs just became unread (for notifications).
    ///
    /// Read detection ("seen"): a tab counts as looked at when it is the visible tab (Ghostty frontmost,
    /// its window in front, tab selected) continuously for `dwell` (0.6 s). While Ghostty is frontmost the
    /// app polls every 0.7 s, so a look registers after ~1 s; shorter flashes while cycling with ⌘⇧[ / ⌘⇧]
    /// don't count. The same dwell rule decides whether a finish/bell is
    /// suppressed ("you were looking at it"), so a flick past a tab at the wrong moment never swallows a
    /// mark; at worst a mark appears and is cleared one poll later. Jumping via GhosttyBar marks read at
    /// once (explicit intent) and suppresses new marks for that tab briefly (the in-flight snapshot may
    /// predate the jump).
    @discardableResult
    func apply(_ fresh: [Tab]?, running isRunning: Bool, front: Bool,
               now: Date = Date()) -> (changed: Bool, newlyUnread: [Tab]) {
        guard let fresh else {
            visibleTab = nil  // gap in observation: dwell must be re-established
            if isRunning != running { running = isRunning; return (true, []) }
            return (false, [])
        }
        let visibleId = front ? fresh.first(where: { $0.inFrontWindow && $0.selected })?.id : nil
        if visibleId != visibleTab { visibleTab = visibleId; visibleSince = now }
        let r = ingest(fresh, owns: { !isExternalID($0) }, front: front, now: now)
        let changed = fresh != ghosttyTabs || r.marksChanged || isRunning != running
        ghosttyTabs = fresh
        running = isRunning
        if changed { publishTabs() }
        return (changed, r.added)
    }

    /// Applies one run of an external source. `items == nil`: offline (keep the last items, dimmed).
    /// External items are never "looked at" (GhosttyBar can't see you looking at another machine): they
    /// become read on click, when they turn busy again, or with Mark all as read.
    @discardableResult
    func applyExternal(_ name: String, items: [ExternalItem]?, error: String?,
                       now: Date = Date()) -> (changed: Bool, newlyUnread: [Tab]) {
        guard let gi = external.firstIndex(where: { $0.name == name }) else { return (false, []) }
        var g = external[gi]
        guard let items else {
            g.error = error ?? "offline"
            guard g != external[gi] else { return (false, []) }
            external[gi] = g
            publishTabs()
            return (true, [])
        }
        let fresh = items.enumerated().map { $0.element.tab(source: name, index: $0.offset + 1, now: now) }
        let prefix = externalGroupID(name) + extSep
        let r = ingest(fresh, owns: { $0.hasPrefix(prefix) }, front: false, now: now)
        g.items = fresh
        g.error = nil
        let changed = g != external[gi] || r.marksChanged
        external[gi] = g
        if changed { publishTabs() }
        persistExternalLast()
        return (changed, r.added)
    }

    /// The configured external sources, in order. Groups of removed sources disappear with their marks.
    func setExternalSources(_ names: [String]) {
        let old = Dictionary(external.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        external = names.map { old[$0] ?? ExternalGroup(name: $0) }
        let keep = Set(names)
        let gone: (String) -> Bool = { id in externalSource(ofID: id).map { !keep.contains($0) } ?? false }
        let before = (unread.count, busySince.count)
        unread = unread.filter { !gone($0.key) }
        busySince = busySince.filter { !gone($0.key) }
        lastState = lastState.filter { !gone($0.key) }
        lastBell = lastBell.filter { !gone($0.key) }
        if before != (unread.count, busySince.count) { persist() }
        persistExternalLast()
        publishTabs()
    }

    private func publishTabs() {
        let all = ghosttyTabs + external.flatMap(\.items)
        if all != tabs { tabs = all }
    }

    /// Edge detection for one batch of tabs (all Ghostty tabs, or all items of one external source).
    /// `owns` says which ids this batch covers, so state of ids missing from it can be dropped.
    private func ingest(_ fresh: [Tab], owns: (String) -> Bool, front: Bool,
                       now: Date) -> (marksChanged: Bool, added: [Tab]) {
        let ids = Set(fresh.map(\.id))
        var newUnread = unread
        var newBusy = busySince
        var added: [Tab] = []
        jumpedAt = jumpedAt.filter { now.timeIntervalSince($0.value) < Self.jumpGrace }

        for t in fresh {
            let visible = front && t.inFrontWindow && t.selected
            let dwelt = visible && now.timeIntervalSince(visibleSince) >= Self.dwell
            let suppress = dwelt || jumpedAt[t.id] != nil
            let prev = lastState[t.id]          // nil = first sight (app start or new tab)

            // A finish: observed busy → idle, or (first sight after a restart) idle with a persisted busy start.
            let finished = t.state == .idle && (prev == .busy || (prev == nil && busySince[t.id] != nil))
            if t.state == .busy {
                if let since = t.since {
                    newBusy[t.id] = since       // the source knows the real start
                    if prev != .busy { newUnread[t.id] = nil }
                } else if prev == nil {
                    // Keep the persisted start after a restart; otherwise the start is unknown.
                    if newBusy[t.id] == nil { newBusy[t.id] = Self.unknownStart }
                    newUnread[t.id] = nil       // working: nothing waits right now
                } else if prev != .busy {
                    newBusy[t.id] = now
                    newUnread[t.id] = nil
                }
            } else {
                newBusy[t.id] = nil
            }

            // External items carry their own finish time; Ghostty edges happen "now".
            let markTime = t.since ?? now
            if finished && !suppress {
                newUnread[t.id] = UnreadMark(since: markTime, bell: t.bell)
                added.append(t)
            }
            // Bell edge only when the tab was seen before without a bell (no marks from stale 🔔 at start).
            // An external item that is "waiting" on first sight needs you now, so it counts.
            let bellEdge = lastBell[t.id] == false || (t.isExternal && prev == nil)
            if t.bell && bellEdge && !suppress {
                if newUnread[t.id] == nil {
                    newUnread[t.id] = UnreadMark(since: markTime, bell: true)
                    if !added.contains(where: { $0.id == t.id }) { added.append(t) }
                } else {
                    newUnread[t.id]?.bell = true  // finished earlier, now explicitly waits for input
                }
            }
            if dwelt && newUnread[t.id] != nil {
                newUnread[t.id] = nil
                log("read (looked at): \(t.title)")
            }
            lastState[t.id] = t.state
            lastBell[t.id] = t.bell
        }
        for t in added where newUnread[t.id] != nil {
            log("unread (\(newUnread[t.id]?.bell == true ? "bell" : "done")): \(t.title)")
        }

        func keep(_ id: String) -> Bool { ids.contains(id) || !owns(id) }
        newUnread = newUnread.filter { keep($0.key) }
        newBusy = newBusy.filter { keep($0.key) }
        lastState = lastState.filter { keep($0.key) }
        lastBell = lastBell.filter { keep($0.key) }

        let marksChanged = newUnread != unread || newBusy != busySince
        if marksChanged {
            unread = newUnread
            busySince = newBusy
            persist()
        }
        return (marksChanged, added.filter { newUnread[$0.id] != nil })
    }

    private func persistExternalLast() {
        var out: [String: String] = [:]
        for (id, st) in lastState where isExternalID(id) {
            out[id] = switch st {
            case .busy: "busy"
            case .plain: "plain"
            case .idle: lastBell[id] == true ? "waiting" : "idle"
            }
        }
        if out != settings.externalLast { settings.externalLast = out }
    }

    /// Jump via GhosttyBar (click, ⌃⌥J, banner): read now, and ignore edges for this tab for a moment.
    func jumped(_ id: String) {
        jumpedAt[id] = Date()
        markRead(id)
    }

    func markRead(_ id: String) {
        guard unread[id] != nil else { return }
        unread[id] = nil
        persist()
    }

    func markAllRead() {
        guard !unread.isEmpty else { return }
        unread = [:]
        persist()
    }

    func setUnreadOnly(_ on: Bool) {
        unreadOnly = on
        settings.unreadOnly = on
    }

    private func persist() {
        settings.unread = unread
        settings.busySince = busySince
    }

    // MARK: derived

    func status(_ t: Tab) -> Status {
        if unread[t.id] != nil { return .unread }
        switch t.state {
        case .busy: return .busy
        case .idle: return .read
        case .plain: return .plain
        }
    }

    func glyph(_ t: Tab) -> String {
        switch status(t) {
        case .unread: return "●"
        case .busy: return "◐"
        case .read: return "✓"
        case .plain: return "○"
        }
    }

    /// Secondary row text: "for 4 min" (busy), "done 2 min ago" / "waiting 2 min" (unread).
    func detail(_ t: Tab, now: Date = Date()) -> String? {
        if let m = unread[t.id] {
            let s = now.timeIntervalSince(m.since)
            if m.bell { return "waiting \(Self.duration(s))" }
            return s < 60 ? "just finished" : "done \(Self.duration(s)) ago"
        }
        if t.state == .busy, let since = busySince[t.id], since != Self.unknownStart {
            return "for \(Self.duration(now.timeIntervalSince(since)))"
        }
        if t.isExternal && t.bell {   // read, but the source still says it waits for you
            return t.since.map { "waiting \(Self.duration(now.timeIntervalSince($0)))" } ?? "waiting"
        }
        return nil
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(max(0, s) / 60)
        if m < 1 { return "<1 min" }
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min" }
        return "\(h / 24) d"
    }

    var busyCount: Int { tabs.filter { $0.state == .busy }.count }
    var unreadCount: Int { unread.count }

    /// Something to list: tabs, external items, or at least an offline source to report.
    var hasContent: Bool { !tabs.isEmpty || external.contains { $0.error != nil } }

    /// Tabs shown in the list (all, or only unread when the filter is on).
    var visibleTabs: [Tab] { unreadOnly ? tabs.filter { unread[$0.id] != nil } : tabs }

    /// Filter on, tabs exist, nothing unread.
    var allReadEmptyState: Bool { unreadOnly && hasContent && visibleTabs.isEmpty }

    /// Oldest unread first (FIFO), ties in list order.
    var nextUnread: Tab? {
        tabs.enumerated()
            .filter { unread[$0.element.id] != nil }
            .min { a, b in
                let (sa, sb) = (unread[a.element.id]!.since, unread[b.element.id]!.since)
                return sa != sb ? sa < sb : a.offset < b.offset
            }?.element
    }

    private var emptyText: String { running ? "No tabs" : "Ghostty not running" }

    /// "9 tabs", or "9 tabs · 2 remote" once external sources contribute items.
    var countLabel: String {
        let remote = tabs.filter(\.isExternal).count
        let local = tabs.count - remote
        return remote > 0 ? "\(local) tabs · \(remote) remote" : "\(local) tabs"
    }

    var summary: String {
        if tabs.isEmpty { return emptyText }
        return "\(countLabel) · \(busyCount) working · \(unreadCount) unread"
    }

    /// Header line in the window: the unread count lives in the filter pill next to it.
    var windowSummary: String {
        if tabs.isEmpty { return emptyText }
        return "\(countLabel) · \(busyCount) working"
    }

    /// Narrow-window variant of `windowSummary`: "11 tabs · 3 ◐".
    var windowSummaryShort: String {
        if tabs.isEmpty { return windowSummary }
        return busyCount > 0 ? "\(countLabel) · \(busyCount) ◐" : countLabel
    }

    /// Ghostty window ids in first-seen order (all windows, so "Window N" numbering stays stable when filtering).
    var windowIDs: [String] {
        var out: [String] = []
        for t in ghosttyTabs where !out.contains(t.windowID) { out.append(t.windowID) }
        return out
    }

    /// What the menu and the window list: Ghostty windows ("Window N", no header when it is the only
    /// group), then one group per external source (header = source name, plus "offline" when it failed).
    /// Groups without visible rows are left out, except an offline source in the "All" view.
    var groups: [TabGroup] {
        let shown = visibleTabs
        let shownIDs = Set(shown.map(\.id))
        let wins = windowIDs
        var out: [TabGroup] = wins.enumerated().compactMap { wi, wid in
            let ts = shown.filter { $0.windowID == wid }
            return ts.isEmpty ? nil : TabGroup(id: wid, title: "Window \(wi + 1)", note: nil, tabs: ts, dim: false)
        }
        for g in external {
            let ts = g.items.filter { shownIDs.contains($0.id) }
            if ts.isEmpty && (unreadOnly || g.error == nil) { continue }
            out.append(TabGroup(id: externalGroupID(g.name), title: g.name, note: g.error, tabs: ts,
                                dim: g.error != nil))
        }
        if out.count == 1, let g = out.first, !isExternalID(g.id) {
            out[0] = TabGroup(id: g.id, title: nil, note: nil, tabs: g.tabs, dim: false)
        }
        return out
    }
}

let opacityPresets: [Double] = [1.0, 0.85, 0.7, 0.55, 0.4, 0.25]
let opacityMin = 0.15
let blurPresets: [Double] = [1.0, 0.75, 0.5, 0.25, 0]

/// Settings + read state in UserDefaults (the app's own domain; `--demo` uses a separate suite).
@MainActor
final class AppSettings {
    static let domain = "com.github.tony-schumacher.GhosttyBar"
    private let d: UserDefaults

    /// Normal settings: the app's standard defaults (also when run as a bare binary outside the bundle).
    init() {
        d = Bundle.main.bundleIdentifier == Self.domain ? .standard : (UserDefaults(suiteName: Self.domain) ?? .standard)
    }

    /// A separate suite, wiped on creation (demo mode, tests).
    init(freshSuite suite: String) {
        d = UserDefaults(suiteName: suite) ?? .standard
        self.suite = suite
        d.removePersistentDomain(forName: suite)
    }

    private var suite: String?

    /// Deletes a fresh suite (demo mode on quit). Never touches the normal settings.
    func removeAll() {
        guard let suite else { return }
        for key in d.persistentDomain(forName: suite)?.keys ?? [:].keys { d.removeObject(forKey: key) }
        d.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
    }

    /// Demo mode only: the Launch at Login checkbox is shown but never registers anything.
    var demoLaunchAtLogin: Bool {
        get { d.bool(forKey: "demoLaunchAtLogin") }
        set { d.set(newValue, forKey: "demoLaunchAtLogin") }
    }

    var visible: Bool {
        get { d.object(forKey: "visible") as? Bool ?? false }
        set { d.set(newValue, forKey: "visible") }
    }
    var onTop: Bool {
        get { d.object(forKey: "onTop") as? Bool ?? true }
        set { d.set(newValue, forKey: "onTop") }
    }
    var opacity: Double {
        get { Self.clamp(d.object(forKey: "opacity") as? Double ?? 0.85) }
        set { d.set(Self.clamp(newValue), forKey: "opacity") }
    }
    /// Blur of the background behind the window, 0 = sharp see-through, 1 = full frosted glass.
    /// Unset = follows the transparency.
    var blur: Double {
        get { min(1.0, max(0, d.object(forKey: "blur") as? Double ?? opacity)) }
        set { d.set(min(1.0, max(0, (newValue * 100).rounded() / 100)), forKey: "blur") }
    }
    var frame: NSRect? {
        get { (d.string(forKey: "frame")).map(NSRectFromString).flatMap { $0.width > 0 ? $0 : nil } }
        set { d.set(newValue.map(NSStringFromRect), forKey: "frame") }
    }
    var unreadOnly: Bool {
        get { d.bool(forKey: "unreadOnly") }
        set { d.set(newValue, forKey: "unreadOnly") }
    }
    /// Default off: no unsolicited banners.
    var notify: Bool {
        get { d.bool(forKey: "notify") }
        set { d.set(newValue, forKey: "notify") }
    }
    /// Global hotkey ⌃⌥J for "Next unread tab". Default on; turn off if it clashes with another app.
    var hotKey: Bool {
        get { d.object(forKey: "hotKey") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotKey") }
    }
    /// Unread marks by tab id (Ghostty ids, and namespaced ids of external items; pruned to existing ones
    /// on every successful poll).
    var unread: [String: UnreadMark] {
        get { d.data(forKey: "unread").flatMap { try? JSONDecoder().decode([String: UnreadMark].self, from: $0) } ?? [:] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "unread") }
    }
    var busySince: [String: Date] {
        get { (d.dictionary(forKey: "busySince") as? [String: Double])?.mapValues { Date(timeIntervalSince1970: $0) } ?? [:] }
        set { d.set(newValue.mapValues(\.timeIntervalSince1970), forKey: "busySince") }
    }
    /// Last seen state of external items ("busy", "idle", "waiting", "plain") by namespaced id.
    var externalLast: [String: String] {
        get { d.dictionary(forKey: "externalLast") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "externalLast") }
    }

    static func clamp(_ v: Double) -> Double { min(1.0, max(opacityMin, (v * 100).rounded() / 100)) }

    func isPreset(_ v: Double) -> Bool { abs(opacity - v) < 0.025 }
}
