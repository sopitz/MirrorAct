// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Startfenster: Gerätegalerie mit Karten, Karte «Kabellos» mit Code, Karte «Gerät verbinden» (Anleitung)
struct LauncherView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var usb = AppModel.shared.usb
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings
    @State private var showGuide = false
    @State private var wirelessHint: DeviceCard.Model?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 18)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(cards) { card in
                        DeviceCard(model: card) { open(card) }
                    }
                    WirelessCard(receiverName: settings.receiverName, pin: settings.pin,
                                 usesPin: settings.peerToPeer, state: model.receiverState) {
                        model.restartReceiver()
                    }
                    AddDeviceCard { showGuide = true }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .frame(width: 760, height: 520)
        .background(background)
        .sheet(isPresented: $showGuide) { ConnectGuide() }
        .alert(item: $wirelessHint) { card in
            Alert(title: Text("Mirror \(card.name) wirelessly"),
                  message: Text(String(localized: "On the device: Control Center → Screen Mirroring → “\(settings.receiverName)”.")
                      + (settings.peerToPeer ? "\n\n" + String(localized: "Code on first connection: \(settings.pin)") : "")),
                  dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("MirrorAct")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.openEditorPanel()
            } label: {
                Label("Edit …", systemImage: "wand.and.stars")
            }
            .help("Frame screenshots (also two as a duo) or videos (⌘E)")
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
        }
        .controlSize(.large)
    }

    private var statusLine: String {
        let connected = usb.devices.count
        let wireless = model.activeWirelessClient != nil
        switch (connected, wireless) {
        case (0, false): return String(localized: "Connect a device by cable or wirelessly")
        case (0, true): return String(localized: "Mirroring wirelessly")
        case (1, _): return wireless ? String(localized: "1 device via cable · mirroring wirelessly") : String(localized: "1 device via cable – click to mirror")
        default: return String(localized: "\(connected) devices via cable") + (wireless ? String(localized: " · mirroring wirelessly") : "")
        }
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color(red: 0.08, green: 0.52, blue: 0.50).opacity(0.16), .clear],
                           startPoint: .topLeading, endPoint: .center)
        }
    }

    // MARK: Karten

    private var cards: [DeviceCard.Model] {
        var result: [DeviceCard.Model] = []
        let connected = Set(usb.devices.map(\.id))
        for device in usb.devices {
            let mirroring = model.isMirroring(cableDevice: device.id)
            result.append(.init(id: "cable:\(device.id)", name: device.name,
                                modelIdentifier: settings.modelIdentifier(forDeviceNamed: device.name),
                                status: mirroring ? String(localized: "Mirroring") : String(localized: "Ready via cable"),
                                state: mirroring ? .mirroring : .ready, transport: .cable, cableDevice: device))
        }
        for known in settings.knownDevices {
            switch known.transport {
            case .cable:
                guard !connected.contains(known.key) else { continue }
                result.append(.init(id: known.id, name: known.name, modelIdentifier: known.modelIdentifier,
                                    status: String(localized: "Cable not connected"), state: .offline, transport: .cable,
                                    cableDevice: nil))
            case .wireless:
                let live = model.activeWirelessClient?.deviceID == known.key
                result.append(.init(id: known.id, name: known.name, modelIdentifier: known.modelIdentifier,
                                    status: live ? String(localized: "Mirroring wirelessly") : String(localized: "Wireless"),
                                    state: live ? .mirroring : .offline, transport: .wireless, cableDevice: nil))
            }
        }
        return result
    }

    private func open(_ card: DeviceCard.Model) {
        if let device = card.cableDevice {
            model.openCableDevice(device)
        } else if card.transport == .wireless {
            wirelessHint = card
        } else {
            showGuide = true
        }
    }
}

// MARK: - Gerätekarte

struct DeviceCard: View {
    struct Model: Identifiable {
        enum State { case ready, mirroring, offline }
        let id: String
        let name: String
        let modelIdentifier: String?
        let status: String
        let state: State
        let transport: AppSettings.KnownDevice.Transport
        let cableDevice: USBDeviceMonitor.Device?
    }

