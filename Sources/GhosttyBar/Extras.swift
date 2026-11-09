// Global hotkey (Carbon, no Accessibility permission needed), opt-in "done" notifications,
// launch at login, logging.
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

/// One global hotkey via RegisterEventHotKey. The handler runs on the main thread.
/// Call `unregister()` before dropping the last reference.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let action: () -> Void

    /// keyCode: kVK_* virtual key, modifiers: Carbon mask (controlKey | optionKey ...).
    /// nil when the hotkey can't be registered (e.g. another app already owns the combination).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &spec, me, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4748_4252), id: 1)  // 'GHBR'
        let reg = status == noErr
            ? RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
            : status
        if reg != noErr {
            log("Global hotkey not registered (status \(reg)), maybe another app uses it")
            unregister()
            return nil
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        ref = nil
        handlerRef = nil
    }
}

/// macOS banners when a tab becomes unread. Off by default; authorization is requested only when
/// the user switches the setting on. Clicking a banner jumps to the tab.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: ((String) -> Void)?           // tab id
    private(set) var blocked = false          // denied in System Settings

    override init() {
        super.init()
        center.delegate = self
        refresh { _ in }
    }

    /// Re-reads the permission; `done(true)` when `blocked` changed.
    func refresh(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        center.getNotificationSettings { s in
            let denied = s.authorizationStatus == .denied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let changed = self.blocked != denied
                    self.blocked = denied
                    done(changed)
                }
            }
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks once; `done(true)` when banners may be shown.
    func requestAuthorization(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: [.alert]) { granted, error in
            let msg = error.map { "\($0)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.blocked = !granted
                    if let msg { log("Notification permission request failed: \(msg)") }
                    done(granted)
                }
            }
        }
    }

    func post(_ tab: Tab, bell: Bool) {
        let c = UNMutableNotificationContent()
        c.title = bell ? "Waiting for you: \(tab.title)" : "Done: \(tab.title)"
        c.body = tab.source.map { tab.directory.isEmpty ? $0 : "\($0) · \(tab.directory)" } ?? tab.directory
        c.userInfo = ["tab": tab.id]
        // no sound on purpose: a silent banner is enough
        center.add(UNNotificationRequest(identifier: "tab-\(tab.id)", content: c, trigger: nil)) { error in
            if let error { log("Notification failed: \(error)") }
        }
    }

    func clear(_ tabID: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["tab-\(tabID)"])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["tab"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id { self.onOpen?(id) }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// "Launch at Login" via SMAppService (registers this app bundle as a login item).
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Launch at Login: \(on ? "enable" : "disable") failed: \(error.localizedDescription)")
        }
        if on && status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

// MARK: logging

/// Started from a terminal: log to stderr. Otherwise (Finder, login item, launchd) append to
/// ~/Library/Logs/GhosttyBar.log, which starts over once it passes 1 MB.
func setUpLogging() {
    guard isatty(STDERR_FILENO) == 0, !isDemo else { return }  // demo runs log to stderr only
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("GhosttyBar.log").path
    if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000 {
        try? fm.removeItem(atPath: path)
    }
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    dup2(fd, STDERR_FILENO)
    close(fd)
}

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write("\(f.string(from: Date())) \(msg)\n".data(using: .utf8)!)
}
