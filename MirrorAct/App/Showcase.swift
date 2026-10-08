// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import SwiftUI

/// Bilder fürs README aus den echten Ansichten der App (nur Debug-Builds).
/// Die App zeichnet ihre eigenen Fenster in Bilder; das iPhone-Bild kommt aus der laufenden
/// Spiegelung (sonst ein Testbild).
///   MirrorAct --showcase <ordner>             ohne Gerät, mit Testbild
///   laufende App: DistributedNotification "io.github.sopitz.MirrorAct.showcase", userInfo["dir"]
@MainActor
enum Showcase {
    static let notification = Notification.Name("io.github.sopitz.MirrorAct.showcase")
    private static let scale: CGFloat = 2

    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let dir = (note.userInfo?["dir"] as? String) ?? NSTemporaryDirectory() + "MirrorAct-Showcase"
            MainActor.assumeIsolated { export(to: URL(fileURLWithPath: dir)) }
        }
    }

    static func export(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let live = AppModel.shared.keyMirror?.session
        let screen = live?.sink.latest.flatMap(FrameRenderer.cgImage(from:))
            ?? RenderTest.testScreen(size: CGSize(width: 1170, height: 2532))!
        let model = live?.modelIdentifier ?? "iPhone14,2"
        let profile = live?.profile ?? DeviceProfile.forModelIdentifier(model)!

        let session = MirrorSession(id: "showcase", kind: live?.kind ?? .cable,
                                    deviceName: live?.kind == .android ? "Phone" : "iPhone",
                                    modelIdentifier: model, muted: false)
        session.state = .live
        // Gerätetasten der Werkzeugleiste zeigen; danach gehört die Bedienung wieder der echten Sitzung
        let liveControl = live?.control
        session.control = liveControl
        defer {
            if let liveControl {
                session.control = nil
                live?.control = liveControl
            }
        }

        write(mirror(screen: screen, profile: profile, session: session), dir, "mirror.png")
        write(startWindow(), dir, "start-window.png")
        if let editor = editor(screen: screen, model: model) { write(editor, dir, "editor.png") }
        write(framed(screen: screen, profile: profile), dir, "framed.png")
        Log.info("Showcase: \(dir.path) (live frame: \(live?.sink.latest != nil))")
    }

    // MARK: Motive

    /// Spiegelfenster mit Werkzeugleiste und offenem Stil-Panel auf einem Schreibtisch
    private static func mirror(screen: CGImage, profile: DeviceProfile, session: MirrorSession) -> CGImage? {
        let canvas = CGSize(width: 1400, height: 900)
        let device = deviceImage(screen: screen, profile: profile, height: 780)
        let chrome = MirrorChrome()
        chrome.hovering = true
        let actions = MirrorActions(close: {}, present: {}, zoomIn: {}, zoomOut: {}, actualSize: {}, lifeSize: {},
                                    pixelPerfect: {}, fitToScreen: {}, saveScreenshot: {}, copyScreenshot: {},
                                    screenshotFile: { nil }, toggleRecording: {}, disconnect: {})
        let rail = snapshot(MirrorToolRail(session: session, chrome: chrome, actions: actions).padding(12))
        let panel = snapshot(StylePanel(session: session, actions: actions)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .padding(12))

        return compose(canvas) { ctx in
            wallpaper(ctx, canvas)
            guard let device, let rail, let panel else { return }
            let d = size(of: device), r = size(of: rail), p = size(of: panel)
            let width = d.width + 10 + r.width - 24 + 14 + p.width - 24
            let x = (canvas.width - width) / 2
            let deviceRect = CGRect(x: x, y: (canvas.height - d.height) / 2, width: d.width, height: d.height)
            draw(device, in: deviceRect, ctx, shadow: true)
            let railRect = CGRect(x: deviceRect.maxX + 10 - 12, y: deviceRect.midY - r.height / 2, width: r.width, height: r.height)
            draw(rail, in: railRect, ctx, shadow: false)
            let panelRect = CGRect(x: railRect.maxX - 12 + 14 - 12, y: deviceRect.midY - p.height / 2 + 20,
                                   width: p.width, height: p.height)
            draw(panel, in: panelRect, ctx, shadow: true)
        }
    }

    /// Startfenster mit Beispielgeräten
    private static func startWindow() -> CGImage? {
        let preview = LauncherView.Preview(cards: [
            .init(id: "1", name: "iPhone 13 Pro", modelIdentifier: "iPhone14,2", status: String(localized: "Ready via cable"),
                  state: .ready, transport: .cable, cableDevice: nil),
            .init(id: "2", name: "iPhone 16 Pro", modelIdentifier: "iPhone17,1", status: String(localized: "Mirroring wirelessly"),
                  state: .mirroring, transport: .wireless, cableDevice: nil),
            .init(id: "3", name: "iPad Air", modelIdentifier: "iPad13,16", status: String(localized: "Cable not connected"),
                  state: .offline, transport: .cable, cableDevice: nil),
        ], status: String(localized: "1 device via cable · mirroring wirelessly"), pin: "4826")
        let size = CGSize(width: 760, height: 520)
        guard let content = snapshot(LauncherView(preview: preview), size: size) else { return nil }
        return windowShot(content, size: size, title: nil, canvas: CGSize(width: 960, height: 700))
    }

    /// Editor mit einem Screenshot auf Verlauf
    private static func editor(screen: CGImage, model: String) -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("iPhone Screenshot.png")
        guard FrameRenderer.writePNG(screen, to: file), let document = EditorDocument(urls: [file]) else { return nil }
        document.modelSelection = model
        document.showFrame = true
        document.style = FrameStyle(bezelColor: .naturalTitanium, background: .gradient, gradient: .evening,
                                    padding: 0.14, shadow: true, aspect: .landscape16x9)
        document.refresh()
        let size = CGSize(width: 1120, height: 700)
        guard let content = snapshot(EditorView(document: document), size: size) else { return nil }
        return windowShot(content, size: size, title: String(localized: "Edit – \(document.title)"),
                          canvas: CGSize(width: 1320, height: 900))
    }

    /// Ergebnis: Screenshot mit Rahmen, Verlauf und Schatten (16:9)
    private static func framed(screen: CGImage, profile: DeviceProfile) -> CGImage? {
        FrameRenderer.render(screen: screen, profile: profile, showFrame: true,
                             style: FrameStyle(bezelColor: .naturalTitanium, background: .gradient, gradient: .ocean,
                                               padding: 0.16, shadow: true, aspect: .landscape16x9))
    }

    // MARK: Bausteine

    /// Gerät im Rahmen in gewünschter Höhe (Punkte), gerendert mit doppelter Auflösung
    private static func deviceImage(screen: CGImage, profile: DeviceProfile, height: CGFloat) -> CGImage? {
        let source = CGSize(width: screen.width, height: screen.height)
        let unit = FrameLayout(profile: profile, screenSize: source, showFrame: true).totalSize
        let factor = height * scale / unit.height
        let target = CGSize(width: (source.width * factor).rounded(), height: (source.height * factor).rounded())
        let resized = EditorDocument.downscaled(screen, maxSide: max(target.width, target.height))
        return FrameRenderer.render(screen: resized, profile: profile, showFrame: true,
                                    style: FrameStyle(bezelColor: AppSettings.shared.style.bezelColor))
    }

    /// echte SwiftUI-Ansicht in einem unsichtbaren Fenster zeichnen (inkl. nativer Bedienelemente)
    private static func snapshot<V: View>(_ view: V, size: CGSize? = nil) -> CGImage? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    /// Fensterinhalt mit Ecken, Titelleiste und Schatten auf dem Schreibtisch
    private static func windowShot(_ content: CGImage, size: CGSize, title: String?, canvas: CGSize) -> CGImage? {
        let titleHeight: CGFloat = title == nil ? 0 : 28
        let frame = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height - titleHeight) / 2,
                           width: size.width, height: size.height + titleHeight)
        return compose(canvas) { ctx in
            wallpaper(ctx, canvas)
            let path = CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 40 * scale,
                          color: CGColor(gray: 0, alpha: 0.55))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let title {
                ctx.setFillColor(CGColor(gray: 0.17, alpha: 1))
                ctx.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleHeight))
                let text = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor(white: 0.85, alpha: 1)])
                let bounds = text.size()
                drawText(text, at: CGPoint(x: frame.midX - bounds.width / 2, y: frame.minY + (titleHeight - bounds.height) / 2), ctx)
            }
            draw(content, in: CGRect(x: frame.minX, y: frame.minY + titleHeight, width: size.width, height: size.height), ctx, shadow: false)
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
            ctx.setLineWidth(1)
            ctx.strokePath()
            for (i, color) in [CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                               CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                               CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: frame.minX + 14 + CGFloat(i) * 20, y: frame.minY + 8, width: 12, height: 12))
            }
        }
    }

    private static func wallpaper(_ ctx: CGContext, _ size: CGSize) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.09, green: 0.32, blue: 0.40, alpha: 1),
            CGColor(srgbRed: 0.20, green: 0.16, blue: 0.38, alpha: 1),
            CGColor(srgbRed: 0.42, green: 0.20, blue: 0.36, alpha: 1)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        let glow = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.35, green: 0.85, blue: 0.80, alpha: 0.35),
            CGColor(srgbRed: 0.35, green: 0.85, blue: 0.80, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size.width * 0.25, y: size.height * 0.2), startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.25, y: size.height * 0.2), endRadius: size.width * 0.6,
                               options: [])
    }

    /// Zeichenfläche in Punkten (oben links, y nach unten), doppelte Auflösung
    private static func compose(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    private static func size(of image: CGImage) -> CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    private static func draw(_ image: CGImage, in rect: CGRect, _ ctx: CGContext, shadow: Bool) {
        ctx.saveGState()
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: 0.5))
        }
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawText(_ text: NSAttributedString, at point: CGPoint, _ ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func write(_ image: CGImage?, _ dir: URL, _ name: String) {
        guard let image else {
            Log.error("Showcase: \(name) failed")
            return
        }
        FrameRenderer.writePNG(image, to: dir.appendingPathComponent(name))
    }
}
#endif
