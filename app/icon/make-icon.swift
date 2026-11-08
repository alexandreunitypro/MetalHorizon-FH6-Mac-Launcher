import AppKit
// MetalHorizon's app icon: the logo, scaled to fit inside macOS's rounded square (824 pt body on a 1024 canvas, as in
// Apple's icon grid), on the picture's own brushed black, with the picture's edges blended in.
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let out = args[2]
let size: CGFloat = 1024, body: CGFloat = 824, inset = (size - body) / 2, radius: CGFloat = 186
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: inset, y: inset, width: body, height: body)
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
// a soft shadow under the shape, as macOS icons have
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.set()
NSColor(srgbRed: 0.06, green: 0.06, blue: 0.065, alpha: 1).setFill(); shape.fill()
NSGraphicsContext.current!.restoreGraphicsState()
shape.addClip()
// background: the picture's dark brushed metal, darker at the edges
NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1), NSColor(srgbRed: 0.03, green: 0.03, blue: 0.035, alpha: 1)])!
    .draw(in: shape, relativeCenterPosition: NSPoint(x: 0, y: 0.15))
// the picture, scaled so the logo (about 1010 of its 1200 px) takes ~92% of the body's width, centred
let scale = (body * 0.92) / 1010
let w = source.size.width * scale, h = source.size.height * scale
let target = NSRect(x: (size - w) / 2, y: (size - h) / 2 + 6, width: w, height: h)
source.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
// blend the picture's edges into the background
for (from, to) in [(NSPoint(x: target.minX, y: 0), NSPoint(x: target.minX + 90, y: 0)), (NSPoint(x: target.maxX, y: 0), NSPoint(x: target.maxX - 90, y: 0))] {
    let g = NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1), NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 0)])!
    let band = NSRect(x: min(from.x, to.x), y: 0, width: abs(to.x - from.x), height: size)
    g.draw(in: band, angle: from.x < to.x ? 0 : 180)
}
for top in [true, false] {
    let y0 = top ? target.maxY - 70 : target.minY
    let g = NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 0), NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1)])!
    g.draw(in: NSRect(x: 0, y: y0, width: size, height: 70), angle: top ? 90 : 270)
}
// a thin light rim, as on a metal plate
NSColor.white.withAlphaComponent(0.10).setStroke()
let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5); rim.lineWidth = 3; rim.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
