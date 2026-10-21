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
    var layout: [String: CGRect] = [:]
    @Published var forward = true
    @Published var celebrating = false
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
        forward = true
        celebrating = false
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

enum SetupLayout {
    static let size = CGSize(width: 520, height: 600)
    static let headerHeight: CGFloat = 132
    static let contentHeight: CGFloat = 248
    static let primaryWidth: CGFloat = 240
    static let linkRowHeight: CGFloat = 22
}

struct SetupStepInfo {
    let title: String
    let subtitle: String
    let primary: String
    let back: Bool
    let skip: Bool

    static func info(step: Int, isDefault: Bool, appName: String) -> SetupStepInfo {
        switch step {
        case 1:
            return SetupStepInfo(title: "Make \(appName) your default browser",
                                 subtitle: "Every link you click comes here first, so you choose where it opens.",
                                 primary: isDefault ? "Continue" : "Make Default Browser", back: true, skip: !isDefault)
        case 2:
            return SetupStepInfo(title: "See every browser profile",
                                 subtitle: "Optional: show each Chrome or Firefox profile as its own choice.",
                                 primary: "Finish", back: true, skip: true)
        default:
            return SetupStepInfo(title: "Choose your apps",
                                 subtitle: "Links open in the apps you pick. Only apps on this Mac are listed.",
                                 primary: "Continue", back: false, skip: false)
        }
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var info: SetupStepInfo { .info(step: m.step, isDefault: m.isDefault, appName: Identity.appName) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .padding(.top, 34)
                page
                    .frame(width: SetupLayout.size.width, height: SetupLayout.headerHeight + SetupLayout.contentHeight)
                    .clipped()
                Spacer(minLength: 0)
                footer
                    .padding(.bottom, 26)
            }
            if m.celebrating {
                if reduceMotion {
                    DoneMark()
                } else {
                    Confetti()
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: SetupLayout.size.width, height: SetupLayout.size.height)
        .ignoresSafeArea()
        .onChange(of: m.step) { _, step in
            if step == 1 { m.startWatching() } else { m.stopWatching() }
        }
    }

    private var page: some View {
        ZStack {
            stepPage(m.step)
                .id(m.step)
                .transition(transition)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.86), value: m.step)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: m.forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: m.forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func stepPage(_ step: Int) -> some View {
        let i = SetupStepInfo.info(step: step, isDefault: m.isDefault, appName: Identity.appName)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(i.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(i.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 56)
            .padding(.top, 18)
            .frame(height: SetupLayout.headerHeight, alignment: .top)
            Group {
                switch step {
                case 1: defaultContent
                case 2: profilesContent
                default: appsContent
                }
            }
            .frame(width: SetupLayout.size.width - 96, height: SetupLayout.contentHeight)
        }
    }

    private var appsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(m.candidates.indices), id: \.self) { idx in
                    let c = m.candidates[idx]
                    HStack(spacing: 12) {
                        Image(nsImage: c.icon).resizable().frame(width: 26, height: 26)
                        Text(c.name)
                        if c.browser {
                            Text("Browser").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $m.candidates[idx].checked)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { m.candidates[idx].checked.toggle() }
                    if idx < m.candidates.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Image(systemName: "person.2.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("This needs Full Disk Access. \(Identity.appName) only reads the browsers' profile lists.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy & Open System Settings") { Access.openFullDiskAccess() }
                .controlSize(.regular)
            Text("Paste “Full Disk Access” into the search field, then turn on \(Identity.appName).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(0..<SetupModel.steps, id: \.self) { i in
                    Capsule()
                        .fill(i == m.step ? Color(nsColor: .controlAccentColor) : Color.secondary.opacity(0.3))
                        .frame(width: i == m.step ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: m.step)
            Button(action: primary) {
                Text(info.primary)
                    .font(.body.weight(.semibold))
                    .frame(width: SetupLayout.primaryWidth - 32)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(!m.canContinue || m.celebrating)
            .frame(width: SetupLayout.primaryWidth)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { m.layout["primary"] = $0 }
            HStack(spacing: 18) {
                if info.back {
                    Button("Back") { go(-1) }
                        .keyboardShortcut(.cancelAction)
                }
                if info.skip {
                    Button(m.step == SetupModel.steps - 1 ? "Skip" : "Not Now") { skip() }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .frame(height: SetupLayout.linkRowHeight)
            .disabled(m.celebrating)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { m.layout["links"] = $0 }
        }
    }

    private func go(_ delta: Int) {
        m.forward = delta > 0
        m.step = max(0, min(SetupModel.steps - 1, m.step + delta))
    }

    private func primary() {
        if m.step == 1 && !m.isDefault {
            DefaultBrowser.make()
            return
        }
        if m.step == SetupModel.steps - 1 {
            finish()
        } else {
            go(1)
        }
    }

    private func skip() {
        if m.step == SetupModel.steps - 1 { finish() } else { go(1) }
    }

    private func finish() {
        m.finish()
        m.celebrating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 1.1 : 1.6)) { close() }
    }
}

struct DoneMark: View {
    var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let p = min(1, context.date.timeIntervalSince(start) / 0.35)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(.green)
                .padding(28)
                .background(.ultraThinMaterial, in: Circle())
                .opacity(p)
                .scaleEffect(0.9 + 0.1 * p)
        }
    }
}

struct ConfettiPiece {
    let x: CGFloat
    let vx: CGFloat
    let vy: CGFloat
    let spin: Double
    let size: CGSize
    let color: Color
    let round: Bool
    let delay: Double

