// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// Zentrale Steuerung: Geräte, AirPlay-Empfänger, Spiegelfenster
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum ReceiverState: Equatable {
        case stopped
        case ready
        case failed(Int32)
    }

    let settings = AppSettings.shared
    let usb = USBDeviceMonitor()
    let receiver = AirPlayReceiver()
    let android = AndroidDeviceMonitor()

    @Published private(set) var receiverState: ReceiverState = .stopped
    @Published private(set) var activeWirelessClient: AirPlayReceiver.Client?
    @Published var pinRequested = false

    private var controllers: [String: MirrorWindowController] = [:] {
        didSet { openSessionIDs = Set(controllers.keys) }
    }
    @Published private(set) var openSessionIDs: Set<String> = []
    private var captures: [String: USBCaptureSession] = [:]
    private weak var wirelessSession: MirrorSession?
    private var cancellables: Set<AnyCancellable> = []

    var keyMirror: MirrorWindowController? {
        controllers.values.first { $0.window?.isKeyWindow == true } ?? controllers.values.first
    }

    func isMirroring(cableDevice id: String) -> Bool { openSessionIDs.contains("usb:\(id)") }

    func start() {
        usb.start()
        usb.$devices.sink { [weak self] devices in
            guard let self else { return }
            for device in devices {
                self.settings.remember(.init(key: device.id, transport: .cable, name: device.name,
                                             modelIdentifier: self.settings.modelIdentifier(forDeviceNamed: device.name),
                                             lastSeen: Date()))
            }
        }.store(in: &cancellables)

        receiver.audio.recordTap = { [weak receiver] sample in receiver?.sink?.recordAudio(sample) }
        receiver.onClient = { [weak self] client in self?.wirelessClientConnected(client) }
        receiver.onConnectionLost = { [weak self] in self?.wirelessDisconnected() }
        receiver.onConnectionCount = { [weak self] count in
            if count == 0, self?.wirelessSession?.state == .live { self?.wirelessDisconnected() }
        }
        receiver.onPin = { [weak self] _ in
            self?.pinRequested = true
            self?.wirelessSession?.state = .disconnected(String(localized: "Enter this code on the iPhone: \(AppSettings.shared.pin)"))
        }
        receiver.onSourceSize = { [weak self] size in
            if size.width > 0, size.height > 0 { self?.wirelessSession?.sourcePixelSize = size }
        }
        restartReceiver()
        startAndroid()
    }

    // MARK: Kabellos (AirPlay)

    func restartReceiver() {
        let config = AirPlayReceiver.Config(
            name: settings.receiverName.isEmpty ? "MirrorAct" : settings.receiverName,
            deviceID: settings.receiverDeviceID,
            keyfile: settings.supportDirectory.appendingPathComponent("airplay.pem").path,
            streamHeight: settings.streamHeight,
            maxFPS: settings.maxFPS,
            hevc: settings.hevc,
            peerToPeer: settings.peerToPeer,
            pin: settings.pinNumber)
        let result = receiver.start(config)
        receiverState = result == 0 ? .ready : .failed(result)
    }

    func disconnectWireless() {
        receiver.disconnect()
    }

    private func wirelessClientConnected(_ client: AirPlayReceiver.Client) {
        settings.remember(.init(key: client.deviceID, transport: .wireless, name: client.name,
                                modelIdentifier: client.model, lastSeen: Date()))
        activeWirelessClient = client
        pinRequested = false

        if let session = wirelessSession, let controller = controllers[session.id] {
            session.deviceName = client.name
            session.modelIdentifier = client.model
            session.state = .connecting
            session.sink.clear()
            receiver.sink = session.sink
            controller.present()
            return
        }

        let session = MirrorSession(id: "airplay", kind: .wireless, deviceName: client.name,
                                    modelIdentifier: client.model, muted: !settings.playAudio)
        session.audioSampleRate = AACAudioPlayer.Format.airPlay.sampleRate
        session.onMuteChange = { [weak self] muted in self?.receiver.audio.muted = muted }
        session.onClose = { [weak self] in
            guard let self else { return }
            self.receiver.sink = nil
            self.receiver.disconnect()
            self.activeWirelessClient = nil
        }
        receiver.audio.muted = session.muted
        receiver.sink = session.sink
        wirelessSession = session
        let controller = MirrorWindowController(session: session)
        controllers[session.id] = controller
        controller.present()
    }

    private func wirelessDisconnected() {
        activeWirelessClient = nil
        guard let session = wirelessSession else { return }
        session.stopRecording()
        if case .disconnected = session.state { return }
        session.state = .disconnected(String(localized: "Disconnected – choose “\(settings.receiverName)” on the iPhone again"))
        session.sink.clear()
    }

    // MARK: Kabel (USB)

    func openCableDevice(_ device: USBDeviceMonitor.Device) {
        let key = "usb:\(device.id)"
        if let controller = controllers[key] {
            controller.present()
            return
        }
        Task {
            guard await USBCaptureSession.requestAccess() else {
                showCameraAccessAlert()
                return
            }
            startCapture(device, key: key)
        }
    }

    private func startCapture(_ device: USBDeviceMonitor.Device, key: String) {
        guard let captureDevice = usb.captureDevice(for: device.id) else {
            NSSound.beep()
            return
        }
        let session = MirrorSession(id: key, kind: .cable, deviceName: device.name,
                                    modelIdentifier: settings.modelIdentifier(forDeviceNamed: device.name),
                                    muted: !settings.playAudio)
        let capture = USBCaptureSession()
        capture.muted = session.muted
        let sink = session.sink
        session.audioSampleRate = USBCaptureSession.audioSampleRate
        capture.onFrame = { buffer, time in sink.push(buffer, time: time) }
        capture.onAudio = { sample in sink.recordAudio(sample) }
        capture.onStop = { [weak session] reason in
            session?.stopRecording()
            session?.state = .disconnected(reason ?? String(localized: "Cable disconnected"))
        }
        session.onMuteChange = { [weak capture] muted in capture?.muted = muted }
        session.onClose = { [weak self] in
            capture.stop()
            self?.captures[key] = nil
        }
        do {
            try capture.start(device: captureDevice)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(device.name) can’t be opened")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        captures[key] = capture
        let controller = MirrorWindowController(session: session)
        controllers[key] = controller
        controller.present()

        if session.modelIdentifier == nil {
            Task.detached {
                guard let identifier = DeviceInfoLookup.productType(forDeviceNamed: device.name) else { return }
                await MainActor.run {
                    session.modelIdentifier = identifier
                    AppSettings.shared.remember(.init(key: device.id, transport: .cable, name: device.name,
                                                      modelIdentifier: identifier, lastSeen: Date()))
                }
            }
        }
    }

    private func showCameraAccessAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Camera access required")
        alert.informativeText = String(localized: "macOS provides the screen of an iPhone connected by cable like a camera. Please allow MirrorAct under Privacy & Security → Camera.")
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Android (adb + scrcpy-Server)

    private var androidClients: [String: ScrcpyClient] = [:]
    private var androidAudio: [String: AACAudioPlayer] = [:]
    private var rememberedAndroid: Set<String> = []

    private static func androidKey(_ device: AndroidDeviceMonitor.Device) -> String { "android:\(device.stableID)" }

    func isMirroring(androidDevice device: AndroidDeviceMonitor.Device) -> Bool {
        openSessionIDs.contains(Self.androidKey(device))
    }

    private func startAndroid() {
        android.start()
        android.$devices.sink { [weak self] devices in
            DispatchQueue.main.async { self?.androidDevicesChanged(devices) }
        }.store(in: &cancellables)
    }

    func stopAndroid() {
        android.stop()
        androidClients.values.forEach { $0.stop() }
        androidClients = [:]
    }

    private func androidDevicesChanged(_ devices: [AndroidDeviceMonitor.Device]) {
        for device in devices where device.state == .ready {
            guard let info = device.info else { continue }
            if rememberedAndroid.insert(device.serial).inserted {
                settings.remember(.init(key: device.stableID, transport: .android, name: info.displayName,
                                        modelIdentifier: "android", lastSeen: Date()))
            }
            // Fenster noch offen, Gerät wieder da (Kabel neu eingesteckt): weiterspiegeln
            let key = Self.androidKey(device)
            if let controller = controllers[key], androidClients[key] == nil {
                connectAndroid(device, session: controller.session)
            }
        }
        rememberedAndroid.formIntersection(devices.map(\.serial))
    }

    func openAndroidDevice(_ device: AndroidDeviceMonitor.Device) {
        switch device.state {
        case .ready:
            break
        case .unauthorized:
            let alert = NSAlert()
            alert.messageText = String(localized: "Allow USB debugging on \(device.name)")
            alert.informativeText = String(localized: "Unlock the phone and tap “Allow” in the dialog “Allow USB debugging?”. If no dialog appears, unplug the cable and connect it again.")
            alert.runModal()
            return
        case .offline:
            NSSound.beep()
            return
        }
        guard device.info != nil else {
            // Angaben (Name, Bildschirm) zuerst lesen, sonst ändert sich die Kennung des Fensters
            Task {
                var loaded = device
                loaded.info = try? await Task.detached { try AndroidDeviceInfo.read(serial: device.serial) }.value
                if loaded.info == nil { loaded.info = AndroidDeviceInfo(model: device.model) }
                openAndroidDevice(loaded)
            }
            return
        }
        let key = Self.androidKey(device)
        if let controller = controllers[key] {
            controller.present()
            return
        }
        let session = MirrorSession(id: key, kind: .android, deviceName: device.name, modelIdentifier: "android",
                                    muted: !settings.playAudio)
        let audio = AACAudioPlayer(format: .android)
        audio.muted = session.muted
        audio.recordTap = { [weak sink = session.sink] sample in sink?.recordAudio(sample) }
        session.audioSampleRate = audio.sampleRate
        session.onMuteChange = { muted in audio.muted = muted }
        androidAudio[key] = audio
        session.onClose = { [weak self] in
            self?.androidClients[key]?.stop()
            self?.androidClients[key] = nil
            self?.androidAudio[key]?.stop()
            self?.androidAudio[key] = nil
        }
        let controller = MirrorWindowController(session: session)
        controllers[key] = controller
        connectAndroid(device, session: session)
        controller.present()
    }

    private func connectAndroid(_ device: AndroidDeviceMonitor.Device, session: MirrorSession) {
        let key = session.id
        var options = ScrcpyClient.Options()
        options.maxFPS = settings.maxFPS
        options.videoBitRate = device.isWireless ? 8_000_000 : 16_000_000
        let client = ScrcpyClient(serial: device.serial, options: options)
        let sink = session.sink
        client.onFrame = { buffer in sink.push(buffer) }
        if let audio = androidAudio[key] {
            client.onAudioConfig = { cookie in audio.setCookie(cookie) }
            client.onAudioPacket = { packet in audio.play(packet) }
        }
        client.onClipboard = { text in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        client.onStop = { [weak self, weak session, weak client] reason in
            guard let self, let client, self.androidClients[key] === client else { return }
            self.androidClients[key] = nil
            self.androidAudio[key]?.stop()
            session?.stopRecording()
            session?.control = nil
            session?.state = .disconnected(reason ?? String(localized: "Disconnected – connect the phone again"))
        }
        if let info = device.info {
            session.deviceName = info.displayName
            session.profileOverride = info.profile
        }
        session.state = .connecting
        session.sink.clear()
        session.control = AndroidControl(client: client)
        androidClients[key] = client
        client.start()
    }

    /// per Kabel verbundenes Android-Gerät auf WLAN umstellen; ein offenes Fenster verbindet sich neu
    func switchAndroidToWiFi(_ device: AndroidDeviceMonitor.Device) {
        let name = device.name
        Task {
            do {
                try await Task.detached { try AndroidWireless.switchToWiFi(serial: device.serial) }.value
                controllers[Self.androidKey(device)]?.session
                    .showToast(String(localized: "Connected via Wi-Fi – you can unplug the cable"))
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "\(name) can’t be switched to Wi-Fi")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// "iPhone oder iPad spiegeln …"
    func mirrorFirstAvailable() {
        if let device = usb.devices.first(where: { !isMirroring(cableDevice: $0.id) }) ?? usb.devices.first {
            openCableDevice(device)
            return
        }
        if let device = android.devices.first(where: { $0.state == .ready && !isMirroring(androidDevice: $0) }) {
            openAndroidDevice(device)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "No device connected by cable")
        alert.informativeText = String(localized: "Cable: connect and unlock the iPhone, then choose this again.\n\nWireless: on the iPhone, open Control Center → Screen Mirroring → “\(settings.receiverName)”. Code: \(settings.pin)")
        alert.runModal()
    }

    // MARK: Fenster

    func windowClosed(_ controller: MirrorWindowController) {
        controllers.removeValue(forKey: controller.session.id)
    }

    // MARK: Bearbeiten / einrahmen

    private var editors: [UUID: EditorWindowController] = [:]

    /// «Bearbeiten …»: ein Bild, zwei Bilder (Duo) oder ein Video im Editor; mehr Bilder werden direkt gerahmt
    func openEditorPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .movie]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose screenshots (one, or two for a duo) or a screen recording")
        panel.prompt = String(localized: "Edit")
        guard panel.runModal() == .OK else { return }
        openEditor(urls: panel.urls)
    }

    func openEditor(urls: [URL]) {
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if images.count > 2 {
            let outputs = FrameRenderer.frameScreenshotFiles(images, showFrame: settings.showFrame)
            outputs.isEmpty ? NSSound.beep() : NSWorkspace.shared.activateFileViewerSelecting(outputs)
            return
        }
        let videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
        let groups: [[URL]] = videos.isEmpty ? [images] : videos.map { [$0] }
        for group in groups where !group.isEmpty {
            guard let document = EditorDocument(urls: group) else {
                NSSound.beep()
                continue
            }
            let controller = EditorWindowController(document: document)
            controller.onClose = { [weak self] in self?.editors[document.id] = nil }
            editors[document.id] = controller
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// alter Menüpunkt: alles ohne Editor einrahmen
    func frameScreenshots() { openEditorPanel() }
}

/// Modellkennung eines per Kabel verbundenen Geräts über `xcrun devicectl` (falls Xcode da ist)
enum DeviceInfoLookup {
    static func productType(forDeviceNamed name: String) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("mirroract-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "--quiet", "--json-output", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return nil }

        guard let data = try? Data(contentsOf: output),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return nil }
        for device in devices {
            let properties = device["deviceProperties"] as? [String: Any]
            let hardware = device["hardwareProperties"] as? [String: Any]
            if properties?["name"] as? String == name, let type = hardware?["productType"] as? String {
                return type
            }
        }
        return nil
    }
}
