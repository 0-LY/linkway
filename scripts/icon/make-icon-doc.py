import json, os, sys

out = sys.argv[1]
os.makedirs(f"{out}/Assets", exist_ok=True)
for f in os.listdir(f"{out}/Assets"):
    os.remove(f"{out}/Assets/{f}")


def p3(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"display-p3:{r:.4f},{g:.4f},{b:.4f},1.0"


BG = [p3("#4B4E52"), p3("#1C1E20")]
INK = p3("#CDD1A6")
INK2 = p3("#868C5E")
W = 66


def svg(name, body):
    with open(f"{out}/Assets/{name}", "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                f'<g fill="#FFFFFF">{body}</g></svg>')


def stroke(d):
    return (f'<path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="{W}" '
            'stroke-linecap="round" stroke-linejoin="round"/>')


def dot(x, y, r=62):
    return f'<circle cx="{x}" cy="{y}" r="{r}"/>'


concept = sys.argv[2] if len(sys.argv) > 2 else "routes"


def stadium(cx, cy, w, h, t):
    r, ri = h / 2, h / 2 - t
    x0, y0 = cx - w / 2, cy - h / 2
    outer = (f"M{x0 + r},{y0} H{x0 + w - r} A{r},{r} 0 0 1 {x0 + w - r},{y0 + h} "
             f"H{x0 + r} A{r},{r} 0 0 1 {x0 + r},{y0} Z")
    xi, yi, wi, hi = x0 + t, y0 + t, w - 2 * t, h - 2 * t
    inner = (f"M{xi + ri},{yi} H{xi + wi - ri} A{ri},{ri} 0 0 1 {xi + wi - ri},{yi + hi} "
             f"H{xi + ri} A{ri},{ri} 0 0 1 {xi + ri},{yi} Z")
    return f'<path fill-rule="evenodd" d="{outer} {inner}"/>'


if concept == "routes":
    svg("back.svg",
        stroke("M420,610 C505,525 485,369 524,236") + stroke("M420,610 C505,525 661,545 794,509")
        + dot(530, 216, 56) + dot(812, 504, 56))
    svg("front.svg", stroke("M236,794 L700,330") + dot(716, 314, 64) + dot(228, 802, 46))
elif concept == "needle":
    place = '<g transform="translate(512 512) rotate(40)" stroke="#FFFFFF" stroke-width="34" stroke-linejoin="round">'
    svg("front.svg", f'{place}<path d="M4,-420 L152,40 L4,320 Z"/></g>')
    svg("back.svg", f'{place}<path d="M-4,-420 L-152,40 L-4,320 Z"/></g>')
elif concept == "fork":
    svg("back.svg",
        stroke("M512,640 C512,520 316,520 316,390") + stroke("M512,640 C512,520 708,520 708,390")
        + dot(316, 316) + dot(708, 316))
    svg("front.svg", stroke("M512,740 L512,360") + dot(512, 276, 70) + dot(512, 774, 50))
else:
    svg("back.svg", f'<g transform="rotate(-45 512 512)">{stadium(392, 512, 420, 220, 72)}</g>')
    svg("front.svg", f'<g transform="rotate(-45 512 512)">{stadium(632, 512, 420, 220, 72)}</g>')

doc = {
    "fill": {"linear-gradient": BG},
    "groups": [
        {"layers": [{"image-name": "front.svg", "name": "front", "glass": True, "fill": {"solid": INK}}],
         "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.25},
         "specular": True},
        {"layers": [{"image-name": "back.svg", "name": "back", "glass": True, "fill": {"solid": INK2}}],
         "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.25},
         "specular": True},
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
with open(f"{out}/icon.json", "w") as f:
    json.dump(doc, f, indent=2)
print(out)
