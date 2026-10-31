// Renders the README banner: the mark and the wordmark on ink, with the tagline.
// Usage: swift scripts/make-banner.swift docs/images/banner.png
import AppKit

let W: CGFloat = 1280, H: CGFloat = 400, scale: CGFloat = 2
let barWidth: CGFloat = 0.1345, gap: CGFloat = 0.0793
let heights: [CGFloat] = [0.517, 0.81, 0.397]  // MarkGeometry in app/Sources/OpenFlow/Theme.swift

func color(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// ink card with soft ember and tide glows
let card = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: 28, cornerHeight: 28, transform: nil)
ctx.addPath(card)
ctx.clip()
ctx.setFillColor(color(0x121318).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (hex, alpha, center, radius) in [(0xFF5C38, 0.30, CGPoint(x: 120, y: -40), 520.0), (0x2BA89C, 0.16, CGPoint(x: W - 80, y: H + 60), 520.0)] {
    let g = CGGradient(colorsSpace: space, colors: [color(hex, alpha).cgColor, color(hex, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// the mark
let u: CGFloat = 150, w = barWidth * u
let wordmark = NSAttributedString(string: "OpenFlow", attributes: [.font: serif(92, .semibold), .foregroundColor: color(0xF6F4EF), .kern: -1.5])
let tagline = NSAttributedString(string: "Talk instead of typing. Private dictation and meeting notes for your Mac.",
                                 attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: color(0xF6F4EF, 0.62)])
let groupWidth = u + 36 + wordmark.size().width
let x0 = (W - groupWidth) / 2, cy: CGFloat = 228
var x = x0
color(0xFF5C38).setFill()
for h in heights {
    NSBezierPath(roundedRect: CGRect(x: x, y: cy - h * u / 2, width: w, height: h * u), xRadius: w / 2, yRadius: w / 2).fill()
    x += w + gap * u
}
color(0xF6F4EF).setFill()
NSBezierPath(roundedRect: CGRect(x: x, y: cy - w / 2, width: x0 + u - x, height: w), xRadius: w / 2, yRadius: w / 2).fill()

wordmark.draw(at: CGPoint(x: x0 + u + 36, y: cy - wordmark.size().height / 2 - 4))
tagline.draw(at: CGPoint(x: (W - tagline.size().width) / 2, y: 92))

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
