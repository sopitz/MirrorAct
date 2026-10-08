// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI

/// Randloses, transparentes Fenster in Form des Geräts
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Spiegelfenster: nur das Gerät; rechts daneben eine Werkzeugleiste, die beim Überfahren
/// mit der Maus erscheint. Alle Funktionen zusätzlich per Rechtsklick und Tastenkürzel.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    static let railGap: CGFloat = 10

    let session: MirrorSession
    private let chrome = MirrorChrome()
    private let container = ContainerView()
    private let frameView = DeviceFrameView(frame: .zero)
    private var railView: NSHostingView<MirrorToolRail>!
    private var hudView: PassthroughHostingView<MirrorHUD>!
    private var settings: AppSettings { .shared }
    private var cancellables: Set<AnyCancellable> = []
    private var zoom: CGFloat = 1
    private var placed = false
    private var resizeStartZoom: CGFloat = 1
    private var presentation: PresentationWindow?
    private var hideTask: Task<Void, Never>?
    private(set) var actions: MirrorActions!

    init(session: MirrorSession) {
        self.session = session
        let window = MirrorWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
                                  styleMask: [.borderless, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        window.title = session.deviceName
        super.init(window: window)
        window.delegate = self

        actions = MirrorActions(
            close: { [weak self] in self?.close() },
            present: { [weak self] in self?.togglePresentation() },
            zoomIn: { [weak self] in self?.zoomIn() },
            zoomOut: { [weak self] in self?.zoomOut() },
            actualSize: { [weak self] in self?.actualSize() },
            lifeSize: { [weak self] in self?.lifeSize() },
            pixelPerfect: { [weak self] in self?.pixelPerfect() },
            fitToScreen: { [weak self] in self?.fitToScreen() },
            saveScreenshot: { [weak self] in self?.session.saveScreenshot(withFrame: AppSettings.shared.showFrame) },
            copyScreenshot: { [weak self] in self?.session.copyScreenshot(withFrame: AppSettings.shared.showFrame) },
            screenshotFile: { [weak self] in self?.session.screenshotFileForDragging(withFrame: AppSettings.shared.showFrame) },
            toggleRecording: { [weak self] in self?.session.toggleRecording() },
            disconnect: { AppModel.shared.disconnectWireless() },
            toggleControl: { [weak self] in self?.toggleControl() },
            press: { [weak self] button in self?.session.control?.press(button) })

        railView = NSHostingView(rootView: MirrorToolRail(session: session, chrome: chrome, actions: actions))
        hudView = PassthroughHostingView(rootView: MirrorHUD(session: session))
        container.addSubview(frameView)
        container.addSubview(hudView)
        container.addSubview(railView)
        container.onLayout = { [weak self] in self?.layoutSubviews() }
        container.onHover = { [weak self] inside in self?.setHovering(inside) }
        window.contentView = container

        frameView.onResizeDrag = { [weak self] phase, delta in self?.handleResizeDrag(phase, delta) }
        frameView.onMagnify = { [weak self] amount in self?.setZoom((self?.zoom ?? 1) * (1 + amount)) }
        frameView.onDragOut = { [weak self] event in self?.dragScreenshot(with: event) }
        frameView.menuProvider = { [weak self] in self?.contextMenu() }
        frameView.bezelColor = settings.style.bezelColor
        session.sink.attach(frameView.videoView.displayLayer)

        session.$frameSize.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }.store(in: &cancellables)
        session.$profile.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }.store(in: &cancellables)
        session.$state.sink { [weak self] state in
            DispatchQueue.main.async { self?.updatePlaceholder(state) }
        }.store(in: &cancellables)
        session.$deviceName.sink { [weak window] name in window?.title = name }.store(in: &cancellables)
        session.$controlState.removeDuplicates().sink { [weak self] state in
            DispatchQueue.main.async { self?.controlStateChanged(state) }
        }.store(in: &cancellables)
        session.$lastExport.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutSubviews() }
        }.store(in: &cancellables)
        settings.$showFrame.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLayout() }
        }.store(in: &cancellables)
        settings.$style.map(\.bezelColor).removeDuplicates().sink { [weak self] color in
            self?.frameView.bezelColor = color
        }.store(in: &cancellables)
        settings.$style.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPresentationBackground() }
        }.store(in: &cancellables)
        settings.$alwaysOnTop.sink { [weak window] onTop in
            window?.level = onTop ? .floating : .normal
        }.store(in: &cancellables)
        chrome.$styleOpen.dropFirst().sink { [weak self] open in
            if !open { self?.scheduleHide() }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        if !placed {
            zoom = fittingZoom(maxZoom: 1)
            applyLayout()
            window?.center()
            placed = true
        }
        window?.makeKeyAndOrderFront(nil)
        if frameView.acceptsFirstResponder { window?.makeFirstResponder(frameView) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if presentation != nil { exitPresentation(reshow: false) }
        chrome.styleOpen = false
        session.control?.stop()
        session.stopRecording()
        session.sink.attach(nil)
        session.onClose?()
        AppModel.shared.windowClosed(self)
    }

    func showStylePanel() {
        chrome.hovering = true
        chrome.styleOpen = true
    }

    // MARK: Werkzeuge ein-/ausblenden

    private func setHovering(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            chrome.hovering = true
        } else {
            scheduleHide()
        }
    }

    /// verzögert, damit die Leiste beim Wechsel vom Gerät zur Leiste nicht flackert
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.chrome.styleOpen || self.container.mouseInside { return }
            self.chrome.hovering = false
        }
    }

    // MARK: Kontextmenü

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let a = actions!
        menu.addItem(ActionMenuItem(session.isRecording ? String(localized: "Stop Recording") : String(localized: "Start Recording"), key: "r", a.toggleRecording))
        menu.addItem(ActionMenuItem(String(localized: "Save Screenshot to Desktop"), key: "s", a.saveScreenshot))
        menu.addItem(ActionMenuItem(String(localized: "Copy Screenshot"), a.copyScreenshot))
        menu.addItem(.separator())
        if let control = session.control {
            if session.isControlReady {
                for button in control.buttons {
                    let item = ActionMenuItem(button.title) { a.press(button) }
                    item.image = NSImage(systemSymbolName: button.symbol, accessibilityDescription: nil)
                    menu.addItem(item)
                }
            }
            if control.startsOnDemand {
                let item = ActionMenuItem(String(localized: "Control Device"), state: session.controlState == .ready
                                          || session.controlState == .starting, a.toggleControl)
                item.keyEquivalent = "c"
                item.keyEquivalentModifierMask = [.command, .option]
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem(String(localized: "Sound"), state: !session.muted) { [weak self] in
            guard let self else { return }
            self.session.muted.toggle()
            self.settings.playAudio = !self.session.muted
        })
        menu.addItem(ActionMenuItem(String(localized: "Keep on Top"), key: "t", state: settings.alwaysOnTop) { [weak self] in
            self?.settings.alwaysOnTop.toggle()
        })
        menu.addItem(ActionMenuItem(String(localized: "Present"), a.present))
        menu.addItem(.separator())

        let size = NSMenu()
        size.addItem(ActionMenuItem(String(localized: "Life-Size"), key: "1", a.lifeSize))
        size.addItem(ActionMenuItem(String(localized: "Pixel-Perfect"), key: "2", a.pixelPerfect))
        size.addItem(ActionMenuItem(String(localized: "Point-Perfect"), key: "0", a.actualSize))
        size.addItem(ActionMenuItem(String(localized: "Fit to Screen"), key: "9", a.fitToScreen))
        size.addItem(.separator())
        size.addItem(ActionMenuItem(String(localized: "Larger"), key: "+", a.zoomIn))
        size.addItem(ActionMenuItem(String(localized: "Smaller"), key: "-", a.zoomOut))
        menu.addItem(ActionMenuItem.submenu(String(localized: "Size"), size))

        menu.addItem(ActionMenuItem(String(localized: "Device Frame"), state: settings.showFrame) { [weak self] in
            self?.settings.showFrame.toggle()
        })
        let colors = NSMenu()
        for color in BezelColor.allCases {
            let item = ActionMenuItem(color.title, state: settings.style.bezelColor == color) { [weak self] in
                self?.settings.style.bezelColor = color
            }
            item.image = StyleControls.swatch(color.swatch)
            colors.addItem(item)
        }
        menu.addItem(ActionMenuItem.submenu(String(localized: "Frame Color"), colors))
        menu.addItem(ActionMenuItem(String(localized: "Style …")) { [weak self] in self?.showStylePanel() })
        if let editable = session.lastEditable {
            menu.addItem(ActionMenuItem(String(localized: "Edit Last File …")) { AppModel.shared.openEditor(urls: [editable]) })
        }
        menu.addItem(.separator())
        if session.kind == .wireless {
            menu.addItem(ActionMenuItem(String(localized: "Disconnect Device"), a.disconnect))
        }
        menu.addItem(ActionMenuItem(String(localized: "Close Window"), key: "w", a.close))
        return menu
    }

    // MARK: Grösse

    private func layout(for zoom: CGFloat) -> FrameLayout {
        let screen = session.screenPointSize
        return FrameLayout(profile: session.profile,
                           screenSize: CGSize(width: (screen.width * zoom).rounded(),
                                              height: (screen.height * zoom).rounded()),
                           showFrame: settings.showFrame)
    }

    private var railSize: CGSize {
        let fitting = railView.fittingSize
        return CGSize(width: MirrorToolRail.width, height: max(fitting.height, 100))
    }

    private func contentSize(for layout: FrameLayout) -> CGSize {
        CGSize(width: (layout.totalSize.width + Self.railGap + MirrorToolRail.width).rounded(.up),
               height: max(layout.totalSize.height, railSize.height).rounded(.up))
    }

    private func fittingZoom(maxZoom: CGFloat) -> CGFloat {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let unit = layout(for: 1).totalSize
        let availableHeight = visible.height * 0.92
        let availableWidth = visible.width * 0.92 - Self.railGap - MirrorToolRail.width
        let fit = min(availableHeight / max(1, unit.height), availableWidth / max(1, unit.width))
        return max(0.25, min(maxZoom, fit))
    }

    func setZoom(_ value: CGFloat) {
        zoom = max(0.25, min(3, value))
        applyLayout()
    }

    func zoomIn() { setZoom(zoom * 1.15) }
    func zoomOut() { setZoom(zoom / 1.15) }
    func actualSize() { setZoom(1) }
    func fitToScreen() { setZoom(fittingZoom(maxZoom: 3)) }

    /// 1 Pixel des Geräts = 1 Pixel des Monitors
    func pixelPerfect() {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let points = session.screenPointSize
        let pixelWidth = session.frameSize == .zero
            ? (session.profile.nativePixelWidth ?? min(points.width, points.height) * 3)
            : min(session.frameSize.width, session.frameSize.height)
        setZoom(pixelWidth / backing / max(1, min(points.width, points.height)))
    }

    /// so gross wie das echte Gerät (nach Pixeldichte des Monitors)
    func lifeSize() {
        guard let screen = window?.screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        let millimeters = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        guard millimeters.width > 0, let deviceMM = session.profile.physicalWidthMM else {
            NSSound.beep()
            session.showToast(String(localized: "Life-size: size of the display or device unknown"))
            return
        }
        let pointsPerMM = screen.frame.width / millimeters.width
        let points = session.screenPointSize
        setZoom(deviceMM * pointsPerMM / max(1, min(points.width, points.height)))
    }

    private func handleResizeDrag(_ phase: NSEvent.Phase, _ delta: CGSize) {
        if phase == .began {
            resizeStartZoom = zoom
            return
        }
        let unit = layout(for: 1).totalSize
        let byHeight = (unit.height * resizeStartZoom + delta.height) / max(1, unit.height)
        let byWidth = (unit.width * resizeStartZoom + delta.width) / max(1, unit.width)
        setZoom(max(byHeight, byWidth))
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // native Grössenänderung: Seitenverhältnis des Geräts halten
        let unit = layout(for: 1).totalSize
        let proposed = (frameSize.width - Self.railGap - MirrorToolRail.width) / max(1, unit.width)
        zoom = max(0.25, min(3, proposed))
        return contentSize(for: layout(for: zoom))
    }

    func windowDidResize(_ notification: Notification) {
        container.needsLayout = true
    }

    private func applyLayout() {
        if presentation != nil {
            layoutPresentation()
            return
        }
        guard let window else { return }
        let model = layout(for: zoom)
        frameView.layoutModel = model
        let size = contentSize(for: model)
        // obere linke Ecke bleibt stehen
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
                           width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: false)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        window.invalidateShadow()
    }

    private func layoutSubviews() {
        guard presentation == nil else { return }
        let bounds = container.bounds
        let device = frameView.layoutModel?.totalSize ?? .zero
        frameView.frame = CGRect(x: 0, y: ((bounds.height - device.height) / 2).rounded(),
                                 width: device.width, height: device.height)
        let rail = railSize
        railView.frame = CGRect(x: device.width + Self.railGap, y: ((bounds.height - rail.height) / 2).rounded(),
                                width: rail.width, height: rail.height)
        if let screen = frameView.layoutModel?.screenRect {
            let rect = screen.offsetBy(dx: frameView.frame.minX, dy: frameView.frame.minY)
            hudView.frame = CGRect(x: rect.minX, y: rect.maxY - 70, width: rect.width, height: 70)
        }
        container.refreshTrackingArea()
        DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
    }

    // MARK: Präsentation

    func togglePresentation() {
        presentation == nil ? enterPresentation() : exitPresentation(reshow: true)
    }

    private func enterPresentation() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        chrome.styleOpen = false
        let presentation = PresentationWindow(screen: screen)
        presentation.onExit = { [weak self] in self?.exitPresentation(reshow: true) }
        self.presentation = presentation
        frameView.removeFromSuperview()
        presentation.content.addSubview(frameView)
        presentation.content.frame = CGRect(origin: .zero, size: screen.frame.size)
        presentation.content.setBackground(style: settings.style, scale: screen.backingScaleFactor)
        window?.orderOut(nil)
        presentation.makeKeyAndOrderFront(nil)
        if frameView.acceptsFirstResponder { presentation.makeFirstResponder(frameView) }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.setHiddenUntilMouseMoves(true)
        layoutPresentation()
    }

    private func exitPresentation(reshow: Bool) {
        guard let presentation else { return }
        self.presentation = nil
        frameView.layer?.shadowOpacity = 0
        frameView.removeFromSuperview()
        container.addSubview(frameView, positioned: .below, relativeTo: hudView)
        presentation.orderOut(nil)
        NSApp.presentationOptions = []
        applyLayout()
        if reshow {
            window?.makeKeyAndOrderFront(nil)
            if frameView.acceptsFirstResponder { window?.makeFirstResponder(frameView) }
        }
    }

    private func layoutPresentation() {
        guard let presentation else { return }
        let bounds = presentation.content.bounds
        let unit = layout(for: 1).totalSize
        let fit = min(bounds.height * 0.9 / max(1, unit.height), bounds.width * 0.9 / max(1, unit.width))
        let model = layout(for: fit)
        frameView.layoutModel = model
        frameView.frame = CGRect(x: ((bounds.width - model.totalSize.width) / 2).rounded(),
                                 y: ((bounds.height - model.totalSize.height) / 2).rounded(),
                                 width: model.totalSize.width, height: model.totalSize.height)
        applyPresentationShadow()
    }

    private func applyPresentationShadow() {
        guard let layer = frameView.layer else { return }
        let on = settings.style.shadow
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = on ? 0.45 : 0
        layer.shadowRadius = on ? 30 : 0
        layer.shadowOffset = CGSize(width: 0, height: -12)
        // fester Umriss: sonst berechnet Core Animation den Schatten bei jedem Videobild neu
        layer.shadowPath = on ? frameView.layoutModel?.silhouettePath : nil
    }

    private func refreshPresentationBackground() {
        guard let presentation else { return }
        presentation.content.setBackground(style: settings.style,
                                           scale: presentation.screen?.backingScaleFactor ?? 2)
        applyPresentationShadow()
    }

    // MARK: Bedienen

    /// Bedienung ein-/ausschalten (iPhone: Agent auf dem Gerät starten)
    func toggleControl() {
        guard let control = session.control else {
            NSSound.beep()
            return
        }
        switch session.controlState {
        case .ready, .starting: control.stop()
        default: control.start()
        }
    }

    private func controlStateChanged(_ state: ControlState?) {
        let ready = state == .ready
        frameView.onTouch = ready ? { [weak self] phase, point in
            guard let self, let target = self.devicePoint(point) else { return }
            self.session.control?.touch(phase, at: target)
        } : nil
        frameView.onScroll = ready ? { [weak self] event, point in
            guard let self, let target = self.devicePoint(point) else { return }
            self.session.control?.scroll(at: target, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                         precise: event.hasPreciseScrollingDeltas)
        } : nil
        frameView.onMiddleClick = ready ? { [weak self] in self?.session.control?.press(.home) } : nil
        frameView.onKey = ready ? { [weak self] event in
            guard let self else { return false }
            if self.presentation != nil, event.keyCode == 53 {   // Esc beendet die Präsentation
                if event.type == .keyDown { self.exitPresentation(reshow: true) }
                return true
            }
            return self.session.control?.key(event) ?? false
        } : nil
        frameView.onPaste = ready ? { [weak self] in
            guard let text = NSPasteboard.general.string(forType: .string) else {
                NSSound.beep()
                return
            }
            self?.session.control?.paste(text)
        } : nil
        if ready, let window = presentation ?? window, window.isKeyWindow {
            window.makeFirstResponder(frameView)
        }
        if case let .failed(message) = state {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(session.deviceName) can’t be controlled")
            alert.informativeText = message
            alert.runModal()
        }
    }

    /// Punkt im Gerätebild → Bildschirmkoordinaten 0…1 (das Video füllt den Bildschirm, «aspect fill»)
    private func devicePoint(_ point: CGPoint) -> CGPoint? {
        guard let screen = frameView.layoutModel?.screenRect, screen.width > 0, screen.height > 0 else { return nil }
        let video = session.frameSize == .zero ? screen.size : session.frameSize
        let scale = max(screen.width / video.width, screen.height / video.height)
        let shown = CGSize(width: video.width * scale, height: video.height * scale)
        let x = (point.x - screen.midX + shown.width / 2) / shown.width
        let y = (point.y - screen.midY + shown.height / 2) / shown.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: Drag & Drop

    private func dragScreenshot(with event: NSEvent) {
        guard let url = session.screenshotFileForDragging(withFrame: settings.showFrame),
              let image = NSImage(contentsOf: url) else {
            NSSound.beep()
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = frameView.bounds.size
        let fitted = NSSize(width: size.width * 0.5,
                            height: size.width * 0.5 * image.size.height / max(1, image.size.width))
        let origin = frameView.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - fitted.width / 2, y: origin.y - fitted.height / 2,
                                     width: fitted.width, height: fitted.height), contents: image)
        frameView.beginDraggingSession(with: [item], event: event, source: frameView)
    }

    private func updatePlaceholder(_ state: MirrorSession.State) {
        switch state {
        case .live:
            frameView.placeholder.isHidden = true
        case .connecting:
            frameView.placeholder.isHidden = false
            frameView.placeholder.stringValue = session.kind == .cable
                ? String(localized: "Connecting …\nUnlock the device if needed")
                : String(localized: "Waiting for video …")
        case let .disconnected(reason):
            frameView.placeholder.isHidden = false
            frameView.placeholder.stringValue = reason ?? String(localized: "Disconnected")
        }
    }
}

/// Inhalt des Fensters (geflippt, transparent); meldet, ob die Maus darüber ist
private final class ContainerView: NSView {
    var onLayout: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private(set) var mouseInside = false

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    func refreshTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        onHover?(false)
    }
}

/// Menüeintrag mit Closure
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", state on: Bool? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if let on { state = on ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