    let model: Model
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                DeviceThumbnail(modelIdentifier: model.modelIdentifier, seed: model.name,
                                dimmed: model.state == .offline)
                    .frame(height: 120)
                    .overlay(alignment: .bottom) {
                        if hovering, model.state != .offline {
                            Text(model.state == .mirroring ? String(localized: "Show") : String(localized: "Mirror"))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                                .offset(y: -8)
                        }
                    }
                VStack(spacing: 3) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: model.transport == .cable ? "cable.connector" : "wifi")
                            .font(.system(size: 9, weight: .bold))
                        Text(model.status)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(CardBackground(highlighted: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var statusColor: Color {
        switch model.state {
        case .ready: return .green
        case .mirroring: return .accentColor
        case .offline: return .secondary
        }
    }
}

/// kleines Gerätebild im passenden Rahmen (Notch, Dynamic Island …)
struct DeviceThumbnail: View {
    let modelIdentifier: String?
    let seed: String
    var dimmed = false

    var body: some View {
        if let image = Self.render(modelIdentifier: modelIdentifier, seed: seed) {
            Image(decorative: image, scale: 2)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .opacity(dimmed ? 0.45 : 1)
                .saturation(dimmed ? 0.2 : 1)
        }
    }

    private static var cache: [String: CGImage] = [:]

    private static func render(modelIdentifier: String?, seed: String) -> CGImage? {
        let key = "\(modelIdentifier ?? "-")|\(seed)"
        if let cached = cache[key] { return cached }
        let profile = modelIdentifier.flatMap(DeviceProfile.forModelIdentifier)
            ?? DeviceProfile.forScreenPixels(CGSize(width: 1170, height: 2532))!
        let size = profile.family == .iPad ? CGSize(width: 240, height: 330) : CGSize(width: 150, height: 325)
        guard let screen = wallpaper(size: size, seed: seed),
              let image = FrameRenderer.render(screen: screen, profile: profile, showFrame: true,
                                               style: FrameStyle(bezelColor: .graphite)) else { return nil }
        cache[key] = image
        return image
    }

    /// ruhiger Verlauf als Platzhalter-Bildschirm, Farbe aus dem Gerätenamen
    private static func wallpaper(size: CGSize, seed: String) -> CGImage? {
        // stabil über Neustarts (hashValue ist pro Prozess zufällig)
        let hue = Double(seed.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let a = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let b = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.45, alpha: 1)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        return ctx.makeImage()
    }
}

// MARK: - Kabellos

struct WirelessCard: View {
    let receiverName: String
    let pin: String
    let usesPin: Bool
    let state: AppModel.ReceiverState
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .semibold))
                Text("Wireless")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(state == .ready ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
            }
            if state == .ready {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose in Control Center:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("“\(receiverName)”")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                if usesPin {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CODE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(pin.map(String.init).joined(separator: " "))
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    }
                }
            } else {
                Text(state == .stopped ? String(localized: "Wireless receiver off") : String(localized: "Receiver failed – see the log"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Restart", action: restart)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(CardBackground(highlighted: false))
    }
}

// MARK: - Gerät verbinden

struct AddDeviceCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .light))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor.opacity(hovering ? 0.25 : 0.14)))
                Text("Connect a Device")
                    .font(.system(size: 13, weight: .semibold))
                Text("Cable or Wi-Fi – how it works")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.18),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct CardBackground: View {
    let highlighted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.primary.opacity(highlighted ? 0.09 : 0.05))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(highlighted ? 0.18 : 0.08), lineWidth: 0.5))
    }
}

/// Geführte Einrichtung: Kabel und WLAN, mit Tipps bei Problemen
struct ConnectGuide: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect a Device")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            HStack(alignment: .top, spacing: 18) {
                steps(title: String(localized: "Cable"), symbol: "cable.connector", items: [
                    String(localized: "Connect the iPhone or iPad to the Mac."),
                    String(localized: "Unlock the device and confirm “Trust This Computer”."),
                    String(localized: "The device appears in the start window – click it."),
                    String(localized: "The first time, allow camera access for MirrorAct."),
                ], note: String(localized: "Lowest latency. Other apps such as QuickTime must not have the device open at the same time."))
                steps(title: String(localized: "Wireless"), symbol: "wifi", items: [
                    String(localized: "Open Control Center on the device."),
                    String(localized: "Tap “Screen Mirroring”."),
                    String(localized: "Choose “\(settings.receiverName)”."),
                    settings.peerToPeer ? String(localized: "The first time, enter the code \(settings.pin).") : String(localized: "Done – no code needed."),
                ], note: String(localized: "If “\(settings.receiverName)” does not appear: turn on AirPlay Receiver in macOS under General → AirDrop & Handoff. Keep Wi-Fi and Bluetooth on the device turned on."))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func steps(title: String, symbol: String, items: [String], note: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.accentColor.opacity(0.18)))
                    Text(text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CardBackground(highlighted: false))
    }
}
