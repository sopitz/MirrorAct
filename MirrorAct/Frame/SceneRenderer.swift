// SPDX-License-Identifier: GPL-3.0-or-later
import CoreImage
import CoreVideo
import Foundation

/// Setzt ein Bildschirmbild mit Gehäuse, Hintergrund, Abstand und Schatten zusammen (Core Image).
/// Gemeinsam für Screenshots, «Screenshot einrahmen» und Aufnahmen; die statischen Ebenen
/// werden pro Bildgrösse einmal gezeichnet.
final class SceneRenderer: @unchecked Sendable {
    let style: FrameStyle
    let profile: DeviceProfile
    let showFrame: Bool
    /// feste Leinwand (Aufnahme, damit eine Drehung die Videogrösse nicht ändert)
    let fixedCanvas: CGSize?

    static let sharedContext = CIContext(options: [.cacheIntermediates: false])

    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var backgroundImage: CGImage? = style.loadBackgroundImage()
    private var cachedSize: CGSize = .zero
    private var scene: Scene?
    /// AVVideoComposition ruft aus Hintergrund-Threads auf
    private let lock = NSLock()

    private struct Scene {
        let canvas: CGSize
        let under: CIImage          // Hintergrund, Schatten, Gehäuse
        let mask: CIImage           // Bildschirmfläche
        let cutout: CIImage?        // Notch / Dynamic Island
        let screenTransform: CGAffineTransform
    }

    private struct Geometry {
        let layout: FrameLayout
        let canvas: CGSize
        let scale: CGFloat
        let origin: CGPoint
    }

    init(style: FrameStyle, profile: DeviceProfile, showFrame: Bool, fixedCanvas: CGSize? = nil,
         context: CIContext = SceneRenderer.sharedContext) {
        self.style = style
        self.profile = profile
        self.showFrame = showFrame
        self.fixedCanvas = fixedCanvas
        self.context = context
    }

    /// Ist das Ergebnis einfach der unveränderte Bildschirm?
    static func isPassthrough(style: FrameStyle, showFrame: Bool) -> Bool {
        !showFrame && style.isPlainScreen && !style.roundedScreen
    }

    static func naturalCanvas(style: FrameStyle, profile: DeviceProfile, showFrame: Bool, screenSize: CGSize) -> CGSize {
        geometry(style: style, profile: profile, showFrame: showFrame, screenSize: screenSize, fixedCanvas: nil).canvas
    }

    static func even(_ value: CGFloat) -> CGFloat {
        let v = Int(value.rounded(.up))
        return CGFloat(v + (v % 2))
    }

    private static func geometry(style: FrameStyle, profile: DeviceProfile, showFrame: Bool,
                                 screenSize: CGSize, fixedCanvas: CGSize?) -> Geometry {
        let layout = FrameLayout(profile: profile, screenSize: screenSize, showFrame: showFrame)
        let total = layout.totalSize
        let pad = CGFloat(style.padding) * min(total.width, total.height)
        let padded = CGSize(width: total.width + 2 * pad, height: total.height + 2 * pad)
        var natural = padded
        if let ratio = style.aspect.ratio {
            if natural.width / natural.height < ratio {
                natural.width = natural.height * ratio
            } else {
                natural.height = natural.width / ratio
            }
        }
        natural = CGSize(width: even(natural.width), height: even(natural.height))
        let canvas = fixedCanvas ?? natural
        let scale = fixedCanvas == nil ? 1 : min(1, canvas.width / padded.width, canvas.height / padded.height)
        let origin = CGPoint(x: ((canvas.width - total.width * scale) / 2).rounded(),
                             y: ((canvas.height - total.height * scale) / 2).rounded())
        return Geometry(layout: layout, canvas: canvas, scale: scale, origin: origin)
    }

    var canvasSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return scene?.canvas ?? fixedCanvas
    }

    func image(screen: CIImage) -> CIImage {
        let size = screen.extent.size
        lock.lock()
        if scene == nil || size != cachedSize {
            scene = buildScene(for: size)
            cachedSize = size
        }
        let current = scene
        lock.unlock()
        guard let scene = current else { return screen }
        let placed = screen.transformed(by: scene.screenTransform)
        var result = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: scene.under,
            kCIInputMaskImageKey: scene.mask,
        ])
        if let cutout = scene.cutout {
            result = cutout.composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: scene.canvas))
    }

    func cgImage(screen: CGImage) -> CGImage? {
        let result = image(screen: CIImage(cgImage: screen))
        guard let canvas = canvasSize else { return nil }
        return context.createCGImage(result, from: CGRect(origin: .zero, size: canvas),
                                     format: .RGBA8, colorSpace: colorSpace)
    }

    func render(screen pixelBuffer: CVPixelBuffer, into output: CVPixelBuffer) {
        let result = image(screen: CIImage(cvPixelBuffer: pixelBuffer))
        guard let canvas = canvasSize else { return }
        context.render(result, to: output, bounds: CGRect(origin: .zero, size: canvas), colorSpace: colorSpace)
    }

    // MARK: Statische Ebenen

    private func buildScene(for size: CGSize) -> Scene? {
        let g = Self.geometry(style: style, profile: profile, showFrame: showFrame, screenSize: size,
                              fixedCanvas: fixedCanvas)
        let layout = g.layout
        let canvas = g.canvas
        let device = CGAffineTransform(translationX: g.origin.x, y: g.origin.y).scaledBy(x: g.scale, y: g.scale)
        let style = self.style
        let backgroundImage = self.backgroundImage
        let showFrame = self.showFrame

        guard let under = draw(canvas, { ctx in
            style.drawBackground(in: ctx, rect: CGRect(origin: .zero, size: canvas), image: backgroundImage)
            if style.shadow {
                let d = min(layout.totalSize.width, layout.totalSize.height) * g.scale
                ctx.saveGState()
                // Schattenversatz wirkt im Geräteraum (y nach oben): negativ = nach unten
                ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.03), blur: d * 0.09,
                              color: CGColor(gray: 0, alpha: 0.45))
                ctx.concatenate(device)
                ctx.addPath(layout.silhouettePath)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.concatenate(device)
            layout.drawChassis(in: ctx, color: style.bezelColor)
            ctx.restoreGState()
        }), let mask = draw(canvas, { ctx in
            ctx.concatenate(device)
            if showFrame || style.roundedScreen {
                ctx.addPath(layout.screenPath)
            } else {
                ctx.addRect(layout.screenRect)
            }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
        }) else { return nil }

        var cutout: CIImage?
        if showFrame, layout.cutout != nil {
            cutout = draw(canvas) { ctx in
                ctx.concatenate(device)
                layout.drawCutout(in: ctx)
            }
        }

        let screen = layout.screenRect.applying(device)
        let transform = CGAffineTransform(scaleX: g.scale, y: g.scale)
            .concatenating(CGAffineTransform(translationX: screen.minX, y: canvas.height - screen.maxY))
        return Scene(canvas: canvas, under: under, mask: mask, cutout: cutout, screenTransform: transform)
    }

    /// Zeichnet in einen geflippten Kontext (oben links, y nach unten)
    private func draw(_ size: CGSize, _ block: (CGContext) -> Void) -> CIImage? {
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        block(ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
