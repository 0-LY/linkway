import AppKit
import SwiftUI

enum FirstRun {
    static func shouldOfferSetup(configExisted: Bool) -> Bool { !configExisted }

    static let browsers: [String] = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "app.zen-browser.zen",
        "com.duckduckgo.macos.browser",
        "org.chromium.Chromium",
        "org.torproject.torbrowser",
    ]

    static func isBrowser(_ id: String) -> Bool { browsers.contains(id) }

    static func realBrowsers(_ handlers: [String]) -> [String] {
        var seen = Set<String>()
        return handlers.filter { isBrowser($0) && seen.insert($0).inserted }
    }

    static func order(browsers: [String], known: [String], defaultBrowser: String?, me: String?) -> [(id: String, browser: Bool)] {
        var out: [(id: String, browser: Bool)] = []
        var seen = Set<String>()
        func push(_ id: String, _ browser: Bool) {
            guard id != me, !seen.contains(id) else { return }
            seen.insert(id)
            out.append((id, browser))
        }
        if let d = defaultBrowser, browsers.contains(d) { push(d, true) }
        browsers.forEach { push($0, true) }
        known.forEach { push($0, false) }
        return out
    }

    static func applyOther(_ other: String?, previous: String?, to cfg: inout Config) {
        if other == SetupModel.askEachTime {
            cfg.linkMode = .ask
        } else {
            if let other, cfg.defaultTarget?.hasPrefix(other + "|") != true { cfg.defaultTarget = other + "|" }
            cfg.linkMode = .direct
        }
        if let previous { cfg.previousDefaultBrowser = previous }
    }

    static func otherChoices(checked: [(id: String, browser: Bool)]) -> [String] {
        let browsers = checked.filter(\.browser).map(\.id)
        return browsers.isEmpty ? checked.map(\.id) : browsers
    }

    static func preferredOther(choices: [String], previous: String?, current: String?) -> String? {
        if let current, choices.contains(current) { return current }
        if let previous, choices.contains(previous) { return previous }
        return choices.first
    }

    static func merge(chosen: [String], existing: [AppEntry]) -> [AppEntry] {
        var result = existing
        var have = Set(existing.map(\.bundleId))
        for id in chosen where have.insert(id).inserted {
            result.append(AppEntry(bundleId: id))
        }
        return result
    }

    struct App: Equatable, Sendable {
        let id: String
        let name: String
    }

    static func search(_ query: String, in apps: [App], excluding: Set<String>, limit: Int = 8) -> [App] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let hits = apps.filter { !excluding.contains($0.id) && $0.name.localizedCaseInsensitiveContains(q) }
        let ranked = hits.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(q.lowercased())
            let pb = b.name.lowercased().hasPrefix(q.lowercased())
            if pa != pb { return pa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        var seen = Set<String>()
        return Array(ranked.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    enum ProfileState: Equatable { case notNeeded, needsAccess, granted }

    static func profileState(profileBrowsers: [String], denied: Bool) -> ProfileState {
        if profileBrowsers.isEmpty { return .notNeeded }
        return denied ? .needsAccess : .granted
    }

    static func appFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
    }

    static func scanApps(folders: [URL] = appFolders()) -> [App] {
        var out: [App] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func visit(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for url in items where !url.lastPathComponent.hasPrefix(".") {
                if url.pathExtension == "app" {
                    guard let b = Bundle(url: url), let id = b.bundleIdentifier, !seen.contains(id) else { continue }
                    seen.insert(id)
                    out.append(App(id: id, name: AppInfo.name(of: url)))
                } else if depth < 1, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(url, depth: depth + 1)
                }
            }
        }
        folders.forEach { visit($0, depth: 0) }
        return out
    }
}

