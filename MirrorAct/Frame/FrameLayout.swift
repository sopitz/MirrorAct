// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Geometrie des Gehäuses rund um einen Bildschirm gegebener Grösse.
/// Koordinaten: Ursprung oben links, y nach unten (wie eine geflippte NSView).
/// Im Querformat liegt die Oberseite des Geräts (Notch) links.
struct FrameLayout {
    let profile: DeviceProfile
    let showFrame: Bool
    let landscape: Bool

    let totalSize: CGSize
    let bodyRect: CGRect
    let bezelRect: CGRect
    let screenRect: CGRect
    let bodyRadius: CGFloat
    let bezelRadius: CGFloat
    let screenRadius: CGFloat
    let buttons: [CGRect]
    let cutout: CGPath?
    let homeButton: CGRect?
    let earpiece: CGRect?
    let camera: CGRect?

    init(profile: DeviceProfile, screenSize: CGSize, showFrame: Bool) {
        self.profile = profile
        self.showFrame = showFrame
        landscape = screenSize.width > screenSize.height

        let W = min(screenSize.width, screenSize.height)
        let H = max(screenSize.width, screenSize.height)
        let screenRadius = profile.screenCornerRatio * W
        self.screenRadius = screenRadius

        guard showFrame else {
            let rect = CGRect(origin: .zero, size: screenSize)
            totalSize = screenSize
            bodyRect = rect
            bezelRect = rect
            screenRect = rect
            bodyRadius = screenRadius
            bezelRadius = screenRadius
            buttons = []
            cutout = nil
            homeButton = nil
            earpiece = nil
            camera = nil
            return
        }

        let isPad = profile.family == .iPad
        let isAndroid = profile.family == .android
        let side: CGFloat, top: CGFloat, bottom: CGFloat
        if profile.homeButton {
            side = (isPad ? 0.075 : 0.065) * W
            top = (isPad ? 0.11 : 0.205) * W
            bottom = top
        } else if isAndroid {
            side = 0.036 * W
            top = side
            bottom = 0.042 * W
        } else {
            side = (isPad ? 0.045 : 0.052) * W
            top = side
            bottom = side
        }
        let rim = (isPad ? 0.010 : 0.014) * W
        let protrusion: CGFloat = isPad ? 0 : 0.012 * W

        // Hochformat
        let body = CGRect(x: protrusion, y: 0, width: W + 2 * side, height: H + top + bottom)
        let screen = CGRect(x: body.minX + side, y: top, width: W, height: H)
        let bodyRadius: CGFloat = profile.homeButton ? (isPad ? 0.075 : 0.17) * W : screenRadius + side
        let portraitTotal = CGSize(width: body.width + 2 * protrusion, height: body.height)

        var buttons: [CGRect] = []
        if isAndroid {
            // Lautstärke und Ein/Aus rechts
            for (y, h) in [(0.200, 0.105), (0.335, 0.055)] as [(CGFloat, CGFloat)] {
                buttons.append(CGRect(x: body.maxX - rim, y: body.minY + y * body.height,
                                      width: protrusion + rim, height: h * body.height))
            }
        } else if !isPad {
            let left: [(CGFloat, CGFloat)] = profile.homeButton
                ? [(0.120, 0.040), (0.190, 0.070), (0.280, 0.070)]
                : [(0.165, 0.036), (0.235, 0.072), (0.330, 0.072)]
            let right: [(CGFloat, CGFloat)] = profile.homeButton ? [(0.190, 0.080)] : [(0.255, 0.110)]
            for (y, h) in left {
                buttons.append(CGRect(x: 0, y: body.minY + y * body.height,
                                      width: protrusion + rim, height: h * body.height))
            }
            for (y, h) in right {
                buttons.append(CGRect(x: body.maxX - rim, y: body.minY + y * body.height,
                                      width: protrusion + rim, height: h * body.height))
            }
        }

        var cutout: CGPath?
        switch profile.cutout {
        case .none:
            break
        case let .notch(widthRatio, heightRatio):
            cutout = Self.notchPath(screen: screen, width: widthRatio * W, height: heightRatio * W)
        case let .island(widthRatio, heightRatio, topRatio):
            let rect = CGRect(x: screen.midX - widthRatio * W / 2, y: screen.minY + topRatio * W,
                              width: widthRatio * W, height: heightRatio * W)
            cutout = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        case let .hole(centerX, centerY, diameter):
            let d = diameter * W
            cutout = CGPath(ellipseIn: CGRect(x: screen.minX + centerX * W - d / 2, y: screen.minY + centerY * W - d / 2,
                                              width: d, height: d), transform: nil)
        }

        var homeButton: CGRect?, earpiece: CGRect?, camera: CGRect?
        if profile.homeButton {
            let d = (isPad ? 0.085 : 0.155) * W
            homeButton = CGRect(x: body.midX - d / 2, y: screen.maxY + (bottom - d) / 2, width: d, height: d)
            if !isPad {
                let ew = 0.16 * W, eh = 0.022 * W
                earpiece = CGRect(x: body.midX - ew / 2, y: (top - eh) / 2, width: ew, height: eh)
                let cd = 0.035 * W
                camera = CGRect(x: body.midX - ew / 2 - cd * 2.2, y: (top - cd) / 2, width: cd, height: cd)
            } else {
                let cd = 0.016 * W
                camera = CGRect(x: body.midX - cd / 2, y: (top - cd) / 2, width: cd, height: cd)
            }
        } else if isPad {
            let cd = 0.012 * W
            camera = CGRect(x: body.midX - cd / 2, y: (top - cd) / 2, width: cd, height: cd)
        }

        let bezel = body.insetBy(dx: rim, dy: rim)

        if landscape {
            // Oberseite nach links drehen: (x, y) → (y, Breite − x)
            let t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: portraitTotal.width)
            func rotate(_ r: CGRect) -> CGRect { r.applying(t) }
            totalSize = CGSize(width: portraitTotal.height, height: portraitTotal.width)
            bodyRect = rotate(body)
            bezelRect = rotate(bezel)
            screenRect = rotate(screen)
            self.buttons = buttons.map(rotate)
            var transform = t
            self.cutout = cutout.flatMap { $0.copy(using: &transform) }
            self.homeButton = homeButton.map(rotate)
            self.earpiece = earpiece.map(rotate)
            self.camera = camera.map(rotate)
        } else {
            totalSize = portraitTotal
            bodyRect = body
            bezelRect = bezel
            screenRect = screen
            self.buttons = buttons
            self.cutout = cutout
            self.homeButton = homeButton
            self.earpiece = earpiece
            self.camera = camera
        }
        self.bodyRadius = bodyRadius
        self.bezelRadius = max(0, bodyRadius - rim)
    }

    /// Notch oben in der Bildschirmmitte, mit nach innen gewölbten Übergängen
    private static func notchPath(screen: CGRect, width: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x0 = screen.midX - width / 2, x1 = screen.midX + width / 2
        let top = screen.minY, bottom = screen.minY + height
        let r = height * 0.58      // untere Ecken
        let ear = height * 0.30    // Übergang zur Oberkante
        path.move(to: CGPoint(x: x0 - ear, y: top))
        path.addQuadCurve(to: CGPoint(x: x0, y: top + ear), control: CGPoint(x: x0, y: top))
        path.addLine(to: CGPoint(x: x0, y: bottom - r))
        path.addArc(tangent1End: CGPoint(x: x0, y: bottom), tangent2End: CGPoint(x: x0 + r, y: bottom), radius: r)
        path.addLine(to: CGPoint(x: x1 - r, y: bottom))
        path.addArc(tangent1End: CGPoint(x: x1, y: bottom), tangent2End: CGPoint(x: x1, y: bottom - r), radius: r)
        path.addLine(to: CGPoint(x: x1, y: top + ear))
        path.addQuadCurve(to: CGPoint(x: x1 + ear, y: top), control: CGPoint(x: x1, y: top))
        path.closeSubpath()
        return path
    }

    // MARK: Zeichnen (geflippter Kontext erwartet)

    func drawChassis(in ctx: CGContext, color: BezelColor = .graphite) {
        guard showFrame else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // Tasten
        for button in buttons {
            let radius = min(button.width, button.height) / 2
            ctx.addPath(CGPath(roundedRect: button, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(color.button)
            ctx.fillPath()
        }

        // Metallrahmen
        let body = CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let metal = CGGradient(colorsSpace: space, colors: color.metal as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(metal, start: CGPoint(x: bodyRect.minX, y: bodyRect.minY),
                               end: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY), options: [])
        ctx.restoreGState()

        // feine Lichtkante
        ctx.addPath(CGPath(roundedRect: bodyRect.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: max(0, bodyRadius - 0.5), cornerHeight: max(0, bodyRadius - 0.5), transform: nil))
        ctx.setStrokeColor(color.highlight)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // schwarze Front
        ctx.addPath(CGPath(roundedRect: bezelRect, cornerWidth: bezelRadius, cornerHeight: bezelRadius, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.035, alpha: 1))
        ctx.fillPath()

        if let homeButton {
            ctx.addEllipse(in: homeButton)
            ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1))
            ctx.fillPath()
            ctx.addEllipse(in: homeButton.insetBy(dx: homeButton.width * 0.04, dy: homeButton.height * 0.04))
            ctx.setStrokeColor(CGColor(srgbRed: 0.32, green: 0.32, blue: 0.35, alpha: 1))
            ctx.setLineWidth(max(1, homeButton.width * 0.035))
            ctx.strokePath()
        }
        if let earpiece {
            let r = min(earpiece.width, earpiece.height) / 2
            ctx.addPath(CGPath(roundedRect: earpiece, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1))
            ctx.fillPath()
        }
        if let camera {
            ctx.addEllipse(in: camera)
            ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1))
            ctx.fillPath()
        }
    }

    func drawCutout(in ctx: CGContext) {
        guard showFrame, let cutout else { return }
        ctx.addPath(cutout)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()
    }

    /// Umriss für den Schatten (Gehäuse oder, ohne Rahmen, der Bildschirm)
    var silhouettePath: CGPath {
        showFrame
            ? CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
            : screenPath
    }

    var screenPath: CGPath {
        CGPath(roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)
    }
}
