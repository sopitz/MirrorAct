// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics

/// Gestaltung für Screenshots, Aufnahmen und Präsentation: Rahmenfarbe, Hintergrund, Abstand, Schatten, Format
struct FrameStyle: Codable, Equatable {
    var bezelColor: BezelColor = .graphite
    var background: BackgroundKind = .transparent
    var color: RGBA = RGBA(red: 0.13, green: 0.13, blue: 0.15)
    var gradient: GradientPreset = .ocean
    var imagePath: String?
    /// Abstand um das Gerät, relativ zur kürzeren Geräteseite
    var padding: Double = 0
    var shadow: Bool = false
    var aspect: CanvasAspect = .auto
    /// ohne Rahmen: Ecken wie das Gerät abrunden
    var roundedScreen: Bool = true

    var isPlainScreen: Bool { background == .transparent && padding == 0 && !shadow }

    /// Schwarzer Rand zum Einpassen gedrehter Bilder in eine feste Leinwand
    static let letterbox = FrameStyle(background: .color, color: RGBA(red: 0, green: 0, blue: 0),
                                      padding: 0, shadow: false, roundedScreen: false)
}

struct RGBA: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        red = Double(c.redComponent)
        green = Double(c.greenComponent)
        blue = Double(c.blueComponent)
        alpha = Double(c.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum BackgroundKind: String, Codable, CaseIterable, Identifiable {
    case transparent, color, gradient, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transparent: return String(localized: "Transparent")
        case .color: return String(localized: "Color")
        case .gradient: return String(localized: "Gradient")
        case .image: return String(localized: "Image")
        }
    }
}

enum CanvasAspect: String, Codable, CaseIterable, Identifiable {
    case auto, square, landscape16x9, portrait9x16, landscape4x3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return String(localized: "Automatic")
        case .square: return "1:1"
        case .landscape16x9: return "16:9"
        case .portrait9x16: return "9:16"
        case .landscape4x3: return "4:3"
        }
    }
    /// Breite / Höhe
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .landscape16x9: return 16.0 / 9
        case .portrait9x16: return 9.0 / 16
        case .landscape4x3: return 4.0 / 3
        }
    }
}

enum GradientPreset: String, Codable, CaseIterable, Identifiable {
    case ocean, evening, forest, lilac, graphite, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ocean: return String(localized: "Ocean")
        case .evening: return String(localized: "Evening")
        case .forest: return String(localized: "Forest")
        case .lilac: return String(localized: "Lilac")
        case .graphite: return String(localized: "Graphite")
        case .light: return String(localized: "Light")
        }
    }
    var colors: (RGBA, RGBA) {
        switch self {
        case .ocean: return (RGBA(red: 0.12, green: 0.42, blue: 0.62), RGBA(red: 0.04, green: 0.14, blue: 0.30))
        case .evening: return (RGBA(red: 0.98, green: 0.62, blue: 0.38), RGBA(red: 0.56, green: 0.20, blue: 0.46))
        case .forest: return (RGBA(red: 0.22, green: 0.52, blue: 0.40), RGBA(red: 0.05, green: 0.20, blue: 0.17))
        case .lilac: return (RGBA(red: 0.66, green: 0.50, blue: 0.92), RGBA(red: 0.26, green: 0.16, blue: 0.52))
        case .graphite: return (RGBA(red: 0.36, green: 0.37, blue: 0.40), RGBA(red: 0.11, green: 0.11, blue: 0.13))
        case .light: return (RGBA(red: 0.98, green: 0.98, blue: 0.99), RGBA(red: 0.84, green: 0.86, blue: 0.89))
        }
    }
}

/// Gehäusefarben (Metallrahmen und Tasten; die Front bleibt schwarz)
enum BezelColor: String, Codable, CaseIterable, Identifiable {
    case graphite, black, silver, gold, naturalTitanium, blue, purple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphite: return String(localized: "Graphite")
        case .black: return String(localized: "Black")
        case .silver: return String(localized: "Silver")
        case .gold: return String(localized: "Gold")
        case .naturalTitanium: return String(localized: "Natural Titanium")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Deep Purple")
        }
    }
    /// Verlauf hell → dunkel → mittel
    var metal: [CGColor] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .graphite: return [c(0.42, 0.42, 0.45), c(0.20, 0.20, 0.22), c(0.33, 0.33, 0.36)]
        case .black: return [c(0.24, 0.24, 0.26), c(0.07, 0.07, 0.08), c(0.16, 0.16, 0.17)]
        case .silver: return [c(0.93, 0.93, 0.95), c(0.66, 0.67, 0.70), c(0.85, 0.85, 0.87)]
        case .gold: return [c(0.97, 0.89, 0.75), c(0.76, 0.64, 0.46), c(0.90, 0.80, 0.64)]
        case .naturalTitanium: return [c(0.80, 0.77, 0.72), c(0.53, 0.51, 0.47), c(0.70, 0.67, 0.62)]
        case .blue: return [c(0.66, 0.77, 0.88), c(0.36, 0.47, 0.60), c(0.56, 0.67, 0.79)]
        case .purple: return [c(0.45, 0.39, 0.52), c(0.21, 0.17, 0.25), c(0.35, 0.30, 0.41)]
        }
    }
    var button: CGColor {
        let m = metal[1]
        let comps = m.components ?? [0.27, 0.27, 0.29, 1]
        return CGColor(srgbRed: min(1, comps[0] * 1.15), green: min(1, comps[1] * 1.15),
                       blue: min(1, comps[2] * 1.15), alpha: 1)
    }
    /// Lichtkante: auf hellen Farben dunkler
    var highlight: CGColor {
        switch self {
        case .silver, .gold, .naturalTitanium, .blue: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18)
        default: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
        }
    }
    var swatch: NSColor { NSColor(cgColor: metal[0]) ?? .gray }
}

// MARK: Hintergrund zeichnen

extension FrameStyle {
    /// Zeichnet den Hintergrund in `rect` (geflippter Kontext); transparent zeichnet nichts
    func drawBackground(in ctx: CGContext, rect: CGRect, image: CGImage?) {
        switch background {
        case .transparent:
            break
        case .color:
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient:
            let (a, b) = gradient.colors
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        case .image:
            guard let image else {
                ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
                ctx.fill(rect)
                return
            }
            // füllend skalieren, mittig
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                width: size.width, height: size.height)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.translateBy(x: target.minX, y: target.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
    }

    func loadBackgroundImage() -> CGImage? {
        guard background == .image, let path = imagePath else { return nil }
        return FrameRenderer.loadImage(at: URL(fileURLWithPath: path))
    }
}
