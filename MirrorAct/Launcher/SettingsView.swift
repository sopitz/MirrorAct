// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            DesignSettingsView()
                .tabItem { Label("Style", systemImage: "paintpalette") }
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

    @State private var language = AppSettings.shared.appLanguage
    @State private var languageChanged = false

    private var languageSelection: Binding<String> {
        Binding(get: { language }, set: { value in
            language = value
            settings.appLanguage = value
            languageChanged = true
        })
    }

    private var pinValid: Bool { pin.count == 4 && pin.allSatisfy(\.isNumber) && pin != "0000" }

    var body: some View {
        Form {
            Section("Wireless receiver (AirPlay)") {
                TextField("Name on the iPhone", text: $name)
                Toggle("Direct connection over Apple Wireless (AWDL)", isOn: $peerToPeer)
                Text("Needed when the iPhone does not find the Mac on Wi-Fi. Asks for a code on first connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Code (4 digits)", text: $pin)
                    .disabled(!peerToPeer)
                Picker("Resolution", selection: $height) {
                    Text("1080 pixels high").tag(1080)
                    Text("1440 pixels high").tag(1440)
                    Text("2160 pixels high").tag(2160)
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Allow HEVC (needed above 1080)", isOn: $hevc)
                HStack {
                    Spacer()
                    Button("Apply and restart") {
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
            Section("Language") {
                Picker("Language", selection: languageSelection) {
                    Text("System language").tag("system")
                    ForEach(AppSettings.languages, id: \.id) { language in
                        Text(verbatim: language.name).tag(language.id)
                    }
                }
                if languageChanged {
                    HStack {
                        Text("Takes effect after a restart.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppSettings.relaunch() }
                    }
                }
            }
            Section("Window") {
                Toggle("Show device frame", isOn: $settings.showFrame)
                Toggle("Keep on top", isOn: $settings.alwaysOnTop)
                Toggle("Play sound", isOn: $settings.playAudio)
            }
            Section("Recording") {
                Toggle("Record with device frame", isOn: $settings.recordWithFrame)
                Text("Background, padding and aspect ratio come from “Style”. A transparent background produces HEVC with transparency, otherwise H.264. Saved to the Desktop.")
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
                Text("Default for screenshots, recordings and presenting (⌃⌘F). The mirror window shows no background. In the editor (⌘E) you can change the style per file.")
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
