// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Aktionen des Spiegelfensters (Werkzeugleiste, Stil-Panel, Kontextmenü)
struct MirrorActions {
    var close: () -> Void
    var present: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var actualSize: () -> Void
    var lifeSize: () -> Void
    var pixelPerfect: () -> Void
    var fitToScreen: () -> Void
    var saveScreenshot: () -> Void
    var copyScreenshot: () -> Void
    var screenshotFile: () -> URL?
    var toggleRecording: () -> Void
    var disconnect: () -> Void
}

/// Sichtbarkeit der Werkzeuge
@MainActor
final class MirrorChrome: ObservableObject {
    @Published var hovering = false
    @Published var styleOpen = false
}

/// Senkrechte Werkzeugleiste rechts neben dem Gerät; erscheint, wenn die Maus über dem Fenster ist
struct MirrorToolRail: View {
    static let width: CGFloat = 66

    @ObservedObject var session: MirrorSession
    @ObservedObject var chrome: MirrorChrome
    @ObservedObject var settings = AppSettings.shared
    let actions: MirrorActions

    private var visible: Bool { chrome.hovering || chrome.styleOpen || settings.alwaysShowTools }

    var body: some View {
        VStack(spacing: 2) {
            RailButton(symbol: "xmark", title: String(localized: "Close"), small: true, action: actions.close)
                .padding(.bottom, 4)
                .railItem(visible)
            recordButton
            RailButton(symbol: "camera.fill", title: String(localized: "Photo"),
                       help: String(localized: "Click: screenshot to the Desktop · ⌥-click: copy · Drag: straight into an app"),
                       action: {
                           NSEvent.modifierFlags.contains(.option) ? actions.copyScreenshot() : actions.saveScreenshot()
                       })
                .onDrag { screenshotProvider() }
                .railItem(visible)
            RailButton(symbol: session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       title: session.muted ? String(localized: "Muted") : String(localized: "Sound")) {
                session.muted.toggle()
                settings.playAudio = !session.muted
            }
            .railItem(visible)
            RailButton(symbol: settings.alwaysOnTop ? "pin.fill" : "pin", title: String(localized: "On Top"),
                       help: String(localized: "Keep on top (⌘T)"), active: settings.alwaysOnTop) {
                settings.alwaysOnTop.toggle()
            }
            .railItem(visible)
            RailButton(symbol: "arrow.up.left.and.arrow.down.right", title: String(localized: "Full Screen"),
                       help: String(localized: "Present full screen (⌃⌘F, Esc to exit)"), action: actions.present)
                .railItem(visible)
            RailButton(symbol: "paintpalette.fill", title: String(localized: "Style"), active: chrome.styleOpen) {
                chrome.styleOpen.toggle()
            }
            .popover(isPresented: $chrome.styleOpen, arrowEdge: .trailing) {
                StylePanel(session: session, actions: actions)
            }
            .railItem(visible)
            if let url = session.lastExport {
                lastFileButton(url)
                    .padding(.top, 4)
                    .railItem(visible)
            }
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .opacity(visible ? 1 : 0)
        )
        .background(WindowDragArea().allowsHitTesting(visible))
        .animation(.easeOut(duration: 0.18), value: visible)
        .environment(\.colorScheme, .dark)
    }

