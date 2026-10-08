// SPDX-License-Identifier: GPL-3.0-or-later
import CoreImage
import Foundation

enum DuoPose: String, CaseIterable, Identifiable, Codable {
    case sideBySide, staggered, tilted, perspective
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sideBySide: return "Nebeneinander"
        case .staggered: return "Versetzt"
        case .tilted: return "Gekippt"
        case .perspective: return "Perspektive"
        }
    }
}

/// Zwei Geräte auf einem gemeinsamen Hintergrund, in verschiedenen Posen
enum DuoRenderer {
    static func render(screens: [CGImage], profiles: [DeviceProfile], style: FrameStyle, showFrame: Bool,
                       pose: DuoPose, context: CIContext = SceneRenderer.sharedContext) -> CGImage? {
        guard screens.count == 2, profiles.count == 2 else { return nil }

        // 1. jedes Gerät einzeln, freigestellt
        var deviceStyle = style
        deviceStyle.background = .transparent
        deviceStyle.padding = 0
        deviceStyle.shadow = false
        deviceStyle.aspect = .auto
        var devices: [CIImage] = []
        for (screen, profile) in zip(screens, profiles) {
            guard let image = SceneRenderer(style: deviceStyle, profile: profile, showFrame: showFrame)
                .cgImage(screen: screen) else { return nil }
            devices.append(CIImage(cgImage: image))
        }

        // 2. gleiche Höhe
        let height = devices.map(\.extent.height).max() ?? 1
        devices = devices.map { $0.transformed(by: CGAffineTransform(scaleX: height / $0.extent.height,
                                                                      y: height / $0.extent.height)) }
        let w0 = devices[0].extent.width, w1 = devices[1].extent.width
        let gap = 0.12 * min(w0, w1)

        // 3. Pose (Core Image: y nach oben)
        var placed: [CIImage]
        switch pose {
        case .sideBySide:
            placed = [devices[0],
                      devices[1].transformed(by: CGAffineTransform(translationX: w0 + gap, y: 0))]
        case .staggered:
            placed = [devices[0].transformed(by: CGAffineTransform(translationX: 0, y: height * 0.07)),
                      devices[1].transformed(by: CGAffineTransform(translationX: w0 + gap, y: -height * 0.07))]
        case .tilted:
            placed = [rotated(devices[0], degrees: 7),
                      rotated(devices[1], degrees: -7).transformed(by: CGAffineTransform(translationX: w0 * 0.82, y: 0))]
        case .perspective:
            placed = [perspective(devices[0], facingRight: true),
                      perspective(devices[1], facingRight: false).transformed(by: CGAffineTransform(translationX: w0 * 0.92 + gap * 0.5, y: 0))]
        }

        // 4. Leinwand: Inhalt + Abstand, ggf. Seitenverhältnis
        let content = placed.reduce(CGRect.null) { $0.union($1.extent) }
        let pad = CGFloat(style.padding) * min(w0, w1)
        var canvas = CGSize(width: content.width + 2 * pad, height: content.height + 2 * pad)
        if let ratio = style.aspect.ratio {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio } else { canvas.height = canvas.width / ratio }
        }
        canvas = CGSize(width: SceneRenderer.even(canvas.width), height: SceneRenderer.even(canvas.height))
        let shift = CGAffineTransform(translationX: (canvas.width - content.width) / 2 - content.minX,
                                      y: (canvas.height - content.height) / 2 - content.minY)
        placed = placed.map { $0.transformed(by: shift) }

        // 5. Hintergrund, Schatten, Geräte
        var result = background(style: style, size: canvas)
        if style.shadow {
            for device in placed {
                result = shadow(of: device, height: height).composited(over: result)
            }
        }
        for device in placed {
            result = device.composited(over: result)
        }
        let rect = CGRect(origin: .zero, size: canvas)
        return context.createCGImage(result.cropped(to: rect), from: rect, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private static func rotated(_ image: CIImage, degrees: CGFloat) -> CIImage {
        let e = image.extent
        let t = CGAffineTransform(translationX: e.midX, y: e.midY)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -e.midX, y: -e.midY)
        return image.transformed(by: t)
    }

    /// leicht um die Hochachse gedreht: die abgewandte Seite wird schmaler und kürzer
    private static func perspective(_ image: CIImage, facingRight: Bool) -> CIImage {
        let e = image.extent
        let near: CGFloat = 1, far: CGFloat = 0.90, depth: CGFloat = 0.86
        let w = e.width, h = e.height
        let farInset = h * (near - far) / 2
        let topLeft, topRight, bottomRight, bottomLeft: CGPoint
        if facingRight {
            topLeft = CGPoint(x: 0, y: h)
            bottomLeft = CGPoint(x: 0, y: 0)
            topRight = CGPoint(x: w * depth, y: h - farInset)
            bottomRight = CGPoint(x: w * depth, y: farInset)
        } else {
            topLeft = CGPoint(x: w * (1 - depth), y: h - farInset)
            bottomLeft = CGPoint(x: w * (1 - depth), y: farInset)
            topRight = CGPoint(x: w, y: h)
            bottomRight = CGPoint(x: w, y: 0)
        }
        let moved = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        return moved.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: topLeft),
            "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomRight": CIVector(cgPoint: bottomRight),
            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
        ])
    }

    private static func shadow(of device: CIImage, height: CGFloat) -> CIImage {
        device
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: height * 0.03])
            .transformed(by: CGAffineTransform(translationX: 0, y: -height * 0.02))
    }

    private static func background(style: FrameStyle, size: CGSize) -> CIImage {
        let width = Int(size.width), height = Int(size.height)
        guard style.background != .transparent,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size)) }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        style.drawBackground(in: ctx, rect: CGRect(origin: .zero, size: size), image: style.loadBackgroundImage())
        return ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage(color: .clear)
    }
}
