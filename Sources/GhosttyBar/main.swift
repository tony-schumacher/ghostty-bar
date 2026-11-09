// GhosttyBar: menu bar overview of all Ghostty tabs + optional floating window.
// Menu bar title "≡", or "● N" when N tabs are unread (finished or rang the bell while you weren't looking).
// ⌃⌥J jumps to the next unread tab from anywhere. `--demo` shows fixture tabs instead of Ghostty.
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// NSMenuItem whose action is a closure (the item retains it).
@MainActor
final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Slider as a menu item view (transparency, blur); live update while dragging.
@MainActor
final class SliderItem: NSMenuItem {
    private let handler: (Double) -> Void
    init(value: Double, min minValue: Double = opacityMin, _ handler: @escaping (Double) -> Void) {
        self.handler = handler
        super.init(title: "Slider", action: nil, keyEquivalent: "")
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let s = NSSlider(value: value, minValue: minValue, maxValue: 1.0, target: self, action: #selector(changed(_:)))
        s.isContinuous = true
        s.frame = NSRect(x: 20, y: 4, width: 164, height: 20)
        v.addSubview(s)
        view = v
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func changed(_ s: NSSlider) { handler(s.doubleValue) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings: AppSettings
    let model: TabModel
    let source: TabSource
    let externals: ExternalSources
    var notifier: Notifier?             // nil in demo mode
    var hotKey: HotKey?
    var statusItem: NSStatusItem!
    var window: TabWindowController!
    var timer: Timer?
    var lastPoll = Date.distantPast
    var sigSource: DispatchSourceSignal?
    var quitSources: [DispatchSourceSignal] = []
    var menuOpen = false
    var menuDirty = false

    override init() {
        if isDemo {
            let demo = DemoSource()
            settings = AppSettings(freshSuite: AppSettings.domain + ".demo")
            demo.seed(settings)
            source = demo
        } else {
            settings = AppSettings()
            source = GhosttyClient()
        }
        model = TabModel(settings: settings)
        externals = ExternalSources(demo: isDemo)
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "≡"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        window = TabWindowController(model: model, settings: settings) { [weak self] t in self?.focus(t) }
        window.onChange = { [weak self] in self?.rebuildMenu() }
        window.menuBuilder = { [weak self] in self?.contextMenu() ?? NSMenu() }

        if !isDemo {
            let n = Notifier()
            n.onOpen = { [weak self] id in
                guard let self, let t = self.model.tabs.first(where: { $0.id == id }) else { return }
                self.focus(t)
            }
            notifier = n
        }
        applyHotKey()

        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.window.toggle() } }
        src.resume()
        sigSource = src
        if isDemo {
            // Ctrl-C / kill quits cleanly, so the demo settings get removed.
            for sig in [SIGINT, SIGTERM] {
                quitSources.append(onSignalEvenInMenu(sig) { [weak self] in
                    self?.settings.removeAll()
                    NSApp.terminate(nil)
                })
            }
            // `kill -USR2`: opens the dropdown, so screenshots of it can be scripted.
            signal(SIGUSR2, SIG_IGN)
            let m = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
            m.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.statusItem.button?.performClick(nil) } }
            m.resume()
            quitSources.append(m)
        }

        externals.onConfig = { [weak self] names in
            guard let self else { return }
            let before = Set(self.model.unread.keys)
            self.model.setExternalSources(names)
            self.afterApply((true, []), unreadBefore: before)
        }
        externals.onResult = { [weak self] name, result in
            guard let self else { return }
            let before = Set(self.model.unread.keys)
            let r = self.model.applyExternal(name, items: result.items, error: result.error)
            self.afterApply(r, unreadBefore: before)
        }

