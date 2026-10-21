import AppKit
import SwiftUI

final class PickerPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct PickerMetrics {
    let cell: CGFloat
    let icon: CGFloat
    let title: CGFloat
    let sub: CGFloat
    let small: CGFloat
    let pad: CGFloat
    let radius: CGFloat
    let tileRadius: CGFloat

    static func of(_ size: Int) -> PickerMetrics {
        switch size {
        case 2: PickerMetrics(cell: 90, icon: 52, title: 12, sub: 10, small: 11, pad: 14, radius: 28, tileRadius: 18)
        case 1: PickerMetrics(cell: 76, icon: 44, title: 11, sub: 9.5, small: 10.5, pad: 12, radius: 24, tileRadius: 15)
        default: PickerMetrics(cell: 64, icon: 36, title: 10, sub: 9, small: 10, pad: 10, radius: 20, tileRadius: 12)
        }
    }
}

@MainActor
final class PickerModel: ObservableObject {
    @Published var urls: [URL] = []
    @Published var targets: [Target] = []
    @Published var selected = 0
    @Published var lastUsed: Int?
    @Published var recommended: Int?
    @Published var size = 0
    @Published var remember = false
    var origin: NSPoint = .zero
    var onPick: (Int, PickAction) -> Void = { _, _ in }

    var columns: Int { max(1, min(targets.count, 8)) }

    var current: Target? { targets.indices.contains(selected) ? targets[selected] : nil }

    func hover(_ i: Int) {
        let p = NSEvent.mouseLocation
        guard hypot(p.x - origin.x, p.y - origin.y) > 4 else { return }
        origin = NSPoint(x: -10_000, y: -10_000)
        selected = i
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @Environment(\.colorScheme) private var scheme

    private var mt: PickerMetrics { .of(model.size) }
    private let gap: CGFloat = 2

    private var rowWidth: CGFloat {
        CGFloat(model.columns) * mt.cell + CGFloat(model.columns - 1) * gap
    }

    var body: some View {
        VStack(spacing: mt.pad * 0.7) {
            address
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(mt.cell), spacing: gap), count: model.columns),
                      spacing: gap) {
                ForEach(Array(model.targets.enumerated()), id: \.offset) { i, t in
                    Tile(target: t, index: i, mt: mt, selected: i == model.selected,
                         lastUsed: i == model.lastUsed, recommended: i == model.recommended)
                        .onHover { if $0 { model.hover(i) } }
                        .onTapGesture { model.onPick(i, PickAction.from(NSEvent.modifierFlags, rememberChecked: model.remember)) }
                }
            }
            hint
        }
        .frame(width: max(rowWidth, 240))
        .padding(mt.pad)
        .glassEffect(.regular.tint(scheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.45)),
                     in: RoundedRectangle(cornerRadius: mt.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: mt.radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .padding(24)
    }

    private var address: some View {
        HStack(spacing: 4) {
            if let u = model.urls.first {
                Image(systemName: u.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: mt.small - 2, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("\(Text(u.host() ?? u.absoluteString).foregroundStyle(.primary))\(Text(rest(of: u)).foregroundStyle(.primary.opacity(0.6)))")
                    .font(.system(size: mt.small + 1, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.urls.count > 1 {
                    Text("+\(model.urls.count - 1)")
                        .font(.system(size: mt.small - 1, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            } else {
                Text("No link to open").font(.system(size: mt.small + 1, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    private var hint: some View {
        HStack(spacing: 5) {
            if model.current != nil {
                KeyCap("↩", size: mt.small - 1)
                Text("Open")
                Spacer().frame(width: mt.pad)
                Button {
                    model.remember.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.remember ? "checkmark.square.fill" : "square")
                            .foregroundStyle(model.remember ? Color(nsColor: .controlAccentColor) : .primary.opacity(0.6))
                        Text("Remember for this site")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open it there automatically next time · ⇧↩ or R")
            }
        }
        .font(.system(size: mt.small, weight: .medium))
        .foregroundStyle(.primary.opacity(0.75))
        .frame(maxWidth: .infinity)
    }

    private func rest(of u: URL) -> String {
        var s = u.path()
        if let q = u.query() { s += "?" + q }
        return s == "/" ? "" : s
    }
}

private struct KeyCap: View {
    let text: String
    let size: CGFloat
    var inverted = false
    init(_ text: String, size: CGFloat, inverted: Bool = false) {
        self.text = text; self.size = size; self.inverted = inverted
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(inverted ? AnyShapeStyle(Color.black.opacity(0.78)) : AnyShapeStyle(.primary.opacity(0.8)))
            .frame(minWidth: size + 7, minHeight: size + 6)
            .padding(.horizontal, text.count > 2 ? 6 : 2)
            .background(inverted ? Color.white.opacity(0.92) : Color.primary.opacity(0.14), in: Capsule())
    }
}

private struct Tile: View {
    let target: Target
    let index: Int
    let mt: PickerMetrics
    let selected: Bool
    let lastUsed: Bool
    let recommended: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: target.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: mt.icon, height: mt.icon)
                .overlay(alignment: .bottomTrailing) {
                    if let a = target.avatar {
                        Image(nsImage: a)
                            .resizable()
                            .frame(width: mt.icon * 0.44, height: mt.icon * 0.44)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.3), radius: 1.5)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(spacing: 0) {
                Text(target.title)
                    .font(.system(size: mt.title, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                if let s = target.subtitle {
                    Text(s)
                        .font(.system(size: mt.sub))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.top, max(mt.pad, inset + badgeSize * 0.55))
        .padding(.bottom, mt.pad * 0.6)
        .padding(.horizontal, 3)
        .frame(width: mt.cell)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: mt.tileRadius, style: .continuous)
                    .fill(Color(nsColor: .controlAccentColor).gradient)
                    .shadow(color: Color(nsColor: .controlAccentColor).opacity(0.35), radius: 4, y: 2)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: mt.tileRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
            }
        }
        .overlay(alignment: .topLeading) {
            if let k = badge {
                KeyCap(k, size: mt.small - 2, inverted: selected)
                    .frame(minHeight: badgeSize)
                    .padding(.top, inset)
                    .padding(.leading, inset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if recommended {
                Image(systemName: "sparkle")
                    .font(.system(size: mt.small - 2, weight: .bold))
                    .foregroundStyle(selected ? Color(nsColor: .controlAccentColor) : .white)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color(nsColor: .controlAccentColor).gradient), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.75))
                    .padding(.top, inset)
                    .padding(.trailing, inset)
                    .help("Recommended: this link belongs to this app")
            } else if lastUsed {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: mt.small - 2, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.primary.opacity(0.6)))
                    .frame(width: badgeSize, height: badgeSize)
                    .padding(.top, inset)
                    .padding(.trailing, inset)
                    .help("Last used for this site")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: mt.tileRadius, style: .continuous))
        .animation(.snappy(duration: 0.12), value: selected)
    }

    private var badge: String? {
        if !target.key.isEmpty { return target.key.uppercased() }
        return index < 9 ? "\(index + 1)" : nil
    }

    private var badgeSize: CGFloat { mt.small + 5 }

    private var inset: CGFloat { max(4, mt.tileRadius - badgeSize / 2) }
}
