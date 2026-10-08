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

    /// Bedienung des Geräts (nil = nur anzeigen): Klicken/Ziehen, Scrollen und Mittelklick im
    /// Bildschirm, Tasten und Einfügen. Punkte in Koordinaten dieser Ansicht.
    var onTouch: ((TouchPhase, CGPoint) -> Void)?
    var onScroll: ((NSEvent, CGPoint) -> Void)?
    var onMiddleClick: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onPaste: (() -> Void)?

    private func isOnScreen(_ point: CGPoint) -> Bool {
        layoutModel?.screenPath.contains(point) == true
    }

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
    override var acceptsFirstResponder: Bool { onKey != nil }

    /// ein Klick auf das inaktive Fenster bedient das Gerät gleich mit
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event, onTouch != nil else { return false }
        return isOnScreen(convert(event.locationInWindow, from: nil))
    }

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
        if let onTouch, !resizeRect.contains(point), !event.modifierFlags.contains(.command), isOnScreen(point) {
            // Berührung: bis zum Loslassen verfolgen (⌘-Ziehen verschiebt das Fenster)
            window?.makeFirstResponder(self)
            onTouch(.began, point)
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let location = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    onTouch(.ended, location)
                    break
                }
                onTouch(.moved, location)
            }
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

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let onScroll, isOnScreen(point) else {
            super.scrollWheel(with: event)
            return
        }
        onScroll(event, point)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let onMiddleClick, isOnScreen(convert(event.locationInWindow, from: nil)) else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick()
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKey?(event) != true { super.keyUp(with: event) }
    }

    /// ⌘V: Zwischenablage des Macs auf dem Gerät einfügen (nur, wenn es bedienbar ist)
    @objc func paste(_ sender: Any?) {
        onPaste?()
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(paste(_:)) { return onPaste != nil }
        return super.responds(to: selector)
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
