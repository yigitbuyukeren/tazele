// Kullanım: swift scripts/make-icon.swift Resources/AppIcon.icns
// Turkuaz gradyanlı yuvarlak köşeli bir kare üzerine beyaz "yenile" simgesi çizer, iconutil ile .icns'e çevirir.
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.225, yRadius: s * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowBlurRadius = s * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    shadow.set()
    NSColor(red: 0.04, green: 0.46, blue: 0.52, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.13, green: 0.78, blue: 0.66, alpha: 1),
                        NSColor(red: 0.04, green: 0.46, blue: 0.52, alpha: 1)])!
        .draw(in: path, angle: -50)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tazele-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
exit(p.terminationStatus)