    static let palette: [Color] = [
        Color(red: 0xCD / 255, green: 0xD1 / 255, blue: 0xA6 / 255),
        Color(red: 0x95 / 255, green: 0x9B / 255, blue: 0x6C / 255),
        Color(red: 0x4B / 255, green: 0x4E / 255, blue: 0x52 / 255),
        Color(red: 0xCD / 255, green: 0xD1 / 255, blue: 0xA6 / 255),
        Color(red: 1.0, green: 0.42, blue: 0.42),
        Color(red: 0.36, green: 0.68, blue: 1.0),
        Color(red: 1.0, green: 0.8, blue: 0.3),
    ]

    static func burst(count: Int = 90, seed: UInt64 = 7) -> [ConfettiPiece] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            ConfettiPiece(x: CGFloat(rng.next(in: 0.2...0.8)),
                          vx: CGFloat(rng.next(in: -260...260)),
                          vy: CGFloat(rng.next(in: -720 ... -380)),
                          spin: rng.next(in: -8...8),
                          size: CGSize(width: rng.next(in: 6...10), height: rng.next(in: 9...15)),
                          color: palette[Int(rng.next(in: 0...Double(palette.count) - 0.001))],
                          round: rng.next(in: 0...1) < 0.25,
                          delay: rng.next(in: 0...0.12))
        }
    }

    func position(at t: Double, in size: CGSize) -> CGPoint {
        let tt = max(0, t - delay)
        let gravity = 900.0
        let px = Double(x * size.width) + Double(vx) * tt
        let py = Double(size.height) * 0.55 + Double(vy) * tt + 0.5 * gravity * tt * tt
        return CGPoint(x: px, y: py)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUnit() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}

struct Confetti: View {
    var start = Date()
    private let pieces = ConfettiPiece.burst()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { ctx, size in
                let fade = t > 1.1 ? max(0, 1 - (t - 1.1) / 0.45) : 1
                for p in pieces where t >= p.delay {
                    let pos = p.position(at: t, in: size)
                    var c = ctx
                    c.opacity = fade
                    c.translateBy(x: pos.x, y: pos.y)
                    c.rotate(by: .radians(p.spin * (t - p.delay)))
                    let rect = CGRect(x: -p.size.width / 2, y: -p.size.height / 2, width: p.size.width, height: p.size.height)
                    let shape = p.round ? Path(ellipseIn: rect.insetBy(dx: 0, dy: (p.size.height - p.size.width) / 2)) : Path(roundedRect: rect, cornerRadius: 2)
                    c.fill(shape, with: .color(p.color))
                }
            }
        }
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
            host.safeAreaRegions = []
            let w = QuietWindow(contentViewController: host)
            w.title = "Set Up \(Identity.appName)"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
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
