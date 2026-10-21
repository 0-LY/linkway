import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    @Published var cfg: Config
    @Published var editing: UUID?
    @Published var dropTarget: UUID?
    @Published var historyCount = 0
    var dragging: UUID?
    @Published var isDefault = false
    @Published var profilesBlocked = false
    @Published var browsers: [URL] = []
    @Published var tab = CommandLine.arguments.first { $0.hasPrefix("--tab=") }.map { String($0.dropFirst(6)) } ?? "apps"
    let preview = PickerModel()
    var onChange: () -> Void = {}
    private var saver: AnyCancellable?

    init() {
        cfg = Config.load()
        refresh()
        saver = $cfg.dropFirst().removeDuplicates().sink { [weak self] new in
            DispatchQueue.main.async {
                guard let self, self.cfg == new else { return }
                self.save()
            }
        }
    }

    func updatePreview() {
        let t = Catalog.build(cfg)
        var host = "example.com"
        var path = "/an/article"
        if let d = t.lazy.compactMap({ $0.domains.first }).first {
            host = d
            path = "/team/issue/ABC-123"
        }
        preview.urls = [URL(string: "https://\(host)\(path)")!]
        let match = (cfg.recommend ?? true) ? t.firstIndex { KnownApps.matches(host, $0.domains) } : nil
        var sample = Array(t.prefix(3))
        if let r = match, r >= 3, sample.count == 3 { sample[2] = t[r] }
        preview.targets = sample
        let rec = match.flatMap { r in sample.firstIndex { $0.id == t[r].id } }
        preview.recommended = rec
        preview.lastUsed = nil
        preview.selected = rec ?? 0
        preview.size = cfg.pickerSize ?? 0
    }

    func refresh() {
        browsers = Self.findBrowsers()
        for b in browsers { if let id = Bundle(url: b)?.bundleIdentifier { _ = Profiles.list(for: id) } }
        for e in cfg.apps { _ = Profiles.list(for: e.bundleId) }
        isDefault = DefaultBrowser.isDefault
        profilesBlocked = Profiles.accessDenied
        updatePreview()
    }

    func save() {
        Config.save(cfg)
        updatePreview()
        onChange()
    }

    private var watcher: Timer?

    func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }

    func watchAccess() {
        guard watcher == nil, profilesBlocked else { return }
        watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if !self.profilesBlocked {
                    self.watcher?.invalidate()
                    self.watcher = nil
                    self.onChange()
                }
            }
        }
    }

    func binding(_ id: UUID) -> Binding<AppEntry> {
        Binding(
            get: { self.cfg.apps.first { $0.id == id } ?? AppEntry(bundleId: "") },
            set: { v in
                if let i = self.cfg.apps.firstIndex(where: { $0.id == id }) { self.cfg.apps[i] = v }
            })
    }

    func index(_ id: UUID) -> Int? { cfg.apps.firstIndex { $0.id == id } }

    func add(_ bundleId: String, profile: String? = nil) {
        cfg.apps.append(AppEntry(bundleId: bundleId, profile: profile, profiles: profile == nil ? nil : false))
    }

    func remove(_ id: UUID) {
        cfg.apps.removeAll { $0.id == id }
        if editing == id { editing = nil }
    }

    var visibleApps: [AppEntry] {
        Config.visibleApps(cfg.apps, installed: { AppInfo.lookup($0).installed })
    }

    func move(_ id: UUID, by delta: Int) {
        let shown = visibleApps.map(\.id)
        guard let i = shown.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < shown.count, let a = index(id), let b = index(shown[j]) else { return }
        cfg.apps.swapAt(a, b)
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = index(id), let to = index(target) else { return }
        cfg.apps.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func chooseApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }

    private static func findBrowsers() -> [URL] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .filter { url in
                guard let id = Bundle(url: url)?.bundleIdentifier, id != me,
                      id != "com.browserosaurus", !seen.contains(id) else { return false }
                seen.insert(id)
                return true
            }
            .sorted { AppInfo.name(of: $0).localizedCaseInsensitiveCompare(AppInfo.name(of: $1)) == .orderedAscending }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    let tab: String

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case "picker": pickerTab
                case "general": generalTab
                default: appsTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Text(appVersion)
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .controlSize(.small)
        .frame(width: 480, height: 580)
    }

    private var appsTab: some View {
        Form {
            Section {
                ForEach(m.visibleApps) { e in
                    AppRow(entry: m.binding(e.id), m: m)
                }

                addButton
            } footer: {
                Text("Drag to reorder · double-click to edit")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if m.profilesBlocked && m.cfg.hideProfilesNotice != true {
                Section {
                    ProfilesNotice(m: m)
                } header: {
                    Text("Browser profiles")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var pickerTab: some View {
        Form {
            Section {
                PickerPreview(m: m, model: m.preview)
                Picker("Size", selection: Binding(get: { m.cfg.pickerSize ?? 0 }, set: { m.cfg.pickerSize = $0 })) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                }
                .pickerStyle(.segmented)
                Picker("Opens", selection: Binding(get: { m.cfg.pickerAtCenter ?? false }, set: { m.cfg.pickerAtCenter = $0 })) {
                    Text("At the pointer").tag(false)
                    Text("Screen center").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(get: { m.cfg.recommend ?? true }, set: { m.cfg.recommend = $0 })) {
                    Text("Recommend the matching app")
                    Text("linear.app → Linear, figma.com → Figma")
                }
            } footer: {
                Text("⇧ background · ⌘C copy link · esc cancel")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section {
                LabeledContent("Default browser") { DefaultBadge(m: m) }
            }
            Section {
                Toggle("Show in menu bar", isOn: flag(\.showMenuBarIcon, true))
                Toggle(isOn: flag(\.showInDock, false)) {
                    Text("Show in Dock")
                    Text("Off hides it from the Dock and ⌘-Tab.")
                }
                Toggle("Open at login", isOn: flag(\.launchAtLogin, true))
            } footer: {
                if !(m.cfg.showMenuBarIcon ?? true) && !(m.cfg.showInDock ?? false) {
                    Text("To come back here, open \(Identity.appName) from Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button("Clear") {
                        History.clear()
                        m.historyCount = 0
                    }
                    .disabled(m.historyCount == 0)
                } label: {
                    Text("Remembered sites")
                    Text(m.historyCount == 1 ? "1 site" : "\(m.historyCount) sites")
                }
                .onAppear { m.historyCount = History.count }
                LabeledContent("Quit \(Identity.appName)") {
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            UpdatesSection()
        }
        .formStyle(.grouped)
    }

    private func flag(_ kp: WritableKeyPath<Config, Bool?>, _ d: Bool) -> Binding<Bool> {
        Binding(get: { m.cfg[keyPath: kp] ?? d }, set: { m.cfg[keyPath: kp] = $0 })
    }

    private var addButton: some View {
        Menu {
            Section("Browsers") {
                ForEach(m.browsers, id: \.self) { url in
                    let id = Bundle(url: url)?.bundleIdentifier ?? ""
                    let ps = Profiles.list(for: id)
                    if ps.count > 1 {
                        Menu(AppInfo.name(of: url)) {
                            Button("Every Profile") { m.add(id) }
                            Divider()
                            ForEach(ps, id: \.id) { p in
                                Button(p.name) { m.add(id, profile: p.id) }
                            }
                        }
                    } else {
                        Button(AppInfo.name(of: url)) { m.add(id) }
                    }
                }
            }
            Divider()
            Button("Other App…") { m.chooseApp() }
        } label: {
            Label("Add App", systemImage: "plus.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

var appVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(Identity.appName) \(version) (\(build))"
}

final class SettingsTabs: NSTabViewController {
    static let lastKey = "settingsPane"
    static let panes = [("apps", "Apps", "square.grid.2x2"), ("picker", "Picker", "cursorarrow.rays"),
                        ("general", "General", "gearshape")]

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.lastKey) }
    }
}

private struct DefaultBadge: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        if m.isDefault {
            Label("Yes", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button("Make Default") {
                DefaultBrowser.make()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { m.refresh() }
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
        }
    }
}

private struct PickerPreview: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var model: PickerModel
    static let height: CGFloat = 230

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            PickerView(model: model)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Text("Hover to try")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.3), in: Capsule())
                .padding(8)
        }
    }
}

private struct ProfilesNotice: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To show each Chrome or Firefox profile as its own choice, allow \(Identity.appName) Full Disk Access once.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Step(n: 1, text: "Click the button below. It copies “Full Disk Access” and opens System Settings.")
                Step(n: 2, text: "Click the search field at the top left, paste (⌘V), and open Full Disk Access.")
                Step(n: 3, text: "Turn on \(Identity.appName) (or click + and choose \(Identity.appName)), then Quit & Reopen.")
            }
            HStack {
                Button("Copy & Open System Settings") { Access.openFullDiskAccess() }
                    .buttonStyle(.glassProminent)
                Button("Restart \(Identity.appName)") { Access.relaunch() }
                Spacer()
                Button("I don't use profiles") { m.cfg.hideProfilesNotice = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .onAppear { m.watchAccess() }
    }
}

