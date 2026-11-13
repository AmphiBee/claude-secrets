// Dessine l'icône (bouclier, serrure, étincelle sur le cuivre) et produit Resources/AppIcon.icns.
//   swift Tools/make-icon.swift        (iconutil est fourni avec macOS)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    // Les coordonnées du dessin d'origine (128 × 128, y vers le bas) : centre ramené au centre de l'image.
    let u: CGFloat = 7.2 * k
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 512 * k + (x - 64) * u, y: 512 * k - (y - 64) * u) }

    // socle : carré arrondi à la marge habituelle de macOS (≈ 100/1024)
    let base = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 24 * k; sh.shadowOffset = NSSize(width: 0, height: -10 * k)
    sh.set(); color(0xDE7650).setFill(); basePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xF6A974), ending: color(0xDE7650))!.draw(in: basePath, angle: -90)
    color(0xFFFFFF, 0.22).setStroke(); basePath.lineWidth = 3 * k; basePath.stroke()

    func shield(dy: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: P(64, 30 + dy)); p.line(to: P(90, 39.5 + dy)); p.line(to: P(90, 60 + dy))
        p.curve(to: P(64, 97 + dy), controlPoint1: P(90, 78 + dy), controlPoint2: P(78.5, 90.5 + dy))
        p.curve(to: P(38, 60 + dy), controlPoint1: P(49.5, 90.5 + dy), controlPoint2: P(38, 78 + dy))
        p.line(to: P(38, 39.5 + dy)); p.close(); return p
    }
    color(0x8E3E28, 0.25).setFill(); shield(dy: 3).fill()
    NSGradient(starting: .white, ending: color(0xFCE9DC))!.draw(in: shield(dy: 0), angle: -90)

    // serrure
    let hole = NSGradient(starting: color(0xB9573A), ending: color(0x8E3E28))!
    let circle = NSBezierPath(ovalIn: NSRect(origin: P(64 - 8.5, 57 + 8.5), size: NSSize(width: 17 * u, height: 17 * u)))
    hole.draw(in: circle, angle: -90)
    let body = NSBezierPath(); body.move(to: P(59.5, 61)); body.line(to: P(68.5, 61)); body.line(to: P(71, 78)); body.line(to: P(57, 78)); body.close()
    hole.draw(in: body, angle: -90)

    // étincelle
    let spark = NSBezierPath()
    spark.move(to: P(95, 18))
    spark.curve(to: P(107, 30), controlPoint1: P(96.4, 26.2), controlPoint2: P(98.8, 28.6))
    spark.curve(to: P(95, 42), controlPoint1: P(98.8, 31.4), controlPoint2: P(96.4, 33.8))
    spark.curve(to: P(83, 30), controlPoint1: P(93.6, 33.8), controlPoint2: P(91.2, 31.4))
    spark.curve(to: P(95, 18), controlPoint1: P(91.2, 28.6), controlPoint2: P(93.6, 26.2))
    color(0xFFF4D2).setFill(); spark.fill()
    color(0xFFF4D2, 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: P(106, 45).x - 2.6 * u, y: P(106, 45).y - 2.6 * u, width: 5.2 * u, height: 5.2 * u)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]; try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK : \(out.path)" : "iconutil a échoué")
