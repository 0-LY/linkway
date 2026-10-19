import AppKit

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = r.midX + r.width / 2 * copysign(pow(abs(ct), 2 / n), ct)
        let y = r.midY + r.height / 2 * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func orb(_ ctx: CGContext, at p: CGPoint, r: CGFloat, top: CGColor, bottom: CGColor) {
    let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(10, 20, 80, 0.35))
    ctx.setFillColor(bottom)
    ctx.fillEllipse(in: rect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    linear(ctx, [top, bottom], [0, 1], from: CGPoint(x: p.x, y: p.y + r), to: CGPoint(x: p.x, y: p.y - r))
    let hl = CGRect(x: p.x - r * 0.62, y: p.y + r * 0.08, width: r * 1.24, height: r * 0.82)
    ctx.addEllipse(in: hl)
    ctx.clip()
    linear(ctx, [c(255, 255, 255, 0.75), c(255, 255, 255, 0.0)], [0, 1],
           from: CGPoint(x: p.x, y: hl.maxY), to: CGPoint(x: p.x, y: hl.minY))
    ctx.restoreGState()

    ctx.setStrokeColor(c(255, 255, 255, 0.95))
    ctx.setLineWidth(9)
    ctx.strokeEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
}

func draw(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: c(0, 0, 0, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(c(40, 60, 200))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    linear(ctx, [c(132, 98, 255), c(70, 110, 255), c(18, 196, 255)], [0, 0.5, 1],
           from: CGPoint(x: 300, y: 924), to: CGPoint(x: 724, y: 100))
    radial(ctx, [c(255, 255, 255, 0.30), c(255, 255, 255, 0)], center: CGPoint(x: 330, y: 860), radius: 560)
    radial(ctx, [c(0, 255, 220, 0.22), c(0, 255, 220, 0)], center: CGPoint(x: 820, y: 160), radius: 460)

    let stemBottom = CGPoint(x: 512, y: 230)
    let fork = CGPoint(x: 512, y: 470)
    let ends = [CGPoint(x: 300, y: 700), CGPoint(x: 512, y: 760), CGPoint(x: 724, y: 700)]

    let path = CGMutablePath()
    path.move(to: stemBottom)
    path.addLine(to: fork)
    for e in ends {
        path.move(to: fork)
        path.addCurve(to: e, control1: CGPoint(x: fork.x, y: fork.y + 120),
                      control2: CGPoint(x: e.x, y: e.y - 150))
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: c(10, 20, 90, 0.35))
    ctx.addPath(path)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(58)
    ctx.setStrokeColor(c(255, 255, 255, 0.96))
    ctx.strokePath()
    ctx.restoreGState()

    orb(ctx, at: ends[0], r: 70, top: c(255, 150, 120), bottom: c(255, 70, 90))
    orb(ctx, at: ends[1], r: 78, top: c(255, 226, 120), bottom: c(255, 166, 30))
    orb(ctx, at: ends[2], r: 70, top: c(120, 240, 180), bottom: c(20, 196, 130))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: c(10, 20, 90, 0.3))
    ctx.setFillColor(c(255, 255, 255))
    ctx.fillEllipse(in: CGRect(x: stemBottom.x - 50, y: stemBottom.y - 50, width: 100, height: 100))
    ctx.restoreGState()
    ctx.setFillColor(c(70, 110, 255))
    ctx.fillEllipse(in: CGRect(x: stemBottom.x - 22, y: stemBottom.y - 22, width: 44, height: 44))

    linear(ctx, [c(255, 255, 255, 0.22), c(255, 255, 255, 0)], [0, 1],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(squircle(body.insetBy(dx: 3, dy: 3)))
    ctx.setLineWidth(6)
    ctx.setStrokeColor(c(255, 255, 255, 0.45))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
