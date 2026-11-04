// Draws AntiClick's app icon and writes an .iconset folder for iconutil.
// Original artwork: a sound wave whose loudness rises and falls smoothly,
// i.e. audio that starts and stops without a click.
// (SF Symbols are used in the menu bar only; their license excludes app icons.)
//
//   swiftc make-icon.swift -o make-icon && ./make-icon AppIcon.iconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // Standard macOS icon grid: the rounded square is 824/1024 of the canvas.
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.07, green: 0.11, blue: 0.30, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.07, green: 0.11, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.36, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.68, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: 90)

    // A wave packet: amplitude fades in and out smoothly (sin² envelope).
    let wave = NSBezierPath()
    let left = rect.minX + rect.width * 0.14
    let right = rect.maxX - rect.width * 0.14
    let amplitude = rect.height * 0.25
    let cycles: CGFloat = 3
    let steps = 400
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let envelope = pow(sin(.pi * t), 2)
        let point = NSPoint(x: left + (right - left) * t,
                            y: rect.midY + amplitude * envelope * sin(2 * .pi * cycles * t))
        if i == 0 { wave.move(to: point) } else { wave.line(to: point) }
    }
    wave.lineWidth = max(1.2, s * 0.045)
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    NSColor.white.setStroke()
    wave.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
