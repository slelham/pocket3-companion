import AppKit

let imgs = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "streamdeck/local.slelham.pocket3.sdPlugin/imgs"
let source = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/icon.png"
let dir = URL(fileURLWithPath: imgs, isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func writePNG(_ size: Int, _ name: String, _ draw: (NSRect) -> Void) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("could not make \(name)\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()
    draw(rect)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do {
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    } catch {
        fputs("could not write \(name)\n", stderr)
        exit(1)
    }
}

func plate(_ rect: NSRect) {
    let s = rect.width
    let inset = rect.insetBy(dx: s * 0.06, dy: s * 0.06)
    let path = NSBezierPath(roundedRect: inset, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
    path.fill()
}

func stroke(_ path: NSBezierPath, _ width: CGFloat) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.white.setStroke()
    path.stroke()
}

func recall(_ rect: NSRect) {
    plate(rect)
    let s = rect.width
    let a = s * 0.30
    let b = s * 0.70
    let arm = s * 0.15
    let width = max(2, s * 0.055)
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (a, a, 1, 1), (b, a, -1, 1), (a, b, 1, -1), (b, b, -1, -1),
    ]
    for (x, y, dx, dy) in corners {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y + dy * arm))
        path.line(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + dx * arm, y: y))
        stroke(path, width)
    }
    let dot = s * 0.055
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: s / 2 - dot, y: s / 2 - dot, width: dot * 2, height: dot * 2)).fill()
}

func chevron(tip: NSPoint, dx: CGFloat, dy: CGFloat, length: CGFloat, width: CGFloat) {
    let back = NSPoint(x: tip.x - dx * length, y: tip.y - dy * length)
    let side = length * 0.7
    let path = NSBezierPath()
    path.move(to: NSPoint(x: back.x + -dy * side, y: back.y + dx * side))
    path.line(to: tip)
    path.line(to: NSPoint(x: back.x - -dy * side, y: back.y - dx * side))
    stroke(path, width)
}

func move(_ rect: NSRect) {
    plate(rect)
    let s = rect.width
    let c = s / 2
    let length = s * 0.11
    let width = max(2, s * 0.05)
    chevron(tip: NSPoint(x: c, y: s * 0.82), dx: 0, dy: 1, length: length, width: width)
    chevron(tip: NSPoint(x: c, y: s * 0.18), dx: 0, dy: -1, length: length, width: width)
    chevron(tip: NSPoint(x: s * 0.82, y: c), dx: 1, dy: 0, length: length, width: width)
    chevron(tip: NSPoint(x: s * 0.18, y: c), dx: -1, dy: 0, length: length, width: width)
}

func zoom(_ rect: NSRect) {
    plate(rect)
    let s = rect.width
    let radius = s * 0.15
    let cx = s * 0.42
    let cy = s * 0.58
    let width = max(2, s * 0.055)
    let circle = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
    stroke(circle, width)
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: cx + radius * 0.72, y: cy - radius * 0.72))
    handle.line(to: NSPoint(x: s * 0.74, y: s * 0.26))
    stroke(handle, width * 1.15)
}

func recenter(_ rect: NSRect) {
    plate(rect)
    let s = rect.width
    let c = s / 2
    let width = max(2, s * 0.05)
    let radius = s * 0.16
    stroke(NSBezierPath(ovalIn: NSRect(x: c - radius, y: c - radius, width: radius * 2, height: radius * 2)), width)
    let gap = s * 0.07
    let outer = s * 0.34
    let horizontal = NSBezierPath()
    horizontal.move(to: NSPoint(x: c - outer, y: c))
    horizontal.line(to: NSPoint(x: c - gap, y: c))
    horizontal.move(to: NSPoint(x: c + gap, y: c))
    horizontal.line(to: NSPoint(x: c + outer, y: c))
    stroke(horizontal, width)
    let vertical = NSBezierPath()
    vertical.move(to: NSPoint(x: c, y: c - outer))
    vertical.line(to: NSPoint(x: c, y: c - gap))
    vertical.move(to: NSPoint(x: c, y: c + gap))
    vertical.line(to: NSPoint(x: c, y: c + outer))
    stroke(vertical, width)
    let dot = s * 0.035
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c - dot, y: c - dot, width: dot * 2, height: dot * 2)).fill()
}

func stop(_ rect: NSRect) {
    plate(rect)
    let s = rect.width
    let side = s * 0.32
    let origin = (s - side) / 2
    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: origin, y: origin, width: side, height: side),
        xRadius: s * 0.05,
        yRadius: s * 0.05
    ).fill()
}

func scaledIcon(_ size: Int, _ name: String) {
    guard let image = NSImage(contentsOfFile: source) else {
        fputs("missing \(source)\n", stderr)
        exit(1)
    }
    writePNG(size, name) { rect in
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

scaledIcon(144, "plugin")
scaledIcon(288, "plugin@2x")
scaledIcon(28, "category")
scaledIcon(56, "category@2x")

let glyphs: [(String, (NSRect) -> Void)] = [
    ("recall", recall), ("move", move), ("zoom", zoom), ("recenter", recenter), ("stop", stop),
]
for (name, draw) in glyphs {
    writePNG(72, name, draw)
    writePNG(144, "\(name)@2x", draw)
}
