// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Foundation

/// Persistent settings (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Where the settings are kept: the app's own preferences, or those of the tests while the
    /// app runs as their host. The test host has the app's bundle identifier, so without a domain
    /// of their own the tests would change the settings of the installed app.
    let defaults: UserDefaults

    /// The domain of the tests' settings; nil when the app is not running as the test host
    static let testSuiteName: String? = AppDelegate.isTesting
        ? (Bundle.main.bundleIdentifier ?? "io.github.sopitz.MirrorAct") + ".tests"
        : nil

    /// The app's preferences, or those of the tests, emptied first so that every test run starts
    /// from the registered defaults. `atExit` registers what runs when the process exits; the
    /// tests pass their own, so that they can check what is registered without exiting.
    static func makeDefaults(atExit: (@convention(c) () -> Void) -> Void = { _ = atexit($0) }) -> UserDefaults {
        guard let name = testSuiteName, let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        // emptied again when the test run ends, so that the code, the device ID and what the
        // tests set do not stay on the Mac; XCTest ends the test host with exit()
        atExit { AppSettings.emptyTestDomain() }
        return suite
    }

    /// Empties the tests' settings. cfprefsd keeps the file of the domain, empty: it writes it
    /// again when it is deleted while the app runs.
    static func emptyTestDomain() {
        guard let name = testSuiteName else { return }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    @Published var receiverName: String { didSet { defaults.set(receiverName, forKey: "receiverName") } }
    @Published var pin: String { didSet { defaults.set(pin, forKey: "pin") } }
    @Published var streamHeight: Int { didSet { defaults.set(streamHeight, forKey: "streamHeight") } }
    @Published var maxFPS: Int { didSet { defaults.set(maxFPS, forKey: "maxFPS") } }
    @Published var hevc: Bool { didSet { defaults.set(hevc, forKey: "hevc") } }
    @Published var peerToPeer: Bool { didSet { defaults.set(peerToPeer, forKey: "peerToPeer") } }
    @Published var showFrame: Bool { didSet { defaults.set(showFrame, forKey: "showFrame") } }
    @Published var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") } }
    /// Keep on top also reaches every desktop and other apps' full-screen Spaces
    @Published var onTopEverywhere: Bool { didSet { defaults.set(onTopEverywhere, forKey: "onTopEverywhere") } }
    @Published var playAudio: Bool { didSet { defaults.set(playAudio, forKey: "playAudio") } }
    @Published var recordWithFrame: Bool { didSet { defaults.set(recordWithFrame, forKey: "recordWithFrame") } }
    /// Tool rail always visible instead of only on hover
    @Published var alwaysShowTools: Bool { didSet { defaults.set(alwaysShowTools, forKey: "alwaysShowTools") } }
    /// Start iPhone/iPad control right away on connect (otherwise only via “Control”)
    @Published var autoStartControl: Bool { didSet { defaults.set(autoStartControl, forKey: "autoStartControl") } }
    /// Language the text on the screen is translated into: "system" or a language identifier
    @Published var translationLanguage: String {
        didSet { defaults.set(translationLanguage, forKey: "translationLanguage") }
    }
    /// What translates the text on the screen: "apple" (on this Mac) or "llm" (a language model
    /// service with the user's own API key)
    @Published var translationEngine: String {
        didSet { defaults.set(translationEngine, forKey: "translationEngine") }
    }
    /// The language model service (`LLMProvider.id`)
    @Published var llmProvider: String { didSet { defaults.set(llmProvider, forKey: "llmProvider") } }
    /// Model per service; none = the service's default model
    @Published var llmModels: [String: String] { didSet { defaults.set(llmModels, forKey: "llmModels") } }
    /// Address per service, for those where it can be changed (own server, local model)
    @Published var llmBaseURLs: [String: String] { didSet { defaults.set(llmBaseURLs, forKey: "llmBaseURLs") } }
    /// Counts up whenever an API key was saved or removed; the keys themselves are in the Keychain
    @Published var llmKeyRevision = 0
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
        defaults = Self.makeDefaults()
        defaults.register(defaults: [
            "receiverName": "MirrorAct",
            "streamHeight": 2160,
            "maxFPS": 60,
            "hevc": true,
            "peerToPeer": true,
            "showFrame": true,
            "alwaysOnTop": false,
            "onTopEverywhere": false,
            "playAudio": true,
            "recordWithFrame": false,
            "alwaysShowTools": false,
            "autoStartControl": true,
            "translationLanguage": "system",
            "translationEngine": "apple",
            "llmProvider": "openai",
        ])
        receiverName = defaults.string(forKey: "receiverName") ?? "MirrorAct"
        streamHeight = defaults.integer(forKey: "streamHeight")
        maxFPS = defaults.integer(forKey: "maxFPS")
        hevc = defaults.bool(forKey: "hevc")
        peerToPeer = defaults.bool(forKey: "peerToPeer")
        showFrame = defaults.bool(forKey: "showFrame")
        alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        onTopEverywhere = defaults.bool(forKey: "onTopEverywhere")
        playAudio = defaults.bool(forKey: "playAudio")
        recordWithFrame = defaults.bool(forKey: "recordWithFrame")
        alwaysShowTools = defaults.bool(forKey: "alwaysShowTools")
        autoStartControl = defaults.bool(forKey: "autoStartControl")
        translationLanguage = defaults.string(forKey: "translationLanguage") ?? "system"
        translationEngine = defaults.string(forKey: "translationEngine") ?? "apple"
        llmProvider = defaults.string(forKey: "llmProvider") ?? "openai"
        llmModels = defaults.dictionary(forKey: "llmModels") as? [String: String] ?? [:]
        llmBaseURLs = defaults.dictionary(forKey: "llmBaseURLs") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "style"), let stored = try? JSONDecoder().decode(FrameStyle.self, from: data) {
            style = stored
        } else {
            style = FrameStyle()
        }

        let store = defaults
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

        if let data = defaults.data(forKey: "knownDevices"),
           let list = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            knownDevices = list
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

    /// Language to translate into; "system" follows the app's language
    var translationTarget: Locale.Language {
        let identifier = translationLanguage == "system"
            ? Locale.preferredLanguages.first ?? "en"
            : translationLanguage
        return Locale.Language(identifier: identifier)
    }

    /// Fires after anything changed that decides how the screen is translated
    var translationSettingsChanged: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            $translationLanguage.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $translationEngine.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $llmProvider.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $llmModels.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $llmBaseURLs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $llmKeyRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]).eraseToAnyPublisher()
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

    @Published private(set) var knownDevices: [KnownDevice] = []

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
