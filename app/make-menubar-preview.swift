// Renders previews of the menu-bar icon states (see MenuBarIcon.swift).
//
//   swiftc -parse-as-library app/MenuBarIcon.swift app/make-menubar-preview.swift -o preview
//   ./preview docs/menubar-icons.png [comparison.png]
//
// The first image (for the README) shows each state on a light and a dark menu
// bar. The optional second one shows them at real size next to the system
// Sound icon, to check they can't be confused.
import AppKit

@main
struct MenuBarPreview {
    static let states: [(MenuBarIcon.State, String)] = [
        (.active, "Active"), (.idle, "Idle"), (.paused, "Paused"), (.waiting, "Waiting"),
    ]
    static let lightBar = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    static let darkBar = CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: preview <docs.png> [comparison.png]")
            exit(1)
        }
        try write(docsImage(), to: args[1])
        if args.count >= 3 { try write(comparisonImage(), to: args[2]) }
    }

    /// README image: four states, light bar on top, dark bar below, labelled.
    static func docsImage() -> CGImage {
        let cellW = 180, bandH = 130, scale: CGFloat = 4
        let ctx = canvas(width: cellW * states.count, height: bandH * 2)
        for (band, (bar, ink, text)) in [(lightBar, CGColor.black, NSColor.black),
                                         (darkBar, CGColor.white, NSColor.white)].enumerated() {
            let y0 = CGFloat(bandH * (1 - band))
            ctx.setFillColor(bar)
            ctx.fill(CGRect(x: 0, y: y0, width: CGFloat(cellW * states.count), height: CGFloat(bandH)))
            for (i, (state, label)) in states.enumerated() {
                let iconW = MenuBarIcon.size.width * scale, iconH = MenuBarIcon.size.height * scale
                let x = CGFloat(i * cellW) + (CGFloat(cellW) - iconW) / 2
                drawIcon(state, in: ctx, rect: CGRect(x: x, y: y0 + 46, width: iconW, height: iconH),
                         scale: scale, ink: ink)
                drawLabel(label, in: ctx, centerX: CGFloat(i * cellW + cellW / 2), y: y0 + 14, color: text)
            }
        }
        return ctx.makeImage()!
    }

    /// Real-size check (2x, like a Retina menu bar): system Sound icon, then ours.
    static func comparisonImage() -> CGImage {
        let cellW = 64, bandH = 48, columns = states.count + 1
        let ctx = canvas(width: cellW * columns, height: bandH * 2)
        let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
        for (band, (bar, ink, tint)) in [(lightBar, CGColor.black, NSColor.black),
                                         (darkBar, CGColor.white, NSColor.white)].enumerated() {
            let y0 = CGFloat(bandH * (1 - band))
            ctx.setFillColor(bar)
            ctx.fill(CGRect(x: 0, y: y0, width: CGFloat(cellW * columns), height: CGFloat(bandH)))
            // system Sound icon
            let s = symbol.size
            let rect = CGRect(x: (CGFloat(cellW) - s.width * 2) / 2, y: y0 + (CGFloat(bandH) - s.height * 2) / 2,
                              width: s.width * 2, height: s.height * 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            tinted(symbol, tint).draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            for (i, (state, _)) in states.enumerated() {
                let w = MenuBarIcon.size.width * 2, h = MenuBarIcon.size.height * 2
                let x = CGFloat((i + 1) * cellW) + (CGFloat(cellW) - w) / 2
                drawIcon(state, in: ctx, rect: CGRect(x: x, y: y0 + (CGFloat(bandH) - h) / 2, width: w, height: h),
                         scale: 2, ink: ink)
            }
        }
        return ctx.makeImage()!
    }

    static func canvas(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func drawIcon(_ state: MenuBarIcon.State, in ctx: CGContext, rect: CGRect, scale: CGFloat, ink: CGColor) {
        guard let rep = MenuBarIcon.rasterize(state, scale: scale, color: ink), let image = rep.cgImage else { return }
        ctx.draw(image, in: rect)
    }

    static func drawLabel(_ text: String, in ctx: CGContext, centerX: CGFloat, y: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 21, weight: .medium),
                                                         .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(at: NSPoint(x: centerX - string.size().width / 2, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func write(_ image: CGImage, to path: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(image.width)×\(image.height))")
    }
}
