// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Vollbild-Präsentation: Gerät mittig auf dem gewählten Hintergrund, ohne Kopfleiste.
/// Beenden mit Esc.
final class PresentationWindow: NSWindow {
    var onExit: (() -> Void)?
    let content = PresentationContentView(frame: .zero)

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenNone, .canJoinAllSpaces]
        level = .normal
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onExit?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onExit?()
    }
}

final class PresentationContentView: NSView {
    private let backgroundLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        backgroundLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(backgroundLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        CATransaction.commit()
    }

    /// Hintergrund aus der Gestaltung; transparent wird schwarz
    func setBackground(style: FrameStyle, scale: CGFloat) {
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard style.background != .transparent,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            backgroundLayer.contents = nil
            return
        }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        style.drawBackground(in: ctx, rect: CGRect(origin: .zero, size: size), image: style.loadBackgroundImage())
        backgroundLayer.contents = ctx.makeImage()
    }
}
