import AppKit
import SwiftUI

enum FirstRun {
    static func shouldOfferSetup(configExisted: Bool) -> Bool { !configExisted }

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

    static func merge(chosen: [String], existing: [AppEntry], installed: (String) -> Bool) -> [AppEntry] {
        var result: [AppEntry] = []
        for id in chosen {
            if let old = existing.first(where: { $0.bundleId == id }) {
                result.append(old)
            } else {
                result.append(AppEntry(bundleId: id))
            }
        }
        result += existing.filter { !installed($0.bundleId) && !chosen.contains($0.bundleId) }
        return result
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
    }

    @Published var step = 0
    @Published var candidates: [Candidate] = []
    @Published var isDefault = DefaultBrowser.isDefault
    var onFinish: () -> Void = {}
    private var timer: Timer?

    static let steps = 3

    func load() {
        let me = Bundle.main.bundleIdentifier
        let probe = URL(string: "https://example.com")!
        let browsers = NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { $0 != "com.browserosaurus" }
            .sorted { AppInfo.lookup($0).name.localizedCaseInsensitiveCompare(AppInfo.lookup($1).name) == .orderedAscending }
        let systemDefault = NSWorkspace.shared.urlForApplication(toOpen: probe).flatMap { Bundle(url: $0)?.bundleIdentifier }
        let known = KnownApps.domains.keys
            .filter { !$0.hasPrefix("com.apple.") && Config.isInstalled($0) }
            .sorted { AppInfo.lookup($0).name.localizedCaseInsensitiveCompare(AppInfo.lookup($1).name) == .orderedAscending }
        let existing = Set(Config.exists ? Config.load().apps.map(\.bundleId) : [])
        candidates = FirstRun.order(browsers: browsers, known: known, defaultBrowser: systemDefault, me: me).map { c in
            let info = AppInfo.lookup(c.id)
            return Candidate(id: c.id, name: info.name, icon: info.icon, browser: c.browser,
                             checked: existing.isEmpty ? c.browser : existing.contains(c.id))
        }
        isDefault = DefaultBrowser.isDefault
        step = 0
    }

    func startWatching() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDefault = DefaultBrowser.isDefault }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    var canContinue: Bool { step != 0 || candidates.contains { $0.checked } }

    func finish() {
        stopWatching()
        var cfg = Config.load()
        cfg.apps = FirstRun.merge(chosen: candidates.filter(\.checked).map(\.id), existing: cfg.apps,
                                  installed: Config.isInstalled)
        Config.save(cfg)
        onFinish()
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch m.step {
                case 1: defaultStep
                case 2: profilesStep
                default: appsStep
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .controlSize(.small)
        .frame(width: 480, height: 540)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text("Welcome to \(Identity.appName)").font(.title3.weight(.semibold))
            Text("Choose which app opens each link.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<SetupModel.steps, id: \.self) { i in
                    Capsule()
                        .fill(i == m.step ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.3))
                        .frame(width: i == m.step ? 18 : 6, height: 6)
                }
            }
            .padding(.top, 4)
            .animation(.snappy, value: m.step)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var appsStep: some View {
        Form {
            Section {
                ForEach($m.candidates) { $c in
                    Toggle(isOn: $c.checked) {
                        HStack(spacing: 10) {
                            Image(nsImage: c.icon).resizable().frame(width: 22, height: 22)
                            Text(c.name)
                            if c.browser {
                                Text("Browser").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } header: {
                Text("Choose your apps")
            } footer: {
                Text("Only apps on this Mac are listed. Change this any time in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var defaultStep: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Make \(Identity.appName) your default browser so every link you click comes here first.")
                        .fixedSize(horizontal: false, vertical: true)
                    if m.isDefault {
                        Label("\(Identity.appName) is your default browser", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Make Default Browser") { DefaultBrowser.make() }
                            .buttonStyle(.glassProminent)
                            .controlSize(.regular)
                        Text("macOS asks you to confirm.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Default browser")
            }
        }
        .formStyle(.grouped)
        .onAppear { m.startWatching() }
        .onDisappear { m.stopWatching() }
    }

    private var profilesStep: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("To show each Chrome or Firefox profile as its own choice, allow \(Identity.appName) Full Disk Access. It only reads the browsers' profile lists.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The button copies “Full Disk Access” and opens System Settings: paste it into the search field, then turn on \(Identity.appName).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy & Open System Settings") { Access.openFullDiskAccess() }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Browser profiles (optional)")
            } footer: {
                Text("Skip this if you use one profile per browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            if m.step > 0 {
                Button("Back") { m.step -= 1 }
            }
            Spacer()
            if m.step == SetupModel.steps - 1 {
                Button("Skip") { m.finish(); close() }
                Button("Finish") { m.finish(); close() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { m.step += 1 }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!m.canContinue)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
            let host = NSHostingController(rootView: SetupView(m: model) { [weak self] in self?.window?.close() })
            host.sizingOptions = [.preferredContentSize]
            let w = QuietWindow(contentViewController: host)
            w.title = "Set Up \(Identity.appName)"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace]
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }
}