@MainActor
final class SetupModel: ObservableObject {
    struct Candidate: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let browser: Bool
        var checked: Bool
        var existing: Bool = false
    }

    enum Step: Int, CaseIterable { case welcome, apps, other, defaultBrowser, profiles }

    @Published var step = 0
    @Published var candidates: [Candidate] = []
    @Published var query = ""
    @Published var allApps: [FirstRun.App] = []
    @Published var isDefault = false
    @Published var profileState = FirstRun.ProfileState.notNeeded
    @Published var forward = true
    @Published var celebrating = false
    @Published var frames = SetupFrames()
    @Published var other: String?
    var previousDefault: String?
    let preview = PickerModel()
    var onFinish: () -> Void = {}
    var makeDefault: () -> Void = { DefaultBrowser.make() }
    var readDefault: () -> Bool = { DefaultBrowser.isDefault }
    var openFullDiskAccess: () -> Void = { Access.openFullDiskAccess() }
    var readProfiles: ([String]) -> Bool = { ids in
        ids.forEach { _ = Profiles.list(for: $0) }
        return Profiles.accessDenied
    }
    var save: ([String], String?, String?) -> Void = { chosen, other, previous in
        var cfg = Config.load()
        cfg.apps = FirstRun.merge(chosen: chosen, existing: cfg.apps)
        FirstRun.applyOther(other, previous: previous, to: &cfg)
        Config.save(cfg)
    }

    var otherChoices: [Candidate] {
        let ids = FirstRun.otherChoices(checked: candidates.filter(\.checked).map { ($0.id, $0.browser) })
        return ids.compactMap { id in candidates.first { $0.id == id } }
    }

    nonisolated static let askEachTime = "__ask__"

    func syncOther() {
        let ids = otherChoices.map(\.id)
        if let o = other, o == Self.askEachTime || ids.contains(o) { return }
        other = FirstRun.preferredOther(choices: ids, previous: previousDefault, current: nil)
    }
    private var timer: Timer?

    static let count = Step.allCases.count

    var current: Step { Step(rawValue: step) ?? .welcome }

    var results: [FirstRun.App] {
        FirstRun.search(query, in: allApps, excluding: Set(candidates.map(\.id)).union([Bundle.main.bundleIdentifier ?? ""]))
    }

    var profileBrowsers: [String] {
        candidates.filter { $0.checked && Profiles.kind(for: $0.id) != nil }.map(\.id)
    }

    func load() {
        let me = Bundle.main.bundleIdentifier
        let probe = URL(string: "https://example.com")!
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { Bundle(url: $0)?.bundleIdentifier }
        let browsers = FirstRun.realBrowsers(handlers)
            .sorted { AppInfo.lookup($0).name.localizedCaseInsensitiveCompare(AppInfo.lookup($1).name) == .orderedAscending }
        let systemDefault = NSWorkspace.shared.urlForApplication(toOpen: probe).flatMap { Bundle(url: $0)?.bundleIdentifier }
        let stored = Config.exists ? Config.load() : nil
        previousDefault = systemDefault.flatMap { $0 != me && FirstRun.isBrowser($0) ? $0 : nil }
            ?? stored?.previousDefaultBrowser
        let storedOther = stored?.defaultTarget.map { String($0.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        let known = KnownApps.domains.keys
            .filter { !$0.hasPrefix("com.apple.") && Config.isInstalled($0) }
            .sorted { AppInfo.lookup($0).name.localizedCaseInsensitiveCompare(AppInfo.lookup($1).name) == .orderedAscending }
        let existing = Set(Config.exists ? Config.load().apps.map(\.bundleId) : [])
        candidates = FirstRun.order(browsers: browsers, known: known, defaultBrowser: systemDefault, me: me).map { c in
            let info = AppInfo.lookup(c.id)
            return Candidate(id: c.id, name: info.name, icon: info.icon, browser: c.browser,
                             checked: existing.isEmpty ? c.browser : existing.contains(c.id),
                             existing: existing.contains(c.id))
        }
        isDefault = readDefault()
        other = Config.load().linkMode == .ask && Config.exists ? Self.askEachTime
            : FirstRun.preferredOther(choices: otherChoices.map(\.id), previous: previousDefault, current: storedOther)
        step = 0
        query = ""
        forward = true
        celebrating = false
        buildPreview()
        Task.detached(priority: .utility) {
            let apps = FirstRun.scanApps()
            await MainActor.run { self.allApps = apps }
        }
    }

    func buildPreview() {
        let ids = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]
        let targets: [Target] = ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let info = AppInfo.lookup(id)
            return Target(appURL: url, bundleId: id, title: info.name, subtitle: nil, icon: info.icon, avatar: nil,
                          key: String(info.name.prefix(1)).lowercased(), profile: nil)
        }
        preview.urls = [URL(string: "https://example.com/an/article")!]
        preview.targets = Array(targets.prefix(3))
        preview.selected = 0
        preview.recommended = nil
        preview.lastUsed = nil
        preview.size = 0
    }

    func add(_ app: FirstRun.App) {
        let info = AppInfo.lookup(app.id)
        candidates.append(Candidate(id: app.id, name: info.url == nil ? app.name : info.name, icon: info.icon,
                                    browser: FirstRun.isBrowser(app.id), checked: true))
        query = ""
    }

    func refresh() {
        switch current {
        case .defaultBrowser: isDefault = readDefault()
        case .profiles:
            let ids = profileBrowsers
            profileState = FirstRun.profileState(profileBrowsers: ids, denied: ids.isEmpty ? false : readProfiles(ids))
        default: break
        }
    }

    func stepChanged() {
        stopWatching()
        refresh()
        if current == .defaultBrowser || current == .profiles { startWatching() }
    }

    func startWatching() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    var isWatching: Bool { timer != nil }

    func page(_ s: Int) -> SetupPage {
        let name = Identity.appName
        switch Step(rawValue: s) ?? .welcome {
        case .welcome:
            return SetupPage(title: "Welcome to \(name)", subtitle: "Every link opens in the right app. Hold ⌥ to choose.",
                             primary: "Get Started")
        case .apps:
            return SetupPage(title: "Choose your apps", subtitle: "Links open in the apps you pick. Search to add any other app.",
                             primary: "Continue", primaryEnabled: candidates.contains { $0.checked }, back: true)
        case .other:
            return SetupPage(title: "Where should other links open?",
                             subtitle: "Links for Linear, Figma and other apps open there. Everything else opens here.",
                             primary: "Continue", primaryEnabled: other != nil, back: true)
        case .defaultBrowser:
            return SetupPage(title: "Make \(name) your default browser",
                             subtitle: "Every link you click comes here first, so you choose where it opens.",
                             primary: isDefault ? "Continue" : "Make Default Browser", back: true,
                             link: isDefault ? nil : "Not Now")
        case .profiles:
            return SetupPage(title: "See every browser profile",
                             subtitle: "Optional: show each Chrome or Firefox profile as its own choice.",
                             primary: "Finish", back: true, link: profileState == .needsAccess ? "Skip" : nil)
        }
    }

    func primary() {
        switch current {
        case .defaultBrowser where !isDefault:
            makeDefault()
        case .profiles:
            finish()
        default:
            go(1)
        }
    }

    func link() {
        if current == .profiles { finish() } else { go(1) }
    }

    func go(_ delta: Int) {
        forward = delta > 0
        step = max(0, min(Self.count - 1, step + delta))
        if current == .other { syncOther() }
        stepChanged()
    }

    func finish() {
        stopWatching()
        save(candidates.filter(\.checked).map(\.id), other, previousDefault)
        celebrating = true
        onFinish()
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SetupScaffold(step: m.step, count: SetupModel.count, forward: m.forward, celebrating: m.celebrating,
                      page: { m.page($0) },
                      onPrimary: primary, onBack: { m.go(-1) }, onLink: link,
                      report: { m.frames.set($0, $1) }) { s in
            switch SetupModel.Step(rawValue: s) ?? .welcome {
            case .welcome: welcomeContent
            case .apps: appsContent
            case .other: otherContent
            case .defaultBrowser: defaultContent
            case .profiles: profilesContent
            }
        }
        .ignoresSafeArea()
    }

    private func primary() {
        let finishing = m.current == .profiles
        m.primary()
        if finishing { scheduleClose() }
    }

    private func link() {
        let finishing = m.current == .profiles
        m.link()
        if finishing { scheduleClose() }
    }

    private func scheduleClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + SetupHost.celebrationDuration(reduceMotion: reduceMotion)) { close() }
    }

    private var welcomeContent: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PickerView(model: m.preview)
                    .fixedSize()
                    .allowsHitTesting(false)
            }
            .frame(height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Hold ⌥ while you click a link to pick where it opens.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var appsContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for another app", text: $m.query)
                    .textFieldStyle(.plain)
                if !m.query.isEmpty {
                    Button { m.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            SetupBox {
                if m.query.isEmpty { candidateList } else { resultList }
            }
            .frame(height: SetupLayout.contentHeight - 40)
        }
    }

    private var candidateList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(m.candidates.indices), id: \.self) { idx in
                    let c = m.candidates[idx]
                    SetupAppRow(icon: c.icon, name: c.name, tag: c.existing ? "In your list" : (c.browser ? "Browser" : nil)) {
                        Toggle("", isOn: $m.candidates[idx].checked)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(c.existing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if !c.existing { m.candidates[idx].checked.toggle() } }
                    .help(c.existing ? "Already in your list. Remove it in Settings → Apps." : "")
                    if idx < m.candidates.count - 1 { Divider().padding(.leading, 52) }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
        .mask(SetupFade(enabled: m.candidates.count > 4))
    }

    private var resultList: some View {
        let hits = m.results
        return Group {
            if hits.isEmpty {
                VStack {
                    Spacer()
                    Text(m.allApps.isEmpty ? "Looking for apps…" : "No app named “\(m.query)”")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, app in
                            SetupAppRow(icon: AppInfo.lookup(app.id).icon, name: app.name,
                                        tag: FirstRun.isBrowser(app.id) ? "Browser" : nil) {
                                Button("Add") { m.add(app) }
                                    .controlSize(.small)
                            }
                            if i < hits.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .mask(SetupFade(enabled: hits.count > 4))
            }
        }
    }

    private var otherContent: some View {
        SetupBox {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(m.otherChoices.enumerated()), id: \.element.id) { i, c in
                        SetupAppRow(icon: c.icon, name: c.name, tag: nil) {
                            Image(systemName: m.other == c.id ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(m.other == c.id ? Color(nsColor: .controlAccentColor) : .secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { m.other = c.id }
                        Divider().padding(.leading, 52)
                    }
                    SetupAppRow(icon: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) ?? NSImage(),
                                name: "Ask each time", tag: "picker opens for every link") {
                        Image(systemName: m.other == SetupModel.askEachTime ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(m.other == SetupModel.askEachTime ? Color(nsColor: .controlAccentColor) : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { m.other = SetupModel.askEachTime }
                }
                .padding(.vertical, 4)
            }
            .mask(SetupFade(enabled: m.otherChoices.count + 1 > 4))
        }
        .frame(height: SetupLayout.contentHeight - 40)
    }

    private var defaultContent: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            if m.isDefault {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                Text("\(Identity.appName) is your default browser")
                    .font(.headline)
            } else {
                Image(systemName: "link.circle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text("macOS will ask you to confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: m.isDefault)
    }

    private var profilesContent: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            switch m.profileState {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(.green)
                Text("\(Identity.appName) can see your browser profiles").font(.headline)
            case .notNeeded:
                Image(systemName: "person.2.circle")
                    .font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
                Text("None of the browsers you picked use profiles. You can change this later in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            case .needsAccess:
                Image(systemName: "person.2.circle")
                    .font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
                Text("This needs Full Disk Access. \(Identity.appName) only reads the browsers' profile lists.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Full Disk Access") { m.openFullDiskAccess() }
                    .controlSize(.regular)
                Text("Turn on \(Identity.appName) in the list, then come back here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: m.profileState)
    }
}

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private let model = SetupModel()
    private var window: NSWindow?
    var onFinish: () -> Void = {}

    func show() {
        model.load()
        model.onFinish = { [weak self] in self?.onFinish() }
        if window == nil {
            window = SetupHost.makeWindow(SetupView(m: model) { [weak self] in self?.window?.close() }, delegate: self)
        }
        model.stepChanged()
        SetupHost.bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }
}
