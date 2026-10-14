// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Vollbild-Präsentation: Gerät mittig auf dem gewählten Hintergrund, ohne Kopfleiste.
/// Beenden mit Esc, ⌃⌘F oder dem Knopf oben links, der erscheint, sobald sich die Maus bewegt.
final class PresentationWindow: NSWindow {
    /// so lange bleibt der Knopf nach der letzten Mausbewegung sichtbar
    static var controlsHideDelay: TimeInterval = 3

    var onExit: (() -> Void)?
    let content = PresentationContentView(frame: .zero)
    let exitButton = NSButton(title: String(localized: "Exit Presentation"),
                              image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                              target: nil, action: nil)
    private let controls = NSVisualEffectView()
    private var hideTimer: Timer?

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
        setUpControls()
        content.onMouseMoved = { [weak self] in self?.showControls() }
        showControls()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Gerät einsetzen, unter dem Knopf
    func embed(_ view: NSView) {
        content.addSubview(view, positioned: .below, relativeTo: controls)
    }

    override func orderOut(_ sender: Any?) {
        hideTimer?.invalidate()
        super.orderOut(sender)
    }

    // MARK: Knopf zum Beenden

    private func setUpControls() {
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.appearance = NSAppearance(named: .darkAqua)
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 16
        controls.layer?.masksToBounds = true
        controls.translatesAutoresizingMaskIntoConstraints = false

        exitButton.isBordered = false
        exitButton.imagePosition = .imageLeading
        exitButton.imageHugsTitle = true
        exitButton.font = .systemFont(ofSize: 13, weight: .medium)
        exitButton.contentTintColor = .labelColor
        exitButton.target = self
        exitButton.action = #selector(exitClicked)
        exitButton.toolTip = String(localized: "Exit Presentation (Esc or ⌃⌘F)")

        let key = NSTextField(labelWithString: "esc")
        key.font = .systemFont(ofSize: 11, weight: .medium)
        key.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [exitButton, key])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controls.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
    }

    @objc private func exitClicked() {
        onExit?()
    }

    /// zeigen und nach controlsHideDelay ohne Mausbewegung wieder ausblenden
    func showControls() {
        controls.alphaValue = 1
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.controlsHideDelay, repeats: false) { [weak self] _ in
            self?.hideControlsIfIdle()
        }
    }

    private func hideControlsIfIdle() {
        let mouse = content.convert(mouseLocationOutsideOfEventStream, from: nil)
        if controls.frame.contains(mouse) {
            showControls()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            controls.animator().alphaValue = 0
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

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
    var onMouseMoved: (() -> Void)?
    private let backgroundLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        backgroundLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(backgroundLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }

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
