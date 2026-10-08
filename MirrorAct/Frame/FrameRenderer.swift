// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreVideo
import UniformTypeIdentifiers
import VideoToolbox

/// Rendert Bildschirminhalte mit Gehäuse in ein Bild (Screenshots, "Screenshot einrahmen").
enum FrameRenderer {
    /// Bildschirminhalt mit Gestaltung (Rahmen, Hintergrund …) in Originalauflösung
    static func render(screen: CGImage, profile: DeviceProfile, showFrame: Bool,
                       style: FrameStyle = AppSettings.shared.style) -> CGImage? {
        if SceneRenderer.isPassthrough(style: style, showFrame: showFrame) { return screen }
        return SceneRenderer(style: style, profile: profile, showFrame: showFrame).cgImage(screen: screen)
    }

    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func copyToPasteboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    /// "Screenshot einrahmen…": gerahmte Kopie neben der Originaldatei
    static func frameScreenshotFiles(_ urls: [URL], showFrame: Bool = true,
                                     style: FrameStyle = AppSettings.shared.style) -> [URL] {
        var outputs: [URL] = []
        for url in urls {
            guard let image = loadImage(at: url) else { continue }
            let size = CGSize(width: image.width, height: image.height)
            let profile = DeviceProfile.resolve(modelIdentifier: nil, screenPixels: size, frameSize: size)
            guard let framed = render(screen: image, profile: profile, showFrame: showFrame, style: style)
            else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let out = url.deletingLastPathComponent().appendingPathComponent(String(localized: "\(base) (Framed).png"))
            if writePNG(framed, to: out) { outputs.append(out) }
        }
        return outputs
    }
}
