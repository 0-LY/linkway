import AppKit

enum LinkMode: String, Codable, CaseIterable, Sendable {
    case direct
    case ask
}

struct RouteCandidate: Equatable, Sendable {
    let id: String
    let bundleId: String
    let domains: [String]
    let browser: Bool
}

enum RouteReason: Equatable, Sendable {
    case knownApp
    case remembered
    case fallback
}

enum Route: Equatable, Sendable {
    case picker
    case open(String, RouteReason)
}

struct PickAction: Equatable, Sendable {
    var background = false
    var remember = false

    static func from(_ flags: NSEvent.ModifierFlags, rememberChecked: Bool) -> PickAction {
        PickAction(background: flags.contains(.command), remember: rememberChecked || flags.contains(.shift))
    }
}

enum Router {
    static let optionGrace: TimeInterval = 0.15

    static func decide(mode: LinkMode, optionHeld: Bool, host: String?, candidates: [RouteCandidate],
                       matchApps: Bool, remembered: String?, defaultId: String?, previousDefault: String?) -> Route {
        guard mode == .direct, !optionHeld, !candidates.isEmpty else { return .picker }
        if matchApps, let host,
           let hit = candidates.first(where: { !$0.domains.isEmpty && KnownApps.matches(host, $0.domains) }) {
            return .open(hit.id, .knownApp)
        }
        if let r = resolve(remembered, in: candidates) { return .open(r, .remembered) }
        if let f = fallback(defaultId: defaultId, previousDefault: previousDefault, in: candidates) {
            return .open(f, .fallback)
        }
        return .picker
    }

    static func resolve(_ id: String?, in candidates: [RouteCandidate]) -> String? {
        guard let id, !id.isEmpty else { return nil }
        if candidates.contains(where: { $0.id == id }) { return id }
        let bundle = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
        return candidates.first { $0.bundleId == bundle }?.id
    }

    static func fallback(defaultId: String?, previousDefault: String?, in candidates: [RouteCandidate]) -> String? {
        if let d = resolve(defaultId, in: candidates) { return d }
        if let p = previousDefault, let hit = candidates.first(where: { $0.bundleId == p }) { return hit.id }
        if let b = candidates.first(where: \.browser) { return b.id }
        if let s = candidates.first(where: { $0.bundleId == "com.apple.Safari" }) { return s.id }
        return candidates.first?.id
    }

    static func optionHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.option, .command, .control, .shift]).contains(.option)
    }

    static func shouldShowToast(alreadyShown: Bool, route: Route) -> Bool {
        guard !alreadyShown, case .open = route else { return false }
        return true
    }

    static func toastText(appName: String, target: String) -> String {
        "\(appName) opened this in \(target) · hold ⌥ to choose"
    }

    static func targetName(title: String, subtitle: String?) -> String {
        guard let subtitle, subtitle != title else { return title }
        return "\(subtitle) (\(title))"
    }

    @MainActor static func clipboardURL(_ text: String?) -> URL? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: raw), Catalog.isSafe(url) else { return nil }
        return url
    }

    static func candidates(_ targets: [Target]) -> [RouteCandidate] {
        targets.map { RouteCandidate(id: $0.id, bundleId: $0.bundleId, domains: $0.domains, browser: FirstRun.isBrowser($0.bundleId)) }
    }
}

@MainActor
enum ModifierProbe {
    static func optionNow() -> Bool {
        Router.optionHeld(NSEvent.modifierFlags)
            || Router.optionHeld(NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)))
    }

    static func waitForOption(grace: TimeInterval = Router.optionGrace, _ done: @escaping (Bool) -> Void) {
        if optionNow() { done(true); return }
        let deadline = Date().addingTimeInterval(grace)
        func poll() {
            if optionNow() { done(true); return }
            if Date() >= deadline { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
    }
}
