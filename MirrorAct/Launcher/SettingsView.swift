// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
                .tag("general")
            DesignSettingsView()
                .tabItem { Label("Gestaltung", systemImage: "paintpalette") }
                .tag("design")
        }
        .frame(width: 500)
    }
}

// MARK: Allgemein

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = AppModel.shared
    @State private var name = AppSettings.shared.receiverName
    @State private var pin = AppSettings.shared.pin
    @State private var height = AppSettings.shared.streamHeight
    @State private var fps = AppSettings.shared.maxFPS
    @State private var hevc = AppSettings.shared.hevc
    @State private var peerToPeer = AppSettings.shared.peerToPeer

    private var changed: Bool {
        name != settings.receiverName || pin != settings.pin || height != settings.streamHeight
            || fps != settings.maxFPS || hevc != settings.hevc || peerToPeer != settings.peerToPeer
    }

    private var pinValid: Bool { pin.count == 4 && pin.allSatisfy(\.isNumber) && pin != "0000" }

    var body: some View {
        Form {
            Section("Kabelloser Empfang (AirPlay)") {
                TextField("Name auf dem iPhone", text: $name)
                Toggle("Direktverbindung über Apple-Funk (AWDL)", isOn: $peerToPeer)
                Text("Nötig, wenn das iPhone den Mac im WLAN nicht findet. Verlangt beim ersten Verbinden einen Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Code (4 Ziffern)", text: $pin)
                    .disabled(!peerToPeer)
                Picker("Auflösung", selection: $height) {
                    Text("1080 Pixel Höhe").tag(1080)
                    Text("1440 Pixel Höhe").tag(1440)
                    Text("2160 Pixel Höhe").tag(2160)
                }
                Picker("Bildrate", selection: $fps) {
                    Text("30 Bilder/s").tag(30)
                    Text("60 Bilder/s").tag(60)
                }
                Toggle("HEVC erlauben (nötig über 1080)", isOn: $hevc)
                HStack {
                    Spacer()
                    Button("Übernehmen und neu starten") {
                        settings.receiverName = name.trimmingCharacters(in: .whitespaces)
                        settings.pin = pin
                        settings.streamHeight = height
                        settings.maxFPS = fps
                        settings.hevc = hevc
                        settings.peerToPeer = peerToPeer
                        model.restartReceiver()
                    }
                    .disabled(!changed || (peerToPeer && !pinValid) || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            Section("Fenster") {
                Toggle("Gerätrahmen anzeigen", isOn: $settings.showFrame)
                Toggle("Immer im Vordergrund", isOn: $settings.alwaysOnTop)
                Toggle("Ton wiedergeben", isOn: $settings.playAudio)
            }
            Section("Aufnahme") {
                Toggle("Mit Gerätrahmen aufnehmen", isOn: $settings.recordWithFrame)
                Text("Hintergrund, Abstand und Format kommen aus «Gestaltung». Bei transparentem Hintergrund entsteht HEVC mit Transparenz, sonst H.264. Ablage: Schreibtisch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Gestaltung

struct DesignSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                DesignPreview(style: settings.style, showFrame: settings.showFrame)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
            }
            StyleControls(style: $settings.style, showFrame: $settings.showFrame)
            Section {
                Text("Standard für Screenshots, Aufnahmen und die Präsentation (⌃⌘F). Im Spiegelfenster bleibt der Hintergrund weg. Im Editor (⌘E) lässt sich die Gestaltung pro Datei ändern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Vorschau mit dem aktuellen Bild des Spiegelfensters (sonst Testbild), auf Schachbrett für Transparenz
struct DesignPreview: View {
    let style: FrameStyle
    let showFrame: Bool

    var body: some View {
        ZStack {
            Checkerboard()
            if let image = render() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func render() -> CGImage? {
        let session = MainActor.assumeIsolated { AppModel.shared.keyMirror?.session }
        var screen: CGImage?
        var profile = DeviceProfile.forModelIdentifier("iPhone14,2")!
        if let session, let buffer = session.sink.latest {
            screen = FrameRenderer.cgImage(from: buffer)
            profile = MainActor.assumeIsolated { session.profile }
        }
        guard let full = screen ?? RenderTest.testScreen(size: CGSize(width: 1170, height: 2532)) else { return nil }
        // verkleinert rendern, damit die Vorschau flüssig bleibt
        let scale = min(1, 520 / CGFloat(max(full.width, full.height)))
        let small = Self.scaled(full, by: scale) ?? full
        return FrameRenderer.render(screen: small, profile: profile, showFrame: showFrame, style: style)
    }

    private static func scaled(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
