// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Persistente Einstellungen (UserDefaults).
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
    /// Werkzeugleiste dauerhaft statt nur beim Überfahren
    @Published var alwaysShowTools: Bool { didSet { defaults.set(alwaysShowTools, forKey: "alwaysShowTools") } }
    /// Bedienung von iPhone/iPad beim Verbinden gleich starten (sonst erst auf «Bedienen»)
    @Published var autoStartControl: Bool { didSet { defaults.set(autoStartControl, forKey: "autoStartControl") } }
    /// Rahmenfarbe, Hintergrund usw. für Screenshots, Aufnahmen und Präsentation
    @Published var style: FrameStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: "style") }
        }
    }

    /// Feste, lokal verwaltete Geräte-ID des AirPlay-Empfängers (nicht die MAC des Macs,
    /// damit MirrorAct neben UxPlay oder dem macOS-Empfänger eindeutig bleibt).
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
            // lokal verwaltete Unicast-Adresse (Bit 1 gesetzt, Bit 0 gelöscht)
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] | 0x02) & 0xFE
            let fresh = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            store.set(fresh, forKey: "receiverDeviceID")
            receiverDeviceID = fresh
        }
    }

    var pinNumber: Int32 { Int32(pin) ?? 0 }

    // MARK: Sprache

    /// "system", "en" oder "de"; wirkt nach einem Neustart (AppleLanguages der App)
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

    /// startet die App neu (nach dem Beenden, damit der AirPlay-Name frei ist)
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Ordner für den AirPlay-Schlüssel usw.
    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MirrorAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Bekannte Geräte (für die Geräteliste)

    struct KnownDevice: Codable, Hashable, Identifiable {
        var id: String { "\(transport.rawValue):\(key)" }
        enum Transport: String, Codable { case cable, wireless, android }
        var key: String            // AirPlay-Geräte-ID, AVCaptureDevice.uniqueID bzw. Android-Seriennummer
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

    /// Modellkennung zu einem Gerätenamen, gelernt über AirPlay (USB liefert keine).
    func modelIdentifier(forDeviceNamed name: String) -> String? {
        knownDevices.first { $0.name == name && $0.modelIdentifier != nil }?.modelIdentifier
    }
}