        poll()
        externals.tick()
        rebuildMenu()
        // Adaptive: every 0.7 s while Ghostty is frontmost (fast read detection), else every 2 s.
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.source.isFrontmost || Date().timeIntervalSince(self.lastPoll) >= 2.0 { self.poll() }
                self.externals.tick()   // runs each external source on its own interval
            }
        }
        RunLoop.main.add(t, forMode: .common)  // keep polling while a menu is open
        timer = t
        // Poll right away when Ghostty comes to the front instead of waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { if self?.source.isFrontmost == true { self?.poll() } } }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        log("GhosttyBar \(version) started\(isDemo ? " in demo mode" : ""), pid \(getpid()), \(model.unreadCount) unread")
    }

    func applicationWillTerminate(_ n: Notification) {
        if isDemo { settings.removeAll() }  // leave no demo settings behind
    }

    // MARK: polling

    /// Fetch runs off-main (GhosttyClient); the result is applied here on main.
    func poll() {
        // Ghostty must be frontmost both when the snapshot is requested and when it is applied, so a
        // stale snapshot (AppleScript can take a moment) never counts as "looked at".
        lastPoll = Date()
        let frontBefore = source.isFrontmost
        source.fetchTabs { [weak self] fresh in
            guard let self else { return }
            let before = Set(self.model.unread.keys)
            let r = self.model.apply(fresh, running: self.source.isRunning,
                                     front: frontBefore && self.source.isFrontmost)
            self.afterApply(r, unreadBefore: before)
        }
    }

    /// After a Ghostty poll or an external source result: redraw, notify, clear stale banners.
    private func afterApply(_ r: (changed: Bool, newlyUnread: [Tab]), unreadBefore: Set<String>) {
        if r.changed {
            rebuildMenu()
            window.fitHeight()
        }
        if let notifier, settings.notify {
            for t in r.newlyUnread { notifier.post(t, bell: model.unread[t.id]?.bell == true) }
        }
        for id in unreadBefore.subtracting(model.unread.keys) { notifier?.clear(id) }
        updateTitle()
    }

    func updateTitle() {
        let n = model.unreadCount
        let title = n > 0 ? "● \(n)" : "≡"
        if statusItem.button?.title != title { statusItem.button?.title = title }
    }

    // MARK: menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menuDirty { rebuildMenu() }  // e.g. slider moved in the right-click menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        // The permission can change in System Settings while we run; the result shows on the next open.
        notifier?.refresh { [weak self] changed in if changed { self?.rebuildMenu() } }
        rebuildMenu()                  // fresh relative times
        menuOpen = true
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if menuDirty { rebuildMenu() }
    }

    /// Rebuilds the dropdown. Deferred while it is open (keeps the slider usable).
    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        if menuOpen { menuDirty = true; return }
        menuDirty = false
        menu.removeAllItems()
        menu.addItem(disabledItem(model.summary))

        if model.hasContent {
            // Demo mode never registers the hotkey but shows the menu as a real instance would.
            let hotKeyActive = hotKey != nil || (isDemo && settings.hotKey)
            let next = ClosureItem("Next unread tab", key: hotKeyActive ? "j" : "") { [weak self] in self?.nextUnread() }
            next.keyEquivalentModifierMask = [.control, .option]  // shows ⌃⌥J (global hotkey)
            next.isEnabled = model.unreadCount > 0
            menu.addItem(next)
            let all = ClosureItem("Mark all as read") { [weak self] in self?.markAllRead() }
            all.isEnabled = model.unreadCount > 0
            menu.addItem(all)
            menu.addItem(.separator())

            if model.allReadEmptyState { menu.addItem(disabledItem("All read ✓")) }
            let groups = model.groups
            let now = Date()
            for (gi, g) in groups.enumerated() {
                if gi > 0 { menu.addItem(.separator()) }
                if let title = g.title {
                    menu.addItem(disabledItem(g.note.map { "\(title) · \($0)" } ?? title))
                }
                for t in g.tabs {
                    let item = ClosureItem(t.title) { [weak self] in self?.focus(t) }
                    item.attributedTitle = rowTitle(t, now: now, dim: g.dim)
                    let tip = t.isExternal ? (t.url ?? t.directory) : t.directory
                    if !tip.isEmpty { item.toolTip = tip }
                    menu.addItem(item)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem(window.isShown ? "Hide window" : "Show window") { [weak self] in
            guard let self else { return }
            self.window.setVisible(!self.window.isShown)
        })
        addSettingsItems(to: menu)
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Quit") { NSApp.terminate(nil) })
    }

    /// "● fix flaky test   done 2 min ago   ‹": glyph colored by status, unread bold, detail dimmed.
    private func rowTitle(_ t: Tab, now: Date, dim: Bool = false) -> NSAttributedString {
        let st = model.status(t)
        let base = NSFont.menuFont(ofSize: 0)
        let size = base.pointSize
        let glyphColor: NSColor = switch st {
        case _ where dim: .tertiaryLabelColor
        case .unread: .systemOrange
        case .busy: .systemBlue
        case .read, .plain: .tertiaryLabelColor
        }
        let s = NSMutableAttributedString(string: model.glyph(t) + "  ",
                                          attributes: [.font: base, .foregroundColor: glyphColor])
        s.append(NSAttributedString(string: t.title, attributes: [
            .font: st == .unread ? NSFont.boldSystemFont(ofSize: size) : base,
            .foregroundColor: (dim || st == .read || st == .plain) ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        if t.isExternal && !t.directory.isEmpty {
            s.append(NSAttributedString(string: "  " + t.directory, attributes: [
                .font: NSFont.systemFont(ofSize: size - 2), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        if let d = model.detail(t, now: now) {
            s.append(NSAttributedString(string: "   " + d, attributes: [
                .font: NSFont.systemFont(ofSize: size - 2),
                .foregroundColor: st == .unread ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
            ]))
        }
        if t.selected {
            s.append(NSAttributedString(string: "   ‹", attributes: [.font: base, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return s
    }

    /// Info row without action (greyed).
    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addSettingsItems(to menu: NSMenu) {
        menu.addItem(ClosureItem("Show unread only", checked: model.unreadOnly) { [weak self] in
            guard let self else { return }
            self.window.setUnreadOnly(!self.model.unreadOnly)
        })
        menu.addItem(ClosureItem("Always on top", checked: settings.onTop) { [weak self] in
            guard let self else { return }
            self.window.setOnTop(!self.settings.onTop)
        })
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(SliderItem(value: settings.opacity) { [weak self] v in
            self?.window.setOpacity(v, rebuildMenu: false)
            self?.menuDirty = true  // preset checkmarks refresh on close / next open
        })
        sub.addItem(.separator())
        for v in opacityPresets {
            sub.addItem(ClosureItem("\(Int((v * 100).rounded())) %", checked: settings.isPreset(v)) { [weak self] in
                self?.window.setOpacity(v)
            })
        }
        let parent = NSMenuItem(title: "Transparency", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        // Blur strength of what shows through, independent of the background tint.
        let blurSub = NSMenu()
        blurSub.autoenablesItems = false
        blurSub.addItem(SliderItem(value: settings.blur, min: 0) { [weak self] v in
            self?.window.setBlur(v, rebuildMenu: false)
            self?.menuDirty = true
        })
        blurSub.addItem(.separator())
        for v in blurPresets {
            let title = v == 0 ? "Off" : "\(Int((v * 100).rounded())) %"
            blurSub.addItem(ClosureItem(title, checked: abs(settings.blur - v) < 0.025) { [weak self] in
                self?.window.setBlur(v)
            })
        }
        let blurParent = NSMenuItem(title: "Blur", action: nil, keyEquivalent: "")
        blurParent.submenu = blurSub
        menu.addItem(blurParent)
        let blocked = notifier?.blocked ?? false
        let notify = ClosureItem(blocked ? "Notify when done (off in System Settings)" : "Notify when done",
                                 checked: settings.notify && !blocked) { [weak self] in self?.toggleNotify() }
        menu.addItem(notify)
        let failed = settings.hotKey && hotKey == nil && !isDemo
        menu.addItem(ClosureItem(failed ? "Global hotkey ⌃⌥J (unavailable)" : "Global hotkey ⌃⌥J",
                                 checked: settings.hotKey && !failed) { [weak self] in self?.toggleHotKey() })
    }

    /// Checked = registered as login item. "Requires approval" = the user must allow it in System Settings.
    private func loginItem() -> NSMenuItem {
        if isDemo {  // shown like a real instance, but never registers the demo binary as a login item
            return ClosureItem("Launch at Login", checked: settings.demoLaunchAtLogin) { [weak self] in
                guard let self else { return }
                self.settings.demoLaunchAtLogin.toggle()
                self.rebuildMenu()
            }
        }
        let status = LoginItem.status
        let pending = status == .requiresApproval
        return ClosureItem(pending ? "Launch at Login (allow in System Settings)" : "Launch at Login",
                           checked: status == .enabled) { [weak self] in
            if pending { SMAppService.openSystemSettingsLoginItems() } else { LoginItem.set(status != .enabled) }
            self?.rebuildMenu()
        }
    }

    /// Right-click menu on the window: same settings + hide.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addSettingsItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Hide window") { [weak self] in self?.window.setVisible(false) })
        return menu
    }

    // MARK: actions

    /// Click, hotkey or banner. Ghostty tab: bring it to the front. External item: open its url, if any.
    func focus(_ t: Tab) {
        if t.isExternal {
            if let u = t.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
        } else {
            source.focus(t)
        }
        if model.unread[t.id] != nil { log("read (jumped to): \(t.title)") }
        model.jumped(t.id)
        notifier?.clear(t.id)
        afterReadChange()
        if isDemo && !t.isExternal { poll() }  // show the new selection right away
    }

    func nextUnread() {
        if let t = model.nextUnread { focus(t) }
    }

    func markAllRead() {
        for id in model.unread.keys { notifier?.clear(id) }
        model.markAllRead()
        log("marked all as read")
        afterReadChange()
    }

    private func afterReadChange() {
        updateTitle()
        rebuildMenu()
        window.fitHeight()
    }

    func toggleNotify() {
        if let notifier, notifier.blocked {
            // Denied in System Settings: asking again returns false at once, so send the user there.
            Notifier.openSystemSettings()
            return
        }
        guard let notifier, !settings.notify else {
            settings.notify.toggle()   // switching off, or demo mode (setting only, never posts)
            rebuildMenu()
            return
        }
        notifier.requestAuthorization { [weak self] granted in
            guard let self else { return }
            self.settings.notify = granted
            if !granted { log("Notifications not allowed, setting stays off") }
            self.rebuildMenu()
        }
    }

    func toggleHotKey() {
        // On but not registered (another app owns ⌃⌥J): a click retries once. If ⌃⌥J is still taken,
        // the setting switches off, so a permanent clash never leaves it stuck on.
        let failed = settings.hotKey && hotKey == nil && !isDemo
        if !failed { settings.hotKey.toggle() }
        applyHotKey()
        if failed && hotKey == nil {
            settings.hotKey = false
            log("Global hotkey still taken, turned it off")
        }
        rebuildMenu()
    }

    /// ⌃⌥J jumps to the next unread tab from anywhere. Never registered in demo mode.
    func applyHotKey() {
        if settings.hotKey && !isDemo {
            if hotKey == nil {
                hotKey = HotKey(keyCode: kVK_ANSI_J, modifiers: controlKey | optionKey) { [weak self] in self?.nextUnread() }
            }
        } else {
            hotKey?.unregister()
            hotKey = nil
        }
    }
}

/// Runs `action` on the main thread when `sig` arrives, also while a menu is open (the main queue is not
/// serviced during menu tracking, a common-modes run loop block is).
nonisolated func onSignalEvenInMenu(_ sig: Int32, _ action: @escaping @MainActor @Sendable () -> Void) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { @Sendable in
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { action() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    src.resume()
    return src
}

setUpLogging()
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
