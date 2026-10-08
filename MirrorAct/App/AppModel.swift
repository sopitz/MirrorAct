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
        session.audioSampleRate = AirPlayAudioPlayer.sampleRate
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
        session.control = IOSControl(session: session)
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
        session.control = IOSControl(session: session)
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

    /// "iPhone oder iPad spiegeln …"
    func mirrorFirstAvailable() {
        if let device = usb.devices.first(where: { !isMirroring(cableDevice: $0.id) }) ?? usb.devices.first {
            openCableDevice(device)
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

/// Geräte, die Xcode kennt, über `xcrun devicectl` (falls Xcode da ist)
enum DeviceInfoLookup {
    struct Device {
        let name: String
        let productType: String?
        let udid: String?
        let developerModeEnabled: Bool
    }

    /// Modellkennung eines per Kabel verbundenen Geräts
    static func productType(forDeviceNamed name: String) -> String? {
        devices().first { $0.name == name }?.productType
    }

    /// Gerät gesperrt? (`devicectl device info lockState`, dauert einige Sekunden; unbekannt = nein)
    static func isLocked(udid: String) -> Bool {
        run(["device", "info", "lockState", "--device", udid])?["passcodeRequired"] as? Bool == true
    }

    static func devices() -> [Device] {
        guard let devices = run(["list", "devices"])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let properties = device["deviceProperties"] as? [String: Any]
            let hardware = device["hardwareProperties"] as? [String: Any]
            guard let name = properties?["name"] as? String else { return nil }
            return Device(name: name, productType: hardware?["productType"] as? String,
                          udid: hardware?["udid"] as? String,
                          developerModeEnabled: properties?["developerModeStatus"] as? String == "enabled")
        }
    }

    /// `xcrun devicectl <arguments>` → "result" der JSON-Ausgabe
    private static func run(_ arguments: [String]) -> [String: Any]? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("mirroract-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl"] + arguments + ["--quiet", "--json-output", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return nil }

        guard let data = try? Data(contentsOf: output),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["result"] as? [String: Any]
    }
}
