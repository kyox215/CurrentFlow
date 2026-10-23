import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let blue = NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.84, alpha: 1)
let green = NSColor(calibratedRed: 0.02, green: 0.56, blue: 0.37, alpha: 1)

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, border: NSColor? = nil, line: CGFloat = 7) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
    if let border { border.setStroke(); path.lineWidth = line; path.stroke() }
}

func draw() {
    let background = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 206, yRadius: 206)
    NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 1), ending: NSColor(calibratedRed: 0.91, green: 0.96, blue: 0.99, alpha: 1))!.draw(in: background, angle: -75)
    for (color, vertices) in [
        (blue, [NSPoint(x: 420, y: 520), NSPoint(x: 530, y: 520), NSPoint(x: 530, y: 720), NSPoint(x: 650, y: 720)]),
        (green, [NSPoint(x: 530, y: 520), NSPoint(x: 530, y: 300), NSPoint(x: 640, y: 300)])
    ] {
        let wire = NSBezierPath(); wire.move(to: vertices[0])
        for point in vertices.dropFirst() { wire.line(to: point) }
        wire.lineWidth = 20; wire.lineCapStyle = .round; wire.lineJoinStyle = .round
        color.setStroke(); wire.stroke()
    }
    rounded(NSRect(x: 170, y: 390, width: 250, height: 260), radius: 52, fill: .white, border: blue.withAlphaComponent(0.45))
    let bolt = NSBezierPath()
    for (i, point) in [NSPoint(x: 316, y: 610), NSPoint(x: 237, y: 510), NSPoint(x: 286, y: 510), NSPoint(x: 267, y: 432), NSPoint(x: 351, y: 542), NSPoint(x: 300, y: 542)].enumerated() {
        if i == 0 { bolt.move(to: point) } else { bolt.line(to: point) }
    }
    bolt.close(); blue.setFill(); bolt.fill()
    rounded(NSRect(x: 650, y: 620, width: 220, height: 200), radius: 38, fill: .white, border: blue.withAlphaComponent(0.35))
    rounded(NSRect(x: 712, y: 673, width: 96, height: 96), radius: 10, fill: blue.withAlphaComponent(0.08), border: blue, line: 8)
    let pins = NSBezierPath()
    for p in [728.0, 748, 768, 788] {
        pins.move(to: NSPoint(x: p, y: 769)); pins.line(to: NSPoint(x: p, y: 786))
        pins.move(to: NSPoint(x: p, y: 656)); pins.line(to: NSPoint(x: p, y: 673))
    }
    for p in [690.0, 710, 730, 750] {
        pins.move(to: NSPoint(x: 695, y: p)); pins.line(to: NSPoint(x: 712, y: p))
        pins.move(to: NSPoint(x: 808, y: p)); pins.line(to: NSPoint(x: 825, y: p))
    }
    blue.setStroke(); pins.lineWidth = 8; pins.lineCapStyle = .round; pins.stroke()
    rounded(NSRect(x: 640, y: 277, width: 14, height: 46), radius: 4, fill: green)
    rounded(NSRect(x: 650, y: 220, width: 220, height: 160), radius: 34, fill: .white, border: green, line: 8)
    rounded(NSRect(x: 664, y: 234, width: 134, height: 132), radius: 22, fill: green.withAlphaComponent(0.20))
    green.setFill(); NSBezierPath(ovalIn: NSRect(x: 517, y: 507, width: 26, height: 26)).fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
