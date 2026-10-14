// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Persistent settings (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var receiverName: String { didSet { defaults.set(receiverName, forKey: "receiverName") } }
    @Published var pin: String { didSet { defaults.set(pin, forKey: "pin") } }
    @Published var streamHeight: Int { didSet { defaults.set(streamHeight, forKey: "streamHeight") } }
    @Published var maxFPS: Int { didSet { defaults.set(maxFPS, forKey: "maxFPS") } }
    @Published var hevc: Bool { didSet { defaults.set(hevc, forKey: "hevc") } }
    @Published var peerToPeer: Bool { didSet { defaults.set(peerToPeer, forKey: "peerToPeer") } }
    @Published var showFrame: Bool { didSet { defaults.set(showFrame, forKey: "showFrame") } }
    @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") } }
    @Published var playAudio: Bool { didSet { defaults.set(playAudio, forKey: "playAudio") } }
    @Published var recordWithFrame: Bool { didSet { defaults.set(recordWithFrame, forKey: "recordWithFrame") } }
    /// Tool rail always visible instead of only on hover
    @Published var alwaysShowTools: Bool { didSet { defaults.set(alwaysShowTools, forKey: "alwaysShowTools") } }
    /// Start iPhone/iPad control right away on connect (otherwise only via “Control”)
    @Published var autoStartControl: Bool { didSet { defaults.set(autoStartControl, forKey: "autoStartControl") } }
    /// Frame color, background etc. for screenshots, recordings and presentation
    @Published var style: FrameStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: "style") }
        }
    }

    /// Fixed, locally administered device ID of the AirPlay receiver (not the Mac's MAC address,
    /// so MirrorAct stays unique alongside UxPlay or the macOS receiver).
    let receiverDeviceID: String

    init() {
        defaults.register(defaults: [
            "receiverName": "MirrorAct",
            "streamHeight": 2160,
            "maxFPS": 60,
            "hevc": true,
            "peerToPeer": true,
            "showFrame": true,
            "alwaysOnTop": false,
            "playAudio": true,
            "recordWithFrame": false,
            "alwaysShowTools": false,
            "autoStartControl": true,
        ])
        receiverName = defaults.string(forKey: "receiverName") ?? "MirrorAct"
        streamHeight = defaults.integer(forKey: "streamHeight")
        maxFPS = defaults.integer(forKey: "maxFPS")
        hevc = defaults.bool(forKey: "hevc")
        peerToPeer = defaults.bool(forKey: "peerToPeer")
        showFrame = defaults.bool(forKey: "showFrame")
        alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        playAudio = defaults.bool(forKey: "playAudio")
        recordWithFrame = defaults.bool(forKey: "recordWithFrame")
        alwaysShowTools = defaults.bool(forKey: "alwaysShowTools")
        autoStartControl = defaults.bool(forKey: "autoStartControl")
        if let data = defaults.data(forKey: "style"), let stored = try? JSONDecoder().decode(FrameStyle.self, from: data) {
            style = stored
        } else {
            style = FrameStyle()
        }

        let store = UserDefaults.standard
        if let stored = store.string(forKey: "pin"), stored.count == 4 {
            pin = stored
        } else {
            let fresh = String(format: "%04d", Int.random(in: 1000...9999))
            store.set(fresh, forKey: "pin")
            pin = fresh
        }

        if let stored = store.string(forKey: "receiverDeviceID") {
            receiverDeviceID = stored
        } else {
            // locally administered unicast address (bit 1 set, bit 0 cleared)
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] | 0x02) & 0xFE
            let fresh = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            store.set(fresh, forKey: "receiverDeviceID")
            receiverDeviceID = fresh
        }
    }

    var pinNumber: Int32 { Int32(pin) ?? 0 }

    // MARK: Language

    /// "system", "en" or "de"; takes effect after a restart (the app's AppleLanguages)
    static let languages: [(id: String, name: String)] = [("en", "English"), ("de", "Deutsch")]

    var appLanguage: String {
        get {
            let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            guard let list = domain["AppleLanguages"] as? [String], let first = list.first else { return "system" }
            return Self.languages.first { first.hasPrefix($0.id) }?.id ?? "system"
        }
        set {
            objectWillChange.send()
            if newValue == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// relaunches the app (after quitting, so the AirPlay name is free)
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Folder for the AirPlay key etc.
    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MirrorAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Known devices (for the device list)

    struct KnownDevice: Codable, Hashable, Identifiable {
        var id: String { "\(transport.rawValue):\(key)" }
        enum Transport: String, Codable { case cable, wireless, android }
        var key: String            // AirPlay device ID, AVCaptureDevice.uniqueID or Android serial number
        var transport: Transport
        var name: String
        var modelIdentifier: String?
        var lastSeen: Date
    }

    @Published private(set) var knownDevices: [KnownDevice] = {
        guard let data = UserDefaults.standard.data(forKey: "knownDevices"),
              let list = try? JSONDecoder().decode([KnownDevice].self, from: data) else { return [] }
        return list
    }()

    func remember(_ device: KnownDevice) {
        var list = knownDevices.filter { $0.id != device.id }
        list.insert(device, at: 0)
        knownDevices = Array(list.prefix(12))
        if let data = try? JSONEncoder().encode(knownDevices) {
            defaults.set(data, forKey: "knownDevices")
        }
    }

    func forget(_ device: KnownDevice) {
        knownDevices.removeAll { $0.id == device.id }
        if let data = try? JSONEncoder().encode(knownDevices) {
            defaults.set(data, forKey: "knownDevices")
        }
    }

    /// Model identifier for a device name, learned via AirPlay (USB provides none).
    func modelIdentifier(forDeviceNamed name: String) -> String? {
        knownDevices.first { $0.name == name && $0.modelIdentifier != nil }?.modelIdentifier
    }
}
