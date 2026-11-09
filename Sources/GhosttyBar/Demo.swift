// `--demo`: fixture tabs instead of Ghostty (plus a fixture external source, see External.swift), for
// screenshots and for trying GhosttyBar without Ghostty.
// No AppleScript, no global hotkey, no notifications; settings live in a separate defaults suite
// that is reset on every launch, so a demo can run next to a normal instance.
import Foundation

let isDemo = CommandLine.arguments.contains("--demo")

@MainActor
final class DemoSource: TabSource {
    private var tabs: [Tab]

    var isRunning: Bool { true }
    /// Never "frontmost": tabs are only marked read by clicking them (or "Mark all as read").
    var isFrontmost: Bool { false }

    init() {
        // (window, raw title as Claude Code / Ghostty set it, directory, selected)
        let rows: [(String, String, String, Bool)] = [
            ("w1", "⠂ refactor auth middleware", "~/code/api", false),
            ("w1", "✳ fix flaky e2e test", "~/code/web", false),
            ("w1", "🔔 ✳ upgrade dependencies", "~/code/api", false),
            ("w1", "✳ write release notes", "~/code/cli", true),
            ("w1", "zsh", "~", false),
            ("w2", "⠐ docs: README", "~/code/docs", false),
            ("w2", "✳ add rate limiting", "~/code/api", true),
            ("w2", "✳ investigate memory leak", "~/code/worker", false),
        ]
        var index: [String: Int] = [:]
        tabs = rows.enumerated().map { i, r in
            let (title, state, bell) = parseTitle(r.1)
            index[r.0, default: 0] += 1
            return Tab(windowID: r.0, id: "demo-\(i + 1)", index: index[r.0]!, selected: r.3,
                       inFrontWindow: r.0 == "w1", title: title, state: state, bell: bell, directory: r.2)
        }
    }

    /// Unread marks and busy start times that make the fixtures look like a real afternoon.
    func seed(_ settings: AppSettings, now: Date = Date()) {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func id(_ title: String) -> String { tabs.first { $0.title == title }!.id }
        settings.busySince = [
            id("refactor auth middleware"): ago(4),
            id("docs: README"): ago(12),
        ]
        settings.unread = [
            id("fix flaky e2e test"): UnreadMark(since: ago(3), bell: false),
            id("upgrade dependencies"): UnreadMark(since: ago(1), bell: true),
            id("investigate memory leak"): UnreadMark(since: ago(9), bell: false),
        ]
        settings.visible = true
    }

    func fetchTabs(_ done: @escaping @MainActor @Sendable ([Tab]?) -> Void) {
        done(tabs)
    }

    /// Selects the tab in its window and brings that window to the front.
    func focus(_ tab: Tab) {
        tabs = tabs.map { t in
            let sameWindow = t.windowID == tab.windowID
            return t.with(selected: sameWindow ? t.id == tab.id : t.selected, inFrontWindow: sameWindow)
        }
    }
}
