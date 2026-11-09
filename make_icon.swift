import AppKit

// One-shot generator: draws the tuti app icon (green tile, white mic) into
// swift/Assets.xcassets/AppIcon.appiconset. Run from the repo root: swift make_icon.swift
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func drawIcon(_ ctx: CGContext) {
    // macOS template: a 824x824 squircle centered on the transparent 1024 canvas
    let side: CGFloat = 824, radius: CGFloat = 185
    let body = CGRect(x: (1024 - side) / 2, y: (1024 - side) / 2, width: side, height: side)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [NSColor(srgbRed: 0.18, green: 0.64, blue: 0.42, alpha: 1).cgColor,
                                       NSColor(srgbRed: 0.05, green: 0.30, blue: 0.22, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    // white microphone: capsule, cradle arc, stem, base
    ctx.setFillColor(NSColor.white.cgColor)
    let capsule = CGRect(x: 512 - 90, y: 540 - 155, width: 180, height: 310)
    ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 90, cornerHeight: 90, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(32)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: 512, y: 540), radius: 210,
               startAngle: .pi + 0.35, endAngle: 2 * .pi - 0.35, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 512, y: 330))
    ctx.addLine(to: CGPoint(x: 512, y: 275))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 512 - 85, y: 275))
    ctx.addLine(to: CGPoint(x: 512 + 85, y: 275))
    ctx.strokePath()
    ctx.restoreGState()
}

for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "swift/Assets.xcassets/AppIcon.appiconset/\(name)"))
}
print("wrote \(sizes.count) icons")
