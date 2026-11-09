// Floating tab-overview window: NSPanel + NSVisualEffectView background + SwiftUI content.
// The window shows the tab overview plus one inline control (the All | Unread filter pill in the header);
// all other settings live in the menu bar dropdown and the right-click menu.
import AppKit
import SwiftUI

enum Layout {
    static let width: CGFloat = 300
    static let topH: CGFloat = 30      // transparent titlebar row: close button + summary + filter pill
    static let rowH: CGFloat = 22
    static let headerH: CGFloat = 20
    static let headerGap: CGFloat = 4  // extra space above the 2nd+ window header
    static let pad: CGFloat = 8
    static let radius: CGFloat = 12
    static let maxHeightShare: CGFloat = 0.7

    @MainActor static func contentHeight(_ m: TabModel) -> CGFloat {
        if !m.hasContent { return 4 }
        if m.allReadEmptyState { return rowH + pad }
        var h: CGFloat = 0
        for (i, g) in m.groups.enumerated() {
            h += CGFloat(g.tabs.count) * rowH
            if g.title != nil { h += headerH + (i > 0 ? headerGap : 0) }
        }
        return h + pad
    }
}

// MARK: SwiftUI content

struct TabRow: View {
    let tab: Tab
    let status: Status
    let glyph: String
    let detail: String?
    let lowOpacity: Bool
    var dim = false       // offline external source: last known state
    let onClick: () -> Void
    @State private var hover = false

    private var unread: Bool { status == .unread }

