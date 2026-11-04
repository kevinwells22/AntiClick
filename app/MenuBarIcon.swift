// AntiClick's menu-bar icon: the same smooth "wave burst" as the app icon
// (a sound whose loudness fades in and out, i.e. starts and stops without a
// click), drawn in code. Deliberately not a speaker, so it can't be mistaken
// for macOS's own Sound icon.
//
// Template images: macOS tints them for light and dark menu bars, so states
// are told apart by shape and opacity, not colour.
import AppKit

enum MenuBarIcon {
    enum State {
        case active     // keeping a device awake
        case idle       // nothing to hold right now
        case paused     // turned off by the user
        case waiting    // device busy (another app has exclusive access)
    }

    /// Size in points; fits the menu bar's square status item.
    static let size = CGSize(width: 20, height: 16)

    static func image(for state: State, description: String) -> NSImage {
        let image = NSImage(size: size)
        for scale in [1, 2, 3] as [CGFloat] {
            if let rep = rasterize(state, scale: scale) { image.addRepresentation(rep) }
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Renders into our own bitmaps, so the "knock-out" gaps around the slash
    /// and badge erase only the icon itself.
    static func rasterize(_ state: State, scale: CGFloat, color: CGColor = .black) -> NSBitmapImageRep? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(state, in: ctx, color: color)
        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: size.width, height: size.height)
        return rep
    }

    /// Draws in a 20×16 pt space (origin bottom-left).
    static func draw(_ state: State, in ctx: CGContext, color: CGColor) {
        let lineWidth: CGFloat = 1.7
        let faded = state == .idle || state == .waiting

        // The wave burst: a sine wave under a sin² envelope, 3 cycles.
        let wave = CGMutablePath()
        let left: CGFloat = 1.5, right: CGFloat = 18.5, middle: CGFloat = 8
        let amplitude: CGFloat = 6.3, cycles: CGFloat = 3, steps = 160
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let envelope = pow(sin(.pi * t), 2)
            let point = CGPoint(x: left + (right - left) * t,
                                y: middle + amplitude * envelope * sin(2 * .pi * cycles * t))
            if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(color.copy(alpha: faded ? 0.42 : 1) ?? color)
        ctx.addPath(wave)
        ctx.strokePath()

        switch state {
        case .paused:
            // A slash with a small gap cut around it, like the system's "off" symbols.
            let from = CGPoint(x: 3.5, y: 1.2), to = CGPoint(x: 16.5, y: 14.8)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(lineWidth + 2.6)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setLineWidth(lineWidth)
            ctx.setStrokeColor(color)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()

        case .waiting:
            // A solid badge with a knocked-out "!" in the top-right corner.
            let center = CGPoint(x: 15.9, y: 11.9), radius: CGFloat = 3.7, gap: CGFloat = 1.1
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: center.x - radius - gap, y: center.y - radius - gap,
                                       width: 2 * (radius + gap), height: 2 * (radius + gap)))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: 2 * radius, height: 2 * radius))
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: center.x - 0.6, y: center.y - 0.35, width: 1.2, height: 2.6))
            ctx.fillEllipse(in: CGRect(x: center.x - 0.65, y: center.y - 2.15, width: 1.3, height: 1.3))
            ctx.setBlendMode(.normal)

        case .active, .idle:
            break
        }
    }
}
