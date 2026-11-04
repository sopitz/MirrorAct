// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Geometry of the chassis around a screen of a given size.
/// Coordinates: origin top left, y down (like a flipped NSView).
/// In landscape, the top of the device (Notch) is on the left.
struct FrameLayout {
    let profile: DeviceProfile
    let showFrame: Bool
    let landscape: Bool

    let totalSize: CGSize
    let bodyRect: CGRect
    let bezelRect: CGRect
    let screenRect: CGRect
    /// outlines; corners on the left (portrait) may differ from the right ones
    let bodyPath: CGPath
    let bezelPath: CGPath
    let screenPath: CGPath
    /// corner radius of the screen if all four corners are equal; nil if they differ (see `screenPath`)
    let uniformScreenRadius: CGFloat?
    let buttons: [CGRect]
    let cutout: CGPath?
    let homeButton: CGRect?
    let earpiece: CGRect?
    let camera: CGRect?

    init(profile: DeviceProfile, screenSize: CGSize, showFrame: Bool) {
        self.profile = profile
        self.showFrame = showFrame
        let isLandscape = screenSize.width > screenSize.height
        landscape = isLandscape

        let W = min(screenSize.width, screenSize.height)
        let H = max(screenSize.width, screenSize.height)
        let screenRadius = profile.screenCornerRatio * W
        let screenRadiusLeft = profile.leftCornerRatio.map { $0 * W } ?? screenRadius
        uniformScreenRadius = screenRadiusLeft == screenRadius ? screenRadius : nil
        // Landscape: rotate the top to the left, (x, y) → (y, portrait width − x)
        func rotation(portraitWidth: CGFloat) -> CGAffineTransform {
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: portraitWidth)
        }
        func oriented(_ path: CGPath, portraitWidth: CGFloat) -> CGPath {
            guard isLandscape else { return path }
            var t = rotation(portraitWidth: portraitWidth)
            return path.copy(using: &t) ?? path
        }

        guard showFrame else {
            let rect = CGRect(origin: .zero, size: screenSize)
            totalSize = screenSize
            bodyRect = rect
            bezelRect = rect
            screenRect = rect
            let path = oriented(Self.roundedRect(CGRect(x: 0, y: 0, width: W, height: H), radius: screenRadius,
                                                 left: screenRadiusLeft), portraitWidth: W)
            bodyPath = path
            bezelPath = path
            screenPath = path
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
            side = profile.bezelRatio.map { $0 * W } ?? (isPad ? 0.045 : 0.052) * W
            top = side
            bottom = side
        }
        let rim = (isPad ? 0.010 : 0.014) * W
        let protrusion: CGFloat = isPad ? 0 : 0.012 * W

        typealias Button = DeviceProfile.Button
        let buttonSpecs: [Button]
        if let custom = profile.buttons {
            buttonSpecs = custom
        } else if isAndroid {
            // Volume and power on the right
            buttonSpecs = [Button(edge: .right, at: 0.200, length: 0.105), Button(edge: .right, at: 0.335, length: 0.055)]
        } else if isPad {
            buttonSpecs = []
        } else {
            let left: [(CGFloat, CGFloat)] = profile.homeButton
                ? [(0.120, 0.040), (0.190, 0.070), (0.280, 0.070)]
                : [(0.165, 0.036), (0.235, 0.072), (0.330, 0.072)]
            let right: [(CGFloat, CGFloat)] = profile.homeButton ? [(0.190, 0.080)] : [(0.255, 0.110)]
            buttonSpecs = left.map { Button(edge: .left, at: $0.0, length: $0.1) }
                + right.map { Button(edge: .right, at: $0.0, length: $0.1) }
        }
        func depth(_ button: Button) -> CGFloat { button.depth.map { $0 * W } ?? protrusion }
        // room for the buttons; left and right always as wide as a side button, as before
        func margin(_ edge: Button.Edge) -> CGFloat {
            let deepest = buttonSpecs.filter { $0.edge == edge }.map(depth).max() ?? 0
            return edge == .left || edge == .right ? max(protrusion, deepest) : deepest
        }

