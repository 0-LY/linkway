import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = PickerModel()
    private lazy var panel: PickerPanel = makePanel()
    private lazy var host = NSHostingView(rootView: PickerView(model: model))
    private lazy var settings = SettingsWindow { [weak self] in self?.configChanged() }
    private var statusItem: NSStatusItem?
    private var targets: [Target] = []
    private var stamp: Date?
    private var gotURL = false
    private var launchedAtLogin = false
    private var otherApp: NSRunningApplication?
    private var activatedAt = Date.distantPast
    private var shownAt = Date.distantPast
    private var cameFromElsewhere = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        if let other = others.first {
            other.activate()
            exit(0)
        }
        launchedAtLogin = Self.isLoginLaunch()
    }

    private static func isLoginLaunch() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 300
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Updates.shared.start()
        let args = CommandLine.arguments
        if args.contains("--make-default") { DefaultBrowser.make() }
        model.onPick = { [weak self] i, bg in self?.open(index: i, background: bg) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                if app == NSRunningApplication.current { self.activatedAt = Date() } else { self.otherApp = app }
            }
        }
        NSApp.mainMenu = makeMainMenu()
        reload()
        applyGeneral()
        _ = panel
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.gotURL, !self.launchedAtLogin,
                  !args.contains("--background"), !args.contains("--make-default") else { return }
            self.settings.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        gotURL = true
        let userWasHere = NSApp.isActive && Date().timeIntervalSince(activatedAt) > 1
        cameFromElsewhere = !userWasHere
        let safe = urls.compactMap(Self.normalize)
        guard !safe.isEmpty else { return }
        show(urls: safe)
        keepSettingsBehind()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        keepSettingsBehind()
    }

    private func keepSettingsBehind() {
        guard cameFromElsewhere, panel.isVisible, settings.isVisible else { return }
        settings.sendToBack()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private static func normalize(_ url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "webloc" else {
            return Catalog.isSafe(url) ? url : nil
        }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let s = plist["URL"] as? String, let u = URL(string: s), Catalog.isSafe(u) else { return nil }
        return u
    }

    private func reload() {
        stamp = Config.modified
        targets = Catalog.build(Config.load())
    }

    private func configChanged() {
        reload()
        applyGeneral()
    }

    private func applyGeneral() {
        let cfg = Config.load()
        let svc = SMAppService.mainApp
        if cfg.launchAtLogin ?? true {
            if svc.status != .enabled { try? svc.register() }
        } else if svc.status == .enabled {
            try? svc.unregister()
        }
        if cfg.showMenuBarIcon ?? true {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                                             accessibilityDescription: Identity.appName)
                let menu = NSMenu()
                menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
                menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
                let def = menu.addItem(withTitle: "Make Default Browser", action: #selector(makeDefault), keyEquivalent: "")
                def.target = self
                def.tag = 1
                menu.addItem(.separator())
                menu.addItem(withTitle: "Quit \(Identity.appName)", action: #selector(quit), keyEquivalent: "q").target = self
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        let policy: NSApplication.ActivationPolicy = (cfg.showInDock ?? false) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if settings.isVisible {
                DispatchQueue.main.async { [weak self] in self?.settings.bringToFront() }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.isHidden = DefaultBrowser.isDefault
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu(Identity.appName, [
            item("About \(Identity.appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(openSettings), ",", target: self),
            item("Check for Updates…", #selector(checkUpdates), "", target: self),
            .separator(),
            item("Hide \(Identity.appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit \(Identity.appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        return main
    }

    @objc private func openSettings() { settings.show() }
    @objc private func checkUpdates() { Updates.shared.checkNow() }
    @objc private func makeDefault() { DefaultBrowser.make() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func makePanel() -> PickerPanel {
        let p = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.animationBehavior = .utilityWindow
        p.delegate = self
        p.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        p.contentView = host
        return p
    }

    private func show(urls: [URL]) {
        if Config.modified != stamp { reload() }
        let cfg = Config.load()
        let list = targets
        var recommended: Int?
        if cfg.recommend ?? true, let host = KnownApps.host(urls.first) {
            recommended = list.firstIndex { KnownApps.matches(host, $0.domains) }
        }
        model.size = cfg.pickerSize ?? 0
        model.urls = urls
        model.targets = list
        let last = History.last(for: urls.first).flatMap { id in list.firstIndex { $0.id == id } }
        model.lastUsed = last
        model.recommended = recommended
        model.selected = last ?? recommended ?? 0
        model.origin = NSEvent.mouseLocation
        shownAt = Date()
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func hide(returnFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.urls = []
        if returnFocus, cameFromElsewhere, NSApp.isActive, let app = otherApp, !app.isTerminated {
            app.activate()
        }
        cameFromElsewhere = false
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { hide() }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let size = panel.frame.size
        if Config.load().pickerAtCenter == true {
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.1))
            return
        }
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height + 14
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        if y < vf.minY + 8 { y = mouse.y - 14 }
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func open(index: Int, background: Bool) {
        let shown = model.targets
        guard index >= 0, index < shown.count, !model.urls.isEmpty else { return }
        let urls = model.urls
        let t = shown[index]
        hide(returnFocus: background)
        History.record(urls.first, t.id)
        Catalog.open(urls, with: t, background: background)
    }

    private func move(_ delta: Int) {
        guard !model.targets.isEmpty else { return }
        model.selected = min(max(model.selected + delta, 0), model.targets.count - 1)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode != 53, Date().timeIntervalSince(shownAt) < 0.3 { return true }
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        let shift = e.modifierFlags.contains(.shift)
        if e.modifierFlags.contains(.command) {
            switch chars {
            case "c":
                if !model.urls.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.urls.map(\.absoluteString).joined(separator: "\n"),
                                                   forType: .string)
                }
                hide()
            case ",": hide(); settings.show()
            case "q": NSApp.terminate(nil)
            case "w": hide()
            default: return false
            }
            return true
        }
        let cols = model.columns
        switch e.keyCode {
        case 53: hide()
        case 36, 76: open(index: model.selected, background: shift)
        case 123: move(-1)
        case 124: move(1)
        case 126: move(-cols)
        case 125: move(cols)
        case 48: move(shift ? -1 : 1)
        default:
            if let d = Int(chars), (1...9).contains(d) {
                open(index: d - 1, background: shift)
            } else if let i = model.targets.firstIndex(where: { !$0.key.isEmpty && $0.key == chars }) {
                open(index: i, background: shift)
            } else {
                return false
            }
        }
        return true
    }
}

if CommandLine.arguments.contains("--login-off") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.run()
}
