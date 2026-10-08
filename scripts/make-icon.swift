// SPDX-License-Identifier: GPL-3.0-or-later
// Erzeugt Resources/AppIcon.icns (eigenes Motiv: zwei Telefone, eines gespiegelt)
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024

func draw(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.05, green: 0.36, blue: 0.40, alpha: 1),
        CGColor(srgbRed: 0.10, green: 0.62, blue: 0.58, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    ctx.restoreGState()

    func phone(_ rect: CGRect, alpha: CGFloat, screen: Bool) {
        let body = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2, cornerHeight: rect.width * 0.2, transform: nil)
        ctx.addPath(body)
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.08, blue: 0.10, alpha: alpha))
        ctx.fillPath()
        ctx.addPath(body)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        ctx.setLineWidth(18)
        ctx.strokePath()
        guard screen else { return }
        let inner = rect.insetBy(dx: rect.width * 0.09, dy: rect.width * 0.09)
        let innerPath = CGPath(roundedRect: inner, cornerWidth: inner.width * 0.15, cornerHeight: inner.width * 0.15, transform: nil)
        ctx.saveGState()
        ctx.addPath(innerPath); ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.98, green: 0.80, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.45, blue: 0.40, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: inner.minX, y: inner.maxY), end: CGPoint(x: inner.maxX, y: inner.minY), options: [])
        ctx.restoreGState()
        // Dynamic Island
        let island = CGRect(x: rect.midX - rect.width * 0.17, y: inner.maxY - rect.width * 0.12, width: rect.width * 0.34, height: rect.width * 0.08)
        ctx.addPath(CGPath(roundedRect: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.08, blue: 0.10, alpha: 1))
        ctx.fillPath()
    }
    phone(CGRect(x: 250, y: 260, width: 300, height: 560), alpha: 0.35, screen: false)
    phone(CGRect(x: 440, y: 200, width: 330, height: 620), alpha: 1, screen: true)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
draw(NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