private struct Step: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Color(nsColor: .controlAccentColor), in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum Access {
    private static let settingsID = "com.apple.systempreferences"

    static func openFullDiskAccess() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Full Disk Access", forType: .string)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).first {
            running.activate()
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settingsID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open -a \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

private struct AppRow: View {
    @Binding var entry: AppEntry
    @ObservedObject var m: SettingsModel

    var body: some View {
        let info = AppInfo.lookup(entry.bundleId)
        let visible = entry.hidden != true
        let id = entry.id
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .saturation(visible ? 1 : 0)
                .opacity(visible ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label ?? info.name)
                Text(detail(info))
                    .font(.caption)
                    .foregroundStyle(info.installed ? Color.secondary : Color.red)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let k = entry.key {
                Text(k.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help("Shortcut key")
            }
            Toggle("", isOn: Binding(get: { visible }, set: { entry.hidden = $0 ? nil : true }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(visible ? "Shown in the picker" : "Hidden from the picker")
            Menu {
                Button("Edit…") { m.editing = id }
                Divider()
                Button("Move Up") { withAnimation { m.move(id, by: -1) } }
                    .disabled(m.index(id) == 0)
                Button("Move Down") { withAnimation { m.move(id, by: 1) } }
                    .disabled(m.index(id) == m.cfg.apps.count - 1)
                Divider()
                Button("Remove", role: .destructive) { withAnimation { m.remove(id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { m.editing = id }
        .background(m.dropTarget == id && m.dragging != id ? Color(nsColor: .controlAccentColor).opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onDrag {
            m.dragging = id
            return NSItemProvider(object: id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: Binding(
            get: { m.dropTarget == id },
            set: { on in
                if on { m.dropTarget = id } else if m.dropTarget == id { m.dropTarget = nil }
            }
        )) { providers in
            m.dropTarget = nil
            m.dragging = nil
            guard let provider = providers.first else { return false }
            let target = id
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let text = obj as? String, let dragged = UUID(uuidString: text) else { return }
                DispatchQueue.main.async {
                    guard dragged != target else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { m.move(dragged, before: target) }
                }
            }
            return true
        }
        .contextMenu {
            Button("Move Up") { m.move(id, by: -1) }
            Button("Move Down") { m.move(id, by: 1) }
        }
        .popover(isPresented: Binding(get: { m.editing == id }, set: { if !$0 { m.editing = nil } }),
                 arrowEdge: .trailing) {
            AppEditor(entry: $entry, m: m)
        }
    }

    private func detail(_ info: AppInfo) -> String {
        guard info.installed else { return "Not installed" }
        var parts: [String] = []
        if entry.label != nil { parts.append(info.name) }
        if let kind = Profiles.kind(for: entry.bundleId) {
            if let p = entry.profile {
                let name = Profiles.list(for: entry.bundleId).first { $0.id == p }?.name ?? p
                parts.append("Profile: \(name)")
            } else if entry.profiles ?? (kind == .chromium) {
                let n = Profiles.list(for: entry.bundleId).count
                parts.append(n > 1 ? "Every profile (\(n))" : "Every profile")
            } else {
                parts.append("Default profile")
            }
        }
        let sites = KnownApps.domains(for: entry)
        if !sites.isEmpty { parts.append("Recommended for \(sites.prefix(2).joined(separator: ", "))") }
        if entry.hidden == true { parts.append("Hidden") }
        return parts.isEmpty ? "Opens links directly" : parts.joined(separator: " · ")
    }
}

private struct AppEditor: View {
    @Binding var entry: AppEntry
    @ObservedObject var m: SettingsModel

    var body: some View {
        let info = AppInfo.lookup(entry.bundleId)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: info.icon).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text(info.name).font(.headline)
                    Text(entry.bundleId).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 16)

            Form {
                TextField("Name", text: optionalText($entry.label), prompt: Text(info.name))
                TextField("Shortcut key", text: keyBinding, prompt: Text("None"))
                if let kind = Profiles.kind(for: entry.bundleId) {
                    profileControl(kind)
                }
                TextField("Recommend for", text: domainsBinding,
                          prompt: Text(builtIn.isEmpty ? "example.com" : builtIn.joined(separator: ", ")))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Done") { m.editing = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private func profileControl(_ kind: ProfileKind) -> some View {
        let detected = Profiles.list(for: entry.bundleId)
        if detected.isEmpty {
            TextField("Profile", text: optionalText($entry.profile),
                      prompt: Text(kind == .chromium ? "Default, Profile 1…" : "Profile name"))
        } else {
            Picker("Profile", selection: profileSelection(kind)) {
                Text("Every profile").tag("*")
                Text("Default only").tag("-")
                Divider()
                ForEach(detected, id: \.id) { p in Text(p.name).tag(p.id) }
            }
        }
    }

    private func profileSelection(_ kind: ProfileKind) -> Binding<String> {
        Binding(
            get: {
                if let p = entry.profile { return p }
                return (entry.profiles ?? (kind == .chromium)) ? "*" : "-"
            },
            set: { v in
                switch v {
                case "*": entry.profile = nil; entry.profiles = true
                case "-": entry.profile = nil; entry.profiles = false
                default: entry.profile = v; entry.profiles = false
                }
            })
    }

    private var keyBinding: Binding<String> {
        Binding(get: { (entry.key ?? "").uppercased() },
                set: { v in
                    let c = v.lowercased().filter { $0.isLetter }.suffix(1)
                    entry.key = c.isEmpty ? nil : String(c)
                })
    }

    private var builtIn: [String] { KnownApps.domains[entry.bundleId] ?? [] }

    private var domainsBinding: Binding<String> {
        Binding(get: { (entry.domains ?? []).joined(separator: ", ") },
                set: { v in
                    let list = v.split(whereSeparator: { $0 == "," || $0 == " " })
                        .map { String($0).lowercased() }
                        .filter { !$0.isEmpty }
                    entry.domains = list.isEmpty ? nil : list
                })
    }
}

final class QuietWindow: NSWindow {
    override func noResponder(for eventSelector: Selector) {}

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let model = SettingsModel()
    private var window: NSWindow?

    init(onChange: @escaping () -> Void) {
        super.init()
        model.onChange = onChange
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }

    func show() {
        model.cfg = Config.load()
        model.refresh()
        if window == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            for (id, title, symbol) in SettingsTabs.panes {
                let host = NSHostingController(rootView: SettingsView(m: model, tab: id))
                host.sizingOptions = [.preferredContentSize]
                host.title = "\(Identity.appName) — \(title)"
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.identifier = id
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let w = QuietWindow(contentViewController: tabs)
            let start = CommandLine.arguments.first { $0.hasPrefix("--tab=") }.map { String($0.dropFirst(6)) }
                ?? UserDefaults.standard.string(forKey: SettingsTabs.lastKey) ?? "apps"
            tabs.selectedTabViewItemIndex = SettingsTabs.panes.firstIndex { $0.0 == start } ?? 0
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.collectionBehavior = [.moveToActiveSpace]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        bringToFront()
    }

    func sendToBack() {
        window?.orderBack(nil)
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
