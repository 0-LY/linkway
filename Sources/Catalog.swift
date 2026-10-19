import AppKit

enum ProfileKind { case chromium, firefox }

enum KnownApps {
    static let domains: [String: [String]] = [
        "com.linear": ["linear.app"],
        "com.figma.Desktop": ["figma.com"],
        "com.tinyspeck.slackmacgap": ["slack.com"],
        "com.microsoft.teams2": ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"],
        "com.spotify.client": ["open.spotify.com", "spotify.link"],
        "us.zoom.xos": ["zoom.us", "zoom.com"],
        "notion.id": ["notion.so", "notion.site", "notion.com"],
        "com.hnc.Discord": ["discord.com", "discord.gg"],
        "com.loom.desktop": ["loom.com"],
        "com.electron.miro": ["miro.com"],
        "com.clickup.desktop-app": ["app.clickup.com"],
        "com.apple.Music": ["music.apple.com"],
        "com.apple.podcasts": ["podcasts.apple.com"],
        "com.apple.TV": ["tv.apple.com"],
        "com.apple.AppStore": ["apps.apple.com"],
        "com.apple.Maps": ["maps.apple.com"],
        "com.microsoft.Outlook": ["outlook.office.com", "outlook.live.com"],
        "md.obsidian": ["obsidian.md"],
        "com.todoist.mac.Todoist": ["app.todoist.com", "todoist.com"],
        "com.postmanlabs.mac": ["postman.co"],
        "com.anthropic.claudefordesktop": ["claude.ai"],
    ]

    static func host(_ url: URL?) -> String? {
        guard var h = url?.host()?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func matches(_ host: String, _ domains: [String]) -> Bool {
        domains.contains { d in
            let d = d.lowercased().trimmingCharacters(in: .whitespaces)
            return !d.isEmpty && (host == d || host.hasSuffix("." + d))
        }
    }

    static func domains(for entry: AppEntry) -> [String] {
        (domains[entry.bundleId] ?? []) + (entry.domains ?? [])
    }
}

struct BrowserProfile: Hashable {
    let id: String
    let name: String
    let avatar: NSImage?
}

enum Profiles {
    static let chromiumDataDirs: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    nonisolated(unsafe) static var denied = Set<String>()

    static var accessDenied: Bool { !denied.isEmpty }

    static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    static func kind(for bundleId: String) -> ProfileKind? {
        if chromiumDataDirs[bundleId] != nil { return .chromium }
        if bundleId == "org.mozilla.firefox" { return .firefox }
        return nil
    }

    static func list(for bundleId: String) -> [BrowserProfile] {
        switch kind(for: bundleId) {
        case .chromium:
            return chromium(bundleId, dataDir: appSupport.appendingPathComponent(chromiumDataDirs[bundleId]!))
        case .firefox:
            return firefox(bundleId)
        case nil:
            return []
        }
    }

    private static func read(_ url: URL, _ bundleId: String) -> Data? {
        do {
            let d = try Data(contentsOf: url)
            denied.remove(bundleId)
            return d
        } catch {
            let ns = error as NSError
            let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            if ns.code == NSFileReadNoPermissionError || under?.code == Int(EPERM) {
                denied.insert(bundleId)
            }
            return nil
        }
    }

    private static func chromium(_ bundleId: String, dataDir: URL) -> [BrowserProfile] {
        guard let data = read(dataDir.appendingPathComponent("Local State"), bundleId),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        var order = (profile["profiles_order"] as? [String]) ?? []
        for k in cache.keys.sorted() where !order.contains(k) { order.append(k) }
        return order.compactMap { dir in
            guard let info = cache[dir], (info["is_ephemeral"] as? Bool) != true else { return nil }
            let pic = dataDir.appendingPathComponent(dir).appendingPathComponent("Google Profile Picture.png")
            return BrowserProfile(id: dir, name: (info["name"] as? String) ?? dir, avatar: NSImage(contentsOf: pic))
        }
    }

    private static func firefox(_ bundleId: String) -> [BrowserProfile] {
        let base = appSupport.appendingPathComponent("Firefox")
        guard let data = read(base.appendingPathComponent("profiles.ini"), bundleId),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [BrowserProfile] = []
        var name: String?, path: String?, relative = true, isProfile = false
        func flush() {
            if isProfile, let n = name, let p = path {
                let dir = relative ? base.appendingPathComponent(p) : URL(fileURLWithPath: p)
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("prefs.js").path) {
                    out.append(BrowserProfile(id: n, name: n, avatar: nil))
                }
            }
            name = nil; path = nil; relative = true
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { flush(); isProfile = line.hasPrefix("[Profile"); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Name": name = parts[1]
            case "Path": path = parts[1]
            case "IsRelative": relative = parts[1] == "1"
            default: break
            }
        }
        flush()
        return out
    }
}

