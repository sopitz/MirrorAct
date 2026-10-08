// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Bedienelemente für die Gestaltung (Einstellungen und Editor)
struct StyleControls: View {
    @Binding var style: FrameStyle
    @Binding var showFrame: Bool

    var body: some View {
        Section("Device") {
            Toggle("Show device frame", isOn: $showFrame)
            Picker("Frame color", selection: $style.bezelColor) {
                ForEach(BezelColor.allCases) { color in
                    Label {
                        Text(color.title)
                    } icon: {
                        Image(nsImage: Self.swatch(color.swatch))
                    }
                    .tag(color)
                }
            }
            .disabled(!showFrame)
            Toggle("Without frame: round corners like the device", isOn: $style.roundedScreen)
                .disabled(showFrame)
        }
        Section("Background") {
            Picker("Background", selection: backgroundSelection) {
                ForEach(BackgroundKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch style.background {
            case .transparent:
                EmptyView()
            case .color:
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
            case .gradient:
                Picker("Gradient", selection: $style.gradient) {
                    ForEach(GradientPreset.allCases) { Text($0.title).tag($0) }
                }
            case .image:
                HStack {
                    Text(style.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "No image chosen"))
                        .foregroundStyle(style.imagePath == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose Image …", action: chooseImage)
                }
            }
            LabeledContent("Padding") {
                Slider(value: $style.padding, in: 0...0.5)
            }
            Toggle("Shadow", isOn: $style.shadow)
            Picker("Aspect ratio", selection: $style.aspect) {
                ForEach(CanvasAspect.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    /// beim Wechsel weg von «Transparent» Abstand und Schatten vorbelegen
    private var backgroundSelection: Binding<BackgroundKind> {
        Binding(get: { style.background }, set: { kind in
            var updated = style
            if updated.background == .transparent, kind != .transparent, updated.padding == 0 {
                updated.padding = 0.12
                updated.shadow = true
            }
            updated.background = kind
            style = updated
            if kind == .image, updated.imagePath == nil { chooseImage() }
        })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: style.color.nsColor) },
                set: { style.color = RGBA(NSColor($0)) })
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose background image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Kopie im App-Ordner, damit das Bild auch nach Verschieben des Originals bleibt
        let target = AppSettings.shared.supportDirectory
            .appendingPathComponent("Hintergrund-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        let path = (try? FileManager.default.copyItem(at: url, to: target)) != nil ? target.path : url.path
        style.imagePath = path
        style.background = .image
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}

/// Schachbrett hinter transparenten Vorschauen
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color.gray.opacity(0.18)))
                }
            }
        }
    }
}
