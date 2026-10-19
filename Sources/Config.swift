import AppKit
import SwiftUI

struct AppEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var bundleId: String
    var key: String?
    var profile: String?
    var label: String?
    var profiles: Bool?
    var excludeProfiles: [String]?
    var hidden: Bool?
    var domains: [String]?

    enum CodingKeys: String, CodingKey {
        case bundleId, key, profile, label, profiles, excludeProfiles, hidden, domains
    }
}

struct Config: Codable, Equatable {
    var apps: [AppEntry]
    var launchAtLogin: Bool?
    var showMenuBarIcon: Bool?
    var showInDock: Bool?
    var pickerAtCenter: Bool?
    var recommend: Bool?
    var pickerSize: Int?
    var hideProfilesNotice: Bool?

    static let defaultApps: [AppEntry] = [
        .init(bundleId: "com.apple.Safari", key: "s"),
        .init(bundleId: "com.google.Chrome", key: "c"),
        .init(bundleId: "org.mozilla.firefox", key: "f"),
    ]

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(Identity.configDirName)/config.json")
    }

    static var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            lockDirectory()
            protect(fileURL)
            protect(fileURL.deletingLastPathComponent().appendingPathComponent("history.json"))
            return cfg
        }
        let cfg = Config(apps: defaultApps)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("config.unreadable.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: fileURL, to: backup)
                protect(backup)
            }
        }
        save(cfg)
        return cfg
    }

    static func save(_ cfg: Config) {
        lockDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(cfg).write(to: fileURL, options: .atomic)
        protect(fileURL)
    }

    static func lockDirectory() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    static func protect(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum DefaultBrowser {
    static var isDefault: Bool {
        guard let u = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return u.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    static func make() {
        let me = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { _ in }
        }
        NSWorkspace.shared.setDefaultApplication(at: me, toOpen: .html) { _ in }
    }
}

struct AppInfo {
    let url: URL?
    let name: String
    let icon: NSImage

    var installed: Bool { url != nil }

    @MainActor private static var cache: [String: AppInfo] = [:]

    @MainActor static func lookup(_ bundleId: String) -> AppInfo {
        if let hit = cache[bundleId] { return hit }
        let info: AppInfo
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            info = AppInfo(url: url, name: name(of: url), icon: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            info = AppInfo(url: nil, name: bundleId,
                           icon: NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil) ?? NSImage())
        }
        cache[bundleId] = info
        return info
    }

    static func name(of url: URL) -> String {
        var n = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        for prefix in ["Google ", "Microsoft "] where n.hasPrefix(prefix) && n.count > prefix.count + 2 {
            n.removeFirst(prefix.count)
        }
        return n
    }
}

func optionalText(_ b: Binding<String?>) -> Binding<String> {
    Binding(get: { b.wrappedValue ?? "" },
            set: { b.wrappedValue = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
}
