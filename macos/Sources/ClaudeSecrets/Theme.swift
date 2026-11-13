import SwiftUI
import AppKit
import SecretsCore

/// « Papier & cuivre » : papier chaud en clair, encre chaude en sombre ; le cuivre est un tampon, pas un décor.
enum Theme {
    static func dynamic(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let d = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = d ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }
    static let paper = dynamic((247, 242, 232), (30, 27, 24))
    static let paperRaised = dynamic((252, 249, 242), (40, 36, 32))
    static let rule = dynamic((222, 213, 197), (66, 59, 52))
    static let ink = dynamic((43, 36, 30), (237, 229, 216))
    static let inkSoft = dynamic((107, 95, 82), (176, 165, 150))      // AA sur le papier, clair et sombre
    static let copper = dynamic((176, 82, 53), (246, 169, 116))        // #B9573A assombri à 4,5:1 sur le papier / #F6A974
    static let copperDeep = Color(red: 0x8E / 255, green: 0x3E / 255, blue: 0x28 / 255)
    /// Action du toast (fond = encre) : étincelle en clair, cuivre profond en sombre (le toast y est clair).
    static let toastAccent = dynamic((255, 244, 210), (142, 62, 40))
    static let spark = Color(red: 1, green: 0xF4 / 255, blue: 0xD2 / 255)

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }

    /// (fond, bordure, lettre) de la teinte i, comme tone_colors() du script ; inversé en sombre.
    static func tone(_ service: String) -> (Color, Color, Color) {
        let hue = Double(toneIndex(service)) * 360 / Double(tones) / 360
        func c(_ s: Double, _ l: Double) -> NSColor { NSColor.hsl(hue: hue, saturation: s, lightness: l) }
        func pair(_ s: Double, _ light: Double, _ dark: Double) -> Color {
            Color(nsColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(s, dark) : c(s, light)
            })
        }
        return (pair(0.62, 0.90, 0.22), pair(0.52, 0.74, 0.36), pair(0.66, 0.26, 0.86))
    }
}

extension NSColor {
    /// HSL → sRGB (même formule que colorsys.hls_to_rgb).
    static func hsl(hue h: Double, saturation s: Double, lightness l: Double) -> NSColor {
        func f(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            return l - s * min(l, 1 - l) * max(-1, min(k - 3, min(9 - k, 1)))
        }
        return NSColor(srgbRed: f(0), green: f(8), blue: f(4), alpha: 1)
    }
}
