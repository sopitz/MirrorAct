// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Zeichnet das Gehäuse, enthält die Videoanzeige und darüber Notch/Dynamic Island.
final class DeviceFrameView: NSView, NSDraggingSource {
    let videoView = VideoDisplayView(frame: .zero)
    private let cutoutView = CutoutView(frame: .zero)
    let placeholder = NSTextField(labelWithString: "")

    /// Ziehen in der Ecke unten rechts ändert die Grösse
    var onResizeDrag: ((_ phase: NSEvent.Phase, _ delta: CGSize) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    /// ⌥-Ziehen: Screenshot als Datei herausziehen
    var onDragOut: ((NSEvent) -> Void)?
    /// Rechtsklick
    var menuProvider: (() -> NSMenu?)?

    var bezelColor: BezelColor = .graphite {
        didSet { if bezelColor != oldValue { needsDisplay = true } }
    }

    var layoutModel: FrameLayout? {
        didSet {
            needsLayout = true
            needsDisplay = true
            cutoutView.layoutModel = layoutModel
            window?.invalidateCursorRects(for: self)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(videoView)
        addSubview(cutoutView)
        placeholder.textColor = NSColor(white: 1, alpha: 0.55)
        placeholder.font = .systemFont(ofSize: 13, weight: .medium)
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 3
        placeholder.lineBreakMode = .byWordWrapping
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        guard let model = layoutModel else { return }
        videoView.frame = model.screenRect
        videoView.cornerRadius = model.screenRadius
        cutoutView.frame = bounds
        let inset = model.screenRect.insetBy(dx: 24, dy: 0)
        let height: CGFloat = 60
        placeholder.frame = CGRect(x: inset.minX, y: model.screenRect.midY - height / 2,
                                   width: max(10, inset.width), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model = layoutModel, let ctx = NSGraphicsContext.current?.cgContext else { return }
        model.drawChassis(in: ctx, color: bezelColor)
    }

    // MARK: Maus

    private var resizeRect: CGRect {
        guard let model = layoutModel else { return .zero }
        let size: CGFloat = 36
        return CGRect(x: model.bodyRect.maxX - size, y: model.bodyRect.maxY - size, width: size, height: size)
    }

    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(resizeRect, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(resizeRect, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option), let onDragOut {
            onDragOut(event)
            return
        }
        guard resizeRect.contains(point), let onResizeDrag else {
            window?.performDrag(with: event)
            return
        }
        let start = NSEvent.mouseLocation
        onResizeDrag(.began, .zero)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let now = NSEvent.mouseLocation
            let delta = CGSize(width: now.x - start.x, height: start.y - now.y)
            if next.type == .leftMouseUp {
                onResizeDrag(.ended, delta)
                break
            }
            onResizeDrag(.changed, delta)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Notch / Dynamic Island über dem Video
private final class CutoutView: NSView {
    var layoutModel: FrameLayout? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let model = layoutModel, let ctx = NSGraphicsContext.current?.cgContext else { return }
        model.drawCutout(in: ctx)
    }
}
