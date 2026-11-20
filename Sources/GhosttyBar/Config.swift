import Foundation

struct Config {
    let values: [String: Any]

    static var empty: Config { Config(values: [:]) }

    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["GHOSTTYBAR_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghosttybar/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("\(url.path): not a JSON object, ignored")
            return .empty
        }
        return Config(values: root)
    }

    func bool(_ key: String) -> Bool? {
        guard let v = values[key] else { return nil }
        guard let b = v as? Bool else {
            log("\(Self.url.path): \"\(key)\" must be true or false")
            return nil
        }
        return b
    }

    func percent(_ key: String) -> Double? {
        guard let v = values[key] else { return nil }
        guard let n = v as? Double else {
            log("\(Self.url.path): \"\(key)\" must be a number from 0 to 100")
            return nil
        }
        return min(100, max(0, n))
    }

    var hotKey: HotKeySpec {
        guard let v = values["hotkey"] else { return .standard }
        guard let text = v as? String, let spec = HotKeySpec.parse(text) else {
            log("\(Self.url.path): can't use \"hotkey\" \(v), using \(HotKeySpec.standard.display)")
            return .standard
        }
        return spec
    }
}

extension AppSettings {
    func apply(_ config: Config) {
        if let v = config.bool("showWindow") { visible = v }
        if let v = config.bool("unreadOnly") { unreadOnly = v }
        if let v = config.bool("groupByWindow") { groupByWindow = v }
        if let v = config.bool("minimizeOthers") { minimizeOthers = v }
        if let v = config.bool("alwaysOnTop") { onTop = v }
        if let v = config.percent("transparency") { opacity = v / 100 }
        if let v = config.percent("blur") { blur = v / 100 }
        if let v = config.bool("globalHotkey") { hotKey = v }
    }
}