    var body: some View {
        HStack(spacing: 6) {
            Text(glyph)
                .font(.system(size: unread ? 13 : 12, weight: unread ? .bold : .regular))
                .foregroundStyle(glyphColor)
                .frame(width: 16)
            Text(tab.title)
                .font(.system(size: 13, weight: unread || tab.selected ? .semibold : .regular))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if tab.isExternal && !tab.directory.isEmpty {
                Text(tab.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(unread ? Color.orange.opacity(0.85) : .white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
            if tab.selected {
                Text("‹").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: Layout.rowH)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hover ? Color.white.opacity(0.13) : (unread ? Color.orange.opacity(0.14) : .clear))
        )
        .opacity(dim ? 0.5 : 1)
        .shadow(color: .black.opacity(lowOpacity ? 0.9 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onClick)
        .help(tab.isExternal ? (tab.url ?? tab.directory) : tab.directory)
    }

    private var glyphColor: Color {
        switch status {
        case .unread: return .orange
        case .busy: return Color(red: 0.55, green: 0.75, blue: 1.0)
        case .read: return .white.opacity(0.45)
        case .plain: return .white.opacity(0.4)
        }
    }

    private var titleColor: Color {
        switch status {
        case .unread: return .orange
        case .busy: return .white
        case .read, .plain: return .white.opacity(0.78)
        }
    }
}

/// Inline two-segment filter "All | Unread N", bound to the persisted unreadOnly setting.
struct FilterPill: View {
    let unreadOnly: Bool
    let unreadCount: Int
    var compact = false   // narrow window: "All | ● 2"
    let lowOpacity: Bool
    let onSelect: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("All", active: !unreadOnly, accent: false) { onSelect(false) }
            segment(unreadLabel, active: unreadOnly,
                    accent: unreadCount > 0) { onSelect(true) }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(lowOpacity ? 0.45 : 0.25)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .fixedSize()
        .help("Show unread only")
    }

    private var unreadLabel: String {
        if compact { return unreadCount > 0 ? "● \(unreadCount)" : "●" }
        return unreadCount > 0 ? "Unread \(unreadCount)" : "Unread"
    }

    private func segment(_ label: String, active: Bool, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(textColor(active: active, accent: accent))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(active ? Color.white.opacity(0.22) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func textColor(active: Bool, accent: Bool) -> Color {
        if accent { return active ? .orange : Color.orange.opacity(0.8) }
        return active ? .white : .white.opacity(0.6)
    }
}

struct TabListView: View {
    @ObservedObject var model: TabModel
    let onClick: (Tab) -> Void
    var onFilter: (Bool) -> Void = { _ in }

    private func header(_ summary: String, compactPill: Bool, low: Bool) -> some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(low ? 0.9 : 0), radius: 2, y: 1)
            Spacer(minLength: 4)
            if model.hasContent {
                FilterPill(unreadOnly: model.unreadOnly, unreadCount: model.unreadCount,
                           compact: compactPill, lowOpacity: low, onSelect: onFilter)
                    .layoutPriority(1)
            }
        }
    }

    var body: some View {
        let low = model.opacity < 0.7
        let groups = model.groups
        VStack(alignment: .leading, spacing: 0) {
            // ViewThatFits picks the first variant whose ideal width fits: narrow windows shorten the
            // summary first, then the pill ("All | ● 2"); the pill is never clipped.
            ViewThatFits(in: .horizontal) {
                header(model.windowSummary, compactPill: false, low: low)
                header(model.windowSummaryShort, compactPill: false, low: low)
                header(model.windowSummaryShort, compactPill: true, low: low)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
            .padding(.trailing, 6)
            .frame(height: Layout.topH)
            // Relative times ("for 4 min") refresh every 30 s even when nothing else changes.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.allReadEmptyState {
                            Text("All read ✓")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                                .shadow(color: .black.opacity(low ? 0.9 : 0), radius: 2, y: 1)
                                .padding(.leading, 28)
                                .frame(height: Layout.rowH)
                        }
                        ForEach(groups, id: \.id) { g in
                            if let title = g.title {
                                HStack(spacing: 0) {
                                    Text(title)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                    if let note = g.note {
                                        Text(" · " + note)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.orange.opacity(0.7))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                .shadow(color: .black.opacity(low ? 0.9 : 0), radius: 2, y: 1)
                                .padding(.leading, 12)
                                .padding(.trailing, 8)
                                .frame(height: Layout.headerH, alignment: .bottom)
                                .padding(.top, g.id == groups.first?.id ? 0 : Layout.headerGap)
                            }
                            ForEach(g.tabs, id: \.id) { t in
                                TabRow(tab: t, status: model.status(t), glyph: model.glyph(t),
                                       detail: model.detail(t, now: ctx.date), lowOpacity: low,
                                       dim: g.dim) { onClick(t) }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, model.hasContent ? Layout.pad : 0)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: AppKit shell

/// Hosting view: right-click anywhere opens the settings menu; first click works without activation.
final class HostingView: NSHostingView<TabListView> {
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Real background blur with an adjustable radius. NSVisualEffectView has no radius (fading it only
/// changes how opaque it looks), so this uses the window server call iTerm2 and Ghostty use for their
/// blur settings. Private API, resolved at runtime; if it is missing nothing breaks, there is just no blur.
@MainActor
enum WindowBlur {
    private typealias MainConn = @convention(c) () -> UInt32
    private typealias SetRadius = @convention(c) (UInt32, UInt32, Int32) -> Int32
    private static let handle = dlopen(nil, RTLD_NOW)
    private static let mainConn: MainConn? = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConn.self) }
    private static let setRadius: SetRadius? = dlsym(handle, "CGSSetWindowBackgroundBlurRadius").map { unsafeBitCast($0, to: SetRadius.self) }
    static let maxRadius = 40.0

    static func apply(_ window: NSWindow, amount: Double) {
        guard window.windowNumber > 0, let mainConn, let setRadius else { return }
        _ = setRadius(mainConn(), UInt32(window.windowNumber), Int32((amount * maxRadius).rounded()))
    }
}

/// Root container (rounded, clipped). Holds tint + content; the blur is the window's own background blur.
final class RootView: NSView {
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

final class TabPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Window-server shape of the window (AppKit private hook). Without it the shape falls back to a
    /// square after moves/resizes, and the background blur then shows square corners around the rounded
    /// content. A stretchable rounded-rect image keeps shape, shadow and blur rounded.
    @objc func _cornerMask() -> NSImage? {
        let r = Layout.radius
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

@MainActor
final class TabWindowController: NSObject, NSWindowDelegate {
    let panel: TabPanel
    let settings: AppSettings
    let model: TabModel
    private let tint = NSView()
    private let host: HostingView
    var onChange: (() -> Void)?        // settings changed -> rebuild status menu
    var menuBuilder: (() -> NSMenu)?   // right-click menu

    init(model: TabModel, settings: AppSettings, onClick: @escaping (Tab) -> Void) {
        self.model = model
        self.settings = settings
        panel = TabPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 120),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView,
                                     .nonactivatingPanel],
                         backing: .buffered, defer: false)
        host = HostingView(rootView: TabListView(model: model, onClick: onClick))
        super.init()
        host.rootView = TabListView(model: model, onClick: onClick) { [weak self] on in self?.setUnreadOnly(on) }

        panel.title = "GhosttyBar"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let root = RootView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 120))
        root.wantsLayer = true
        root.layer?.cornerRadius = Layout.radius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true

        tint.wantsLayer = true
        host.sizingOptions = []
        host.safeAreaRegions = []
        for v in [tint, host] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        let menu: () -> NSMenu = { [weak self] in self?.menuBuilder?() ?? NSMenu() }
        root.contextMenu = menu
        host.contextMenu = menu
        panel.contentView = root

        applyOnTop()
        applyOpacity()
        restoreFrame()
        fitHeight()
        if settings.visible { panel.orderFrontRegardless(); applyOpacity() }
    }

    // MARK: settings

    var isShown: Bool { settings.visible }

    func setVisible(_ show: Bool) {
        settings.visible = show
        if show {
            fitHeight()
            panel.orderFrontRegardless()
            applyOpacity()   // blur radius needs a window number, i.e. an on-screen window
        } else {
            panel.orderOut(nil)
        }
        onChange?()
    }

    func toggle() { setVisible(!settings.visible) }

    func setOnTop(_ on: Bool) {
        settings.onTop = on
        applyOnTop()
        onChange?()
    }

    /// Shared by the inline pill, the dropdown and the right-click menu (one persisted setting).
    func setUnreadOnly(_ on: Bool) {
        guard on != model.unreadOnly else { return }
        model.setUnreadOnly(on)
        fitHeight()
        onChange?()
    }

    func setOpacity(_ v: Double, rebuildMenu: Bool = true) {
        settings.opacity = v
        applyOpacity()
        if rebuildMenu { onChange?() }
    }

    func setBlur(_ v: Double, rebuildMenu: Bool = true) {
        settings.blur = v
        applyOpacity()
        if rebuildMenu { onChange?() }
    }

    private func applyOnTop() {
        if settings.onTop {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = .normal
            panel.collectionBehavior = []
        }
    }

    private func applyOpacity() {
        let op = settings.opacity
        model.opacity = op
        WindowBlur.apply(panel, amount: settings.blur)   // blur slider: radius 0…40
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.92 * op).cgColor
        panel.invalidateShadow()
    }

    // MARK: frame

    private func restoreFrame() {
        if let f = settings.frame {
            let probe = NSPoint(x: f.minX + 20, y: f.maxY - 10)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(probe) }) {
                panel.setFrame(f, display: false)
                return
            }
        }
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrame(NSRect(x: vf.maxX - Layout.width - 20, y: vf.maxY - 140, width: Layout.width, height: 120),
                       display: false)
    }

    private func rememberFrame() {
        let f = panel.frame.integral
        if settings.frame != f { settings.frame = f }
    }

    /// Height follows content (top edge stays put); only width is user-resizable.
    /// The result is clamped into the screen's visible frame (shifted up / left when it would overflow).
    func fitHeight() {
        let vf = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        let maxH = (vf?.height ?? 800) * Layout.maxHeightShare
        let h = min(max(Layout.topH + Layout.contentHeight(model), Layout.topH + 4), maxH)
        panel.contentMinSize = NSSize(width: 200, height: h)
        panel.contentMaxSize = NSSize(width: 900, height: h)
        let f = panel.frame
        var r = NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
        if let vf {
            r.size.width = min(r.width, vf.width)
            r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width)
            if r.minY < vf.minY { r.origin.y = vf.minY }
            if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height }
        }
        if !NSEqualRects(r.integral, f.integral) {
            panel.setFrame(r, display: true)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        setVisible(false)  // close = hide
        return false
    }
}
