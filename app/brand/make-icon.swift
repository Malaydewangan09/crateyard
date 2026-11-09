// Draws Crateyard's app icon (a container on the load line) at every size macOS asks for, then iconutil packs them.
// The geometry matches CrateyardGlyph in Theme.swift: a standalone script cannot import the app target.
import AppKit

func rounded(_ p: CGMutablePath, _ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) {
    let s = r.width / 64
    p.addRoundedRect(in: CGRect(x: r.minX + x * s, y: r.minY + y * s, width: w * s, height: h * s), cornerWidth: radius * s, cornerHeight: radius * s)
}
func container(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    rounded(p, r, 15, 18, 34, 22, 2)
    for x in [22.0, 30.5, 39.0] { rounded(p, r, x, 22, 3, 14, 0) }
    return p
}
func loadLine(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    rounded(p, r, 4, 43, 56, 4.5, 2.25)
    return p
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSColor(red: 0.043, green: 0.063, blue: 0.086, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18).fill()
    // The mark is drawn y-down in a 64-unit square, so flip the context and centre it on the tile.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)
    let markRect = CGRect(x: s * 0.2, y: s * 0.19, width: s * 0.6, height: s * 0.6)
    ctx.setFillColor(CGColor(red: 1, green: 0.416, blue: 0.239, alpha: 1))
    ctx.addPath(container(markRect))
    ctx.fillPath(using: .evenOdd)
    ctx.addPath(loadLine(markRect))
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
