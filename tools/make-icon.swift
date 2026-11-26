// Draws assets/AppIcon.iconset. Run: ./swiftc.sh tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon
import AppKit

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // macOS icon grid: 824/1024 body, ~185/1024 corner radius.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 18 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.31, blue: 0.93, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.62, blue: 0.72, alpha: 1)])!.draw(in: shape, angle: -55)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.18, green: 0.42, blue: 0.86, alpha: 1), .white]))
    if let glyph = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2 - s * 0.01, width: g.width, height: g.height))
    }
    if let spark = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: s * 0.15, weight: .bold).applying(.init(paletteColors: [.white]))) {
        let g = spark.size
        spark.draw(in: NSRect(x: s * 0.67, y: s * 0.63, width: g.width, height: g.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: folder.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: folder.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
