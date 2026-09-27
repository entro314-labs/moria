// Renders Moria's app icon into an .iconset directory: layered rock strata (depth) seen
// through a glass magnifier. Usage: swift Scripts/make_icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt body centered in 1024, continuous corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
    color(0x0B1330).setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    // Sky-to-depth gradient
    NSGradient(colors: [color(0x2B3A8F), color(0x151C4A), color(0x080B1F)], atLocations: [0, 0.45, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -90)

    // Strata: wavy bands getting warmer with depth.
    let bands: [(y: CGFloat, color: NSColor)] = [
        (520, color(0x3D5AFE, 0.55)), (430, color(0x00BFA5, 0.55)), (340, color(0xFFB300, 0.55)), (250, color(0xFF6D00, 0.6)),
    ]
    for (index, band) in bands.enumerated() {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 80, y: band.y))
        let phase = CGFloat(index) * 70
        path.curve(to: CGPoint(x: 960, y: band.y + 30),
                   controlPoint1: CGPoint(x: 330 + phase, y: band.y + 90),
                   controlPoint2: CGPoint(x: 640 - phase, y: band.y - 70))
        path.line(to: CGPoint(x: 960, y: 60))
        path.line(to: CGPoint(x: 80, y: 60))
        path.close()
        band.color.setFill()
        path.fill()
    }
    // Top sheen
    NSGradient(colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)])!
        .draw(in: CGRect(x: 100, y: 620, width: 824, height: 304), angle: -90)
    ctx.restoreGState()

    // Magnifier: glass lens with a bright rim and a handle.
    let center = CGPoint(x: 470, y: 560)
    let radius: CGFloat = 190
    let handle = NSBezierPath()
    handle.move(to: CGPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.72))
    handle.line(to: CGPoint(x: 800, y: 230))
    handle.lineWidth = 78
    handle.lineCapStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45).cgColor)
    color(0xE8ECFF).setStroke()
    handle.stroke()
    ctx.restoreGState()

    let lens = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.saveGState()
    lens.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.28), color(0x9FB4FF, 0.10), color(0xFFFFFF, 0.04)])!
        .draw(in: lens, relativeCenterPosition: CGPoint(x: -0.4, y: 0.45))
    // Magnified strata inside the lens
    let inner = NSBezierPath()
    inner.move(to: CGPoint(x: center.x - radius, y: center.y - 40))
    inner.curve(to: CGPoint(x: center.x + radius, y: center.y - 10),
                controlPoint1: CGPoint(x: center.x - 60, y: center.y + 60),
                controlPoint2: CGPoint(x: center.x + 60, y: center.y - 90))
    inner.line(to: CGPoint(x: center.x + radius, y: center.y - radius))
    inner.line(to: CGPoint(x: center.x - radius, y: center.y - radius))
    inner.close()
    color(0xFFC400, 0.55).setFill()
    inner.fill()
    ctx.restoreGState()

    lens.lineWidth = 44
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 30, color: color(0x8FA8FF, 0.8).cgColor)
    color(0xF4F6FF).setStroke()
    lens.stroke()
    ctx.restoreGState()
    // Lens highlight
    let glint = NSBezierPath()
    glint.appendArc(withCenter: center, radius: radius - 52, startAngle: 115, endAngle: 160)
    glint.lineWidth = 18
    glint.lineCapStyle = .round
    color(0xFFFFFF, 0.75).setStroke()
    glint.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: base * scale).write(to: output.appending(path: name))
    }
}