struct Target {
    let appURL: URL
    let bundleId: String
    let title: String
    let subtitle: String?
    let icon: NSImage
    let avatar: NSImage?
    let key: String
    let profile: String?
    var domains: [String] = []

    var id: String { bundleId + "|" + (profile ?? "") }
}

@MainActor
enum History {
    private static var url: URL {
        Config.fileURL.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    private static var cache: [String: String]?

    private static var store: [String: String] {
        get {
            if let c = cache { return c }
            let d = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            Config.protect(url)
            cache = d
            return d
        }
        set {
            cache = newValue
            Config.lockDirectory()
            if let d = try? JSONEncoder().encode(newValue) { try? d.write(to: url, options: .atomic) }
            Config.protect(url)
        }
    }

    static func key(_ url: URL?) -> String? {
        guard var h = url?.host()?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func last(for url: URL?) -> String? {
        key(url).flatMap { store[$0] }
    }

    static func record(_ url: URL?, _ targetId: String) {
        guard let k = key(url) else { return }
        store[k] = targetId
    }
}

@MainActor
enum Catalog {
    static func build(_ cfg: Config) -> [Target] {
        var out: [Target] = []
        var used = Set<String>()
        func claim(_ k: String?) -> String {
            let k = (k ?? "").lowercased()
            guard k.count == 1, !used.contains(k), Int(k) == nil else { return "" }
            used.insert(k)
            return k
        }
        for entry in cfg.apps where entry.hidden != true {
            let info = AppInfo.lookup(entry.bundleId)
            guard let url = info.url else { continue }
            let all = Profiles.list(for: entry.bundleId)

            if let wanted = entry.profile {
                let p = all.first { $0.id == wanted || $0.name == wanted }
                out.append(Target(appURL: url, bundleId: entry.bundleId,
                                  title: entry.label ?? p?.name ?? wanted, subtitle: info.name,
                                  icon: info.icon, avatar: p?.avatar, key: claim(entry.key),
                                  profile: p?.id ?? wanted, domains: KnownApps.domains(for: entry)))
                continue
            }

            let expand = entry.profiles ?? (Profiles.kind(for: entry.bundleId) == .chromium)
            let excluded = Set(entry.excludeProfiles ?? [])
            let profiles = all.filter { !excluded.contains($0.id) && !excluded.contains($0.name) }
            if expand && profiles.count > 1 {
                for (n, p) in profiles.enumerated() {
                    out.append(Target(appURL: url, bundleId: entry.bundleId, title: p.name,
                                      subtitle: info.name, icon: info.icon, avatar: p.avatar,
                                      key: n == 0 ? claim(entry.key) : "", profile: p.id))
                }
            } else {
                out.append(Target(appURL: url, bundleId: entry.bundleId, title: entry.label ?? info.name,
                                  subtitle: nil, icon: info.icon, avatar: nil,
                                  key: claim(entry.key), profile: nil, domains: KnownApps.domains(for: entry)))
            }
        }
        return out
    }

    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return false }
        return !url.absoluteString.hasPrefix("-")
    }

    static func open(_ urls: [URL], with t: Target, background: Bool) {
        let urls = urls.filter(isSafe)
        guard !urls.isEmpty else { return }
        guard let profile = t.profile, let kind = Profiles.kind(for: t.bundleId) else {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = !background
            NSWorkspace.shared.open(urls, withApplicationAt: t.appURL, configuration: cfg) { _, err in
                if let err = err as NSError? { NSLog("%@: open failed: %@ %ld", Identity.appName, err.domain, err.code) }
            }
            return
        }
        let links = urls.map(\.absoluteString)
        let args: [String] = kind == .chromium
            ? ["--profile-directory=\(profile)", "--"] + links
            : ["-P", profile, "-new-tab"] + links
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleId).isEmpty
        if running, let exe = Bundle(url: t.appURL)?.executableURL {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            do { try p.run() } catch { NSLog("%@: forward failed: %@ %ld", Identity.appName, (error as NSError).domain, (error as NSError).code) }
            if !background {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleId).first?.activate()
                }
            }
        } else {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = args
            cfg.activates = !background
            NSWorkspace.shared.openApplication(at: t.appURL, configuration: cfg) { _, err in
                if let err = err as NSError? { NSLog("%@: launch failed: %@ %ld", Identity.appName, err.domain, err.code) }
            }
        }
    }
}
