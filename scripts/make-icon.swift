// Renders OpenFlow's app icon into an .iconset and converts it to .icns (plus a 1024 px PNG next to it).
// The mark: three voice bars in ember that end in a line of text, on an ink tile. Keep the
// geometry in sync with MarkGeometry in app/Sources/OpenFlow/Theme.swift.
// Usage: swift scripts/make-icon.swift <out.icns>
import AppKit

let barWidth: CGFloat = 0.1345, gap: CGFloat = 0.0793
let heights: [CGFloat] = [0.517, 0.81, 0.397]

func srgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a).cgColor
}

func renderIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024  // design on a 1024 grid
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: 824pt rounded square centered, with a soft drop shadow.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: srgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(srgb(0x121318))
    ctx.fillPath()
    ctx.restoreGState()

    // ink, a little lighter at the top
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [srgb(0x2A2B33), srgb(0x121318)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()
    // a hairline rim so the tile reads on dark docks
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.09))
    ctx.setLineWidth(3 * s)
    ctx.strokePath()
    ctx.restoreGState()

    // the mark, 580 wide, centered
    let u = 580 * s, x0 = tile.midX - u / 2, cy = tile.midY, w = barWidth * u
    var x = x0
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 24 * s, color: srgb(0x000000, 0.3))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let barsTop = cy + heights.max()! * u / 2, barsBottom = cy - heights.max()! * u / 2
    ctx.saveGState()
    for h in heights {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: cy - h * u / 2, width: w, height: h * u),
                           cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        x += w + gap * u
    }
    ctx.clip()
    let ember = CGGradient(colorsSpace: space, colors: [srgb(0xFF7A4D), srgb(0xFF5C38), srgb(0xF2452A)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(ember, start: CGPoint(x: 0, y: barsTop), end: CGPoint(x: 0, y: barsBottom), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: cy - w / 2, width: x0 + u - x, height: w),
                       cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
    ctx.setFillColor(srgb(0xF6F4EF))
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFlow-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try renderIcon(px: pt * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try renderIcon(px: 1024).representation(using: .png, properties: [:])!
    .write(to: out.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