        // Portrait
        let body = CGRect(x: margin(.left), y: margin(.top), width: W + 2 * side, height: H + top + bottom)
        let screen = CGRect(x: body.minX + side, y: body.minY + top, width: W, height: H)
        let bodyRadius: CGFloat = profile.homeButton ? (isPad ? 0.075 : 0.17) * W : screenRadius + side
        // a smaller corner on the left (hinge) leaves the chassis corner as round as the screen's
        let bodyRadiusLeft = profile.leftCornerRatio == nil ? bodyRadius : screenRadiusLeft
        let portraitTotal = CGSize(width: body.maxX + margin(.right), height: body.maxY + margin(.bottom))

        let buttons: [CGRect] = buttonSpecs.map { button in
            let d = depth(button)
            switch button.edge {
            case .left:
                return CGRect(x: body.minX - d, y: body.minY + button.at * body.height,
                              width: d + rim, height: button.length * body.height)
            case .right:
                return CGRect(x: body.maxX - rim, y: body.minY + button.at * body.height,
                              width: d + rim, height: button.length * body.height)
            case .top:
                return CGRect(x: body.minX + button.at * body.width, y: body.minY - d,
                              width: button.length * body.width, height: d + rim)
            case .bottom:
                return CGRect(x: body.minX + button.at * body.width, y: body.maxY - rim,
                              width: button.length * body.width, height: d + rim)
            }
        }

        var cutout: CGPath?
        switch profile.cutout {
        case .none:
            break  // also a camera under the display
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
                earpiece = CGRect(x: body.midX - ew / 2, y: body.minY + (top - eh) / 2, width: ew, height: eh)
                let cd = 0.035 * W
                camera = CGRect(x: body.midX - ew / 2 - cd * 2.2, y: body.minY + (top - cd) / 2, width: cd, height: cd)
            } else {
                let cd = 0.016 * W
                camera = CGRect(x: body.midX - cd / 2, y: body.minY + (top - cd) / 2, width: cd, height: cd)
            }
        } else if isPad {
            let cd = 0.012 * W
            camera = CGRect(x: body.midX - cd / 2, y: body.minY + (top - cd) / 2, width: cd, height: cd)
        }

        let bezel = body.insetBy(dx: rim, dy: rim)
        bodyPath = oriented(Self.roundedRect(body, radius: bodyRadius, left: bodyRadiusLeft),
                            portraitWidth: portraitTotal.width)
        bezelPath = oriented(Self.roundedRect(bezel, radius: max(0, bodyRadius - rim), left: max(0, bodyRadiusLeft - rim)),
                             portraitWidth: portraitTotal.width)
        screenPath = oriented(Self.roundedRect(screen, radius: screenRadius, left: screenRadiusLeft),
                              portraitWidth: portraitTotal.width)

        if landscape {
            let t = rotation(portraitWidth: portraitTotal.width)
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
    }

    /// Rounded rectangle; `left` is the radius of the two left corners
    static func roundedRect(_ rect: CGRect, radius: CGFloat, left: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let r = min(radius, limit), l = min(left, limit)
        if r == l { return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: l)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: l)
        path.closeSubpath()
        return path
    }

    /// Notch at the top center of the screen, with inward-curved transitions
    private static func notchPath(screen: CGRect, width: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let x0 = screen.midX - width / 2, x1 = screen.midX + width / 2
        let top = screen.minY, bottom = screen.minY + height
        let r = height * 0.58      // bottom corners
        let ear = height * 0.30    // transition to the top edge
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

    // MARK: Drawing (expects a flipped context)

    func drawChassis(in ctx: CGContext, color: BezelColor = .graphite) {
        guard showFrame else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // Buttons
        for button in buttons {
            let radius = min(button.width, button.height) / 2
            ctx.addPath(CGPath(roundedRect: button, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(color.button)
            ctx.fillPath()
        }

        // Metal frame
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let metal = CGGradient(colorsSpace: space, colors: color.metal as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(metal, start: CGPoint(x: bodyRect.minX, y: bodyRect.minY),
                               end: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY), options: [])
        ctx.restoreGState()

        // fine highlight edge, inside the outline
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(color.highlight)
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        // black front
        ctx.addPath(bezelPath)
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

    /// Outline for the shadow (chassis or, without a frame, the screen)
    var silhouettePath: CGPath { bodyPath }
}