    /// bleibt sichtbar, solange aufgenommen wird
    private var recordButton: some View {
        Group {
            if let start = session.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    RailButton(symbol: "stop.circle.fill", title: Self.elapsed(from: start, to: context.date),
                               help: String(localized: "Stop recording (⌘R)"), tint: .red, action: actions.toggleRecording)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                        .opacity(visible ? 0 : 1)
                )
            } else {
                RailButton(symbol: "record.circle", title: String(localized: "Record"), help: String(localized: "Record video (⌘R)"),
                           action: actions.toggleRecording)
                    .railItem(visible)
            }
        }
    }

    private func lastFileButton(_ url: URL) -> some View {
        RailButton(symbol: url.pathExtension == "mov" ? "film" : "photo", title: String(localized: "Latest"),
                   help: String(localized: "\(url.lastPathComponent) – drag to share, click to edit"), tint: .accentColor) {
            if let editable = session.lastEditable {
                AppModel.shared.openEditor(urls: [editable])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            if let editable = session.lastEditable {
                Button("Edit …") { AppModel.shared.openEditor(urls: [editable]) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func screenshotProvider() -> NSItemProvider {
        guard let url = actions.screenshotFile() else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

extension View {
    /// Werkzeug ein-/ausblenden; ausgeblendet nicht klickbar
    func railItem(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).allowsHitTesting(visible)
    }
}

/// Knopf mit Symbol und kurzer Beschriftung
struct RailButton: View {
    let symbol: String
    let title: String
    var help: String?
    var small = false
    var active = false
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    init(symbol: String, title: String, help: String? = nil, small: Bool = false, active: Bool = false,
         tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.help = help
        self.small = small
        self.active = active
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: small ? 11 : 17, weight: .medium))
                    .frame(height: small ? 14 : 20)
                if !small {
                    Text(title)
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(tint ?? (active ? Color.accentColor : Color.primary))
            .frame(width: small ? 26 : 54, height: small ? 26 : 48)
            .background(
                RoundedRectangle(cornerRadius: small ? 13 : 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.14 : (active ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? title)
    }
}

/// Stil-Panel: alles zur Darstellung mit einem Klick
struct StylePanel: View {
    @ObservedObject var session: MirrorSession
    @ObservedObject var settings = AppSettings.shared
    let actions: MirrorActions
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            group(String(localized: "Size")) {
                HStack(spacing: 6) {
                    tile(String(localized: "Life-\nsize"), symbol: "ruler", action: actions.lifeSize)
                    tile(String(localized: "Pixel-\nperfect"), symbol: "square.grid.3x3", action: actions.pixelPerfect)
                    tile(String(localized: "Point-\nperfect"), symbol: "iphone", action: actions.actualSize)
                    tile(String(localized: "Fit to\nscreen"), symbol: "arrow.up.and.down", action: actions.fitToScreen)
                }
            }
            group(String(localized: "Device")) {
                Picker("", selection: $settings.showFrame) {
                    Text("With frame").tag(true)
                    Text("Screen only").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    ForEach(BezelColor.allCases) { color in
                        Button { settings.style.bezelColor = color } label: {
                            Circle()
                                .fill(Color(nsColor: color.swatch))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                                .padding(2)
                                .overlay(Circle().strokeBorder(Color.accentColor,
                                                               lineWidth: settings.style.bezelColor == color ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(color.title)
                    }
                }
                .opacity(settings.showFrame ? 1 : 0.35)
                .disabled(!settings.showFrame)
            }
            group(String(localized: "Background for photos, videos and full screen")) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6), spacing: 6) {
                    backgroundTile(selected: settings.style.background == .transparent, help: String(localized: "Transparent")) {
                        Checkerboard()
                    } action: { setBackground(.transparent) }
                    ForEach(GradientPreset.allCases) { preset in
                        backgroundTile(selected: settings.style.background == .gradient && settings.style.gradient == preset,
                                       help: preset.title) {
                            LinearGradient(colors: [Color(nsColor: preset.colors.0.nsColor), Color(nsColor: preset.colors.1.nsColor)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        } action: {
                            settings.style.gradient = preset
                            setBackground(.gradient)
                        }
                    }
                    backgroundTile(selected: settings.style.background == .color, help: String(localized: "Color")) {
                        Color(nsColor: settings.style.color.nsColor)
                    } action: { setBackground(.color) }
                    backgroundTile(selected: settings.style.background == .image, help: String(localized: "Custom image")) {
                        Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.secondary)
                    } action: { setBackground(.image) }
                }
                if settings.style.background == .color {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: settings.style.color.nsColor) },
                        set: { settings.style.color = RGBA(NSColor($0)) }), supportsOpacity: false)
                }
                HStack {
                    Text("Padding").frame(width: 62, alignment: .leading)
                    Slider(value: $settings.style.padding, in: 0...0.5)
                }
                HStack {
                    Toggle("Shadow", isOn: $settings.style.shadow)
                    Spacer()
                    Text("Aspect ratio")
                    Picker("Aspect ratio", selection: $settings.style.aspect) {
                        ForEach(CanvasAspect.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Divider()
            HStack {
                Toggle("Always show tools", isOn: $settings.alwaysShowTools)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("All Settings …") {
                    UserDefaults.standard.set("design", forKey: "settingsTab")
                    openSettings()
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: session.profile.family == .iPad ? "ipad" : "iphone")
                .font(.system(size: 24, weight: .light))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.deviceName).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: session.kind == .cable ? "cable.connector" : "wifi")
                        .font(.system(size: 9, weight: .semibold))
                    Text(session.subtitle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.kind == .wireless {
                Button("Disconnect", action: actions.disconnect)
                    .controlSize(.small)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func tile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title)
                    .font(.system(size: 9.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func backgroundTile<Content: View>(selected: Bool, help: String, @ViewBuilder content: () -> Content,
                                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// beim Wechsel weg von «Transparent» Abstand und Schatten vorbelegen
    private func setBackground(_ kind: BackgroundKind) {
        var style = settings.style
        if style.background == .transparent, kind != .transparent, style.padding == 0 {
            style.padding = 0.12
            style.shadow = true
        }
        if kind == .image, style.imagePath == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = String(localized: "Choose background image")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let target = AppSettings.shared.supportDirectory
                .appendingPathComponent("Hintergrund-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
            style.imagePath = (try? FileManager.default.copyItem(at: url, to: target)) != nil ? target.path : url.path
        }
        style.background = kind
        settings.style = style
    }
}

/// kurze Hinweise unten auf dem Gerät ("gesichert" …); lässt Klicks durch
struct MirrorHUD: View {
    @ObservedObject var session: MirrorSession

    var body: some View {
        VStack {
            Spacer()
            if let toast = session.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: session.toast)
    }
}

/// NSHostingView, die keine Klicks abfängt
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Fläche, mit der sich das randlose Fenster verschieben lässt
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
