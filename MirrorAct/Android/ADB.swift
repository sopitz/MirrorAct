// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Darwin
import CoreGraphics
import Foundation

/// adb (Android Debug Bridge) aus Homebrew oder dem Android-SDK. Apps aus dem Finder erben
/// den PATH der Shell nicht, darum werden die üblichen Orte direkt abgesucht.
enum ADB {
    static var executable: URL? {
        var candidates: [String] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key] { candidates.append("\(sdk)/platform-tools/adb") }
        }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Führt adb aus und wartet (nicht auf dem Main-Thread aufrufen)
    @discardableResult
    static func run(_ arguments: [String], serial: String? = nil, timeout: TimeInterval = 20) throws -> String {
        guard let executable else { throw Failure(message: String(localized: "adb not found")) }
        let process = Process()
        process.executableURL = executable
        process.arguments = (serial.map { ["-s", $0] } ?? []) + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // lesen, bevor gewartet wird: sonst blockiert adb bei vollem Puffer
        var output = Data()
        let reader = DispatchWorkItem { output = pipe.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async(execute: reader)
        if reader.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure(message: "adb \(arguments.first ?? ""): timeout")
        }
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "adb \(arguments.first ?? ""): \(process.terminationStatus)" : message)
        }
        return text
    }
}

/// Angaben zu einem Android-Gerät (über `adb shell` gelesen)
struct AndroidDeviceInfo: Equatable {
    var serialNumber: String?
    var manufacturer: String?
    var model: String?
    var marketingName: String?
    var userName: String?
    var sdk: Int?
    /// Bildschirm in Pixeln (Hochformat) und dpi-Stufe, wie sie die Oberfläche verwendet
    var screenPixels: CGSize?
    var densityDpi: CGFloat?
    /// tatsächliche Pixeldichte des Displays
    var physicalPPI: CGFloat?
    /// Kamera-Aussparung und Radius der Bildschirmecken (Pixel, Hochformat)
    var cutoutRect: CGRect?
    var cornerRadius: CGFloat?
    /// Samsung: Reihenfolge der Navigationstasten (0 = Apps | Home | Zurück, 1 = Zurück | Home | Apps)
    var samsungKeyOrder: Int?

    var displayModel: String {
        if let marketingName, !marketingName.isEmpty { return marketingName }
        guard let model, !model.isEmpty else { return "Android" }
        if let manufacturer, !manufacturer.isEmpty,
           !model.localizedCaseInsensitiveContains(manufacturer), manufacturer.lowercased() != "google" {
            return "\(manufacturer.capitalized) \(model)"
        }
        return model
    }

    var displayName: String {
        if let userName, !userName.isEmpty, userName != "null" { return userName }
        return displayModel
    }

    var profile: DeviceProfile {
        DeviceProfile.android(name: displayModel, screenPixels: screenPixels, densityDpi: densityDpi,
                              ppi: physicalPPI, cutoutRect: cutoutRect, cornerRadius: cornerRadius)
    }

    /// Ein einziger Aufruf, Zeilen «key=value»
    static func read(serial: String) throws -> AndroidDeviceInfo {
        let script = [
            "echo serial=$(getprop ro.serialno)",
            "echo manufacturer=$(getprop ro.product.manufacturer)",
            "echo model=$(getprop ro.product.model)",
            "echo marketname=$(getprop ro.product.marketname)",
            "echo marketing=$(getprop ro.config.marketing_name)",
            "echo sdk=$(getprop ro.build.version.sdk)",
            "echo name=$(settings get global device_name)",
            "echo size=$(wm size | tail -n 1)",
            "echo density=$(wm density | tail -n 1)",
            "echo dpi=$(dumpsys display 2>/dev/null | grep -m 1 -o '[0-9.]* x [0-9.]* dpi')",
            "echo cutout=$(dumpsys display 2>/dev/null | grep -m 1 -o 'boundingRect={Bounds=[^}]*}')",
            "echo spec=$( (dumpsys display; dumpsys window) 2>/dev/null | grep -m 1 -o 'cutoutSpec={M[^}]*}')",
            "echo navorder=$(settings get global navigationbar_key_order)",
            "echo radius=$(dumpsys window 2>/dev/null | grep -m 1 -o 'RoundedCorner{position=TopLeft, radius=[0-9]*')",
        ].joined(separator: "; ")
        let output = try ADB.run(["shell", script], serial: serial, timeout: 10)
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        func value(_ key: String) -> String? {
            guard let v = values[key], !v.isEmpty else { return nil }
            return v
        }

        var info = AndroidDeviceInfo()
        info.serialNumber = value("serial")
        info.manufacturer = value("manufacturer")
        info.model = value("model")
        info.marketingName = value("marketname") ?? value("marketing")
        info.userName = value("name")
        info.sdk = value("sdk").flatMap { Int($0) }
        info.samsungKeyOrder = value("navorder").flatMap { Int($0) }
        // "Physical size: 1080x2400" bzw. "Override size: …"
        if let size = value("size")?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                info.screenPixels = CGSize(width: min(parts[0], parts[1]), height: max(parts[0], parts[1]))
            }
        }
        if let density = value("density")?.split(separator: ":").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
            info.densityDpi = density
        }
        // "409.432 x 411.891 dpi"
        if let dpi = value("dpi")?.split(separator: " ").first.flatMap({ Double($0) }), dpi > 50 {
            info.physicalPPI = dpi
        }
        // Form der Aussparung als Pfad (genau), sonst ihre Begrenzung
        // "boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(498, 0 - 582, 145), …]}"
        if let spec = value("spec"), let width = info.screenPixels?.width,
           let circle = Self.parseCutoutCircle(spec, screenWidth: width, density: info.densityDpi ?? 160) {
            info.cutoutRect = circle
        } else if let cutout = value("cutout") {
            info.cutoutRect = Self.parseRects(cutout).first { !$0.isEmpty }
        }
        if let radius = value("radius")?.split(separator: "=").last.flatMap({ Double($0) }) {
            info.cornerRadius = radius
        }
        return info
    }

    /// Kreis aus der Pfadbeschreibung der Aussparung, z. B. Samsung
    /// "M 0,0 M 0, 8.53 a 12.44,12.44 0 1,0 0,24.89 a … Z @dp" oder "M 40,83 a 42.75,42.75 0 1 0 85.5,0 … @left".
    /// x zählt von der Bildschirmmitte (@left: vom linken, @right: vom rechten Rand), @dp: in dp statt Pixeln.
    static func parseCutoutCircle(_ spec: String, screenWidth: CGFloat, density: CGFloat) -> CGRect? {
        let body = spec.replacingOccurrences(of: "cutoutSpec={", with: "").replacingOccurrences(of: "}", with: "")
        guard let arc = body.firstIndex(where: { $0 == "a" || $0 == "A" }), body[arc] == "a",
              let move = body[..<arc].lastIndex(of: "M") else { return nil }
        func numbers(_ text: Substring) -> [CGFloat] {
            text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.map { CGFloat($0) }
        }
        let start = numbers(body[body.index(after: move)..<arc])
        let arcEnd = body[body.index(after: arc)...].firstIndex(where: { $0.isLetter }) ?? body.endIndex
        let values = numbers(body[body.index(after: arc)..<arcEnd])
        // erster Halbkreis: Radius, dann Endpunkt relativ zum Start (gegenüberliegender Punkt)
        guard start.count >= 2, values.count >= 7, values[0] > 0 else { return nil }
        let scale = body.contains("@dp") ? density / 160 : 1
        let radius = values[0] * scale
        var center = CGPoint(x: (start[0] + values[5] / 2) * scale, y: (start[1] + values[6] / 2) * scale)
        if body.contains("@left") {
            // schon vom linken Rand
        } else if body.contains("@right") {
            center.x = screenWidth - center.x
        } else {
            center.x += screenWidth / 2
        }
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        guard rect.minX >= 0, rect.maxX <= screenWidth, rect.minY >= 0, radius < screenWidth / 4 else { return nil }
        return rect
    }

    /// "Rect(l, t - r, b)" → CGRect
    static func parseRects(_ text: String) -> [CGRect] {
        var rects: [CGRect] = []
        var rest = Substring(text)
        while let open = rest.range(of: "Rect(") {
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { break }
            let numbers = rest[..<close]
                .split(whereSeparator: { $0 == "," || $0 == "-" || $0 == " " })
                .compactMap { Double($0) }
            if numbers.count == 4 {
                rects.append(CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0],
                                    height: numbers[3] - numbers[1]))
            }
            rest = rest[close...]
        }
        return rects
    }
}

/// Angeschlossene Android-Geräte (Kabel oder WLAN-Debugging), laufend über `adb track-devices`
@MainActor
final class AndroidDeviceMonitor: ObservableObject {
    struct Device: Identifiable, Equatable {
        enum State: Equatable { case ready, unauthorized, offline }
        let serial: String
        var id: String { serial }
        var state: State
        /// aus `adb devices -l` (mit Unterstrichen), bis die Angaben gelesen sind
        var model: String?
        var info: AndroidDeviceInfo?

        /// verbunden über WLAN (IP:Port oder mDNS-Name)
        var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
        /// bleibt gleich über Kabel und WLAN
        var stableID: String { info?.serialNumber ?? serial }
        var name: String { info?.displayName ?? model?.replacingOccurrences(of: "_", with: " ") ?? "Android" }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var adbAvailable = true

    private var process: Process?
    private var buffer = Data()
    private var infoRequests: Set<String> = []
    private var retryTask: Task<Void, Never>?

    func start() {
        guard process == nil else { return }
        guard let executable = ADB.executable else {
            adbAvailable = false
            scheduleRetry(after: 10)
            return
        }
        adbAvailable = true
        let process = Process()
        process.executableURL = executable
        process.arguments = ["track-devices", "-l"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.buffer = Data()
                self.update([])
                self.scheduleRetry(after: 3)   // adb-Server neu gestartet o. ä.
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            Log.error("adb track-devices: \(error.localizedDescription)")
            scheduleRetry(after: 10)
        }
    }

    func stop() {
        retryTask?.cancel()
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    func device(serial: String) -> Device? { devices.first { $0.serial == serial } }

    /// Angaben erneut lesen (z. B. nach dem Erlauben des USB-Debuggings)
    func refreshInfo(for serial: String) {
        guard !infoRequests.contains(serial) else { return }
        infoRequests.insert(serial)
        Task.detached {
            let info = try? AndroidDeviceInfo.read(serial: serial)
            await MainActor.run {
                self.infoRequests.remove(serial)
                guard let info, let index = self.devices.firstIndex(where: { $0.serial == serial }) else { return }
                self.devices[index].info = info
            }
        }
    }

    private func scheduleRetry(after seconds: UInt64) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// Nachrichten: 4 Hex-Ziffern Länge, dann die Geräteliste wie `adb devices -l`
    private func receive(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            guard let length = Int(String(decoding: buffer.prefix(4), as: UTF8.self), radix: 16) else {
                buffer = Data()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let body = String(decoding: buffer.dropFirst(4).prefix(length), as: UTF8.self)
            buffer = Data(buffer.dropFirst(4 + length))
            update(Self.parse(body))
        }
    }

    private func update(_ list: [Device]) {
        var merged: [Device] = []
        for var device in list {
            if let old = devices.first(where: { $0.serial == device.serial }) {
                device.info = old.info
            }
            merged.append(device)
        }
        if merged != devices { devices = merged }
        for device in merged where device.state == .ready && device.info == nil {
            refreshInfo(for: device.serial)
        }
    }

    private static let states: [String: Device.State] = [
        "device": .ready, "unauthorized": .unauthorized, "offline": .offline,
        "authorizing": .offline, "connecting": .offline,
    ]

    /// "serial   device usb:1-1 product:x model:Pixel_7 device:panther transport_id:1"
    static func parse(_ text: String) -> [Device] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let stateIndex = tokens.indices.dropFirst().first(where: { states[tokens[$0]] != nil }),
                  let state = states[tokens[stateIndex]] else { return nil }
            let serial = tokens[..<stateIndex].joined(separator: " ")
            let model = tokens[stateIndex...].first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return Device(serial: serial, state: state, model: model, info: nil)
        }
    }
}

/// Android über WLAN: ein per Kabel verbundenes Gerät umstellen (adb tcpip) oder ab Android 11
/// mit Kopplungscode koppeln («Kabelloses Debugging»). Aufrufe blockieren.
enum AndroidWireless {
    static let tcpPort = 5555

    /// IP-Adresse des Geräts im WLAN, aus `ip route` ("… dev wlan0 … src 192.168.1.23")
    static func wifiAddress(serial: String) throws -> String? {
        let routes = try ADB.run(["shell", "ip", "route"], serial: serial, timeout: 10)
        for line in routes.split(whereSeparator: \.isNewline) where line.contains("dev wlan") {
            let tokens = line.split(separator: " ")
            if let index = tokens.firstIndex(of: "src"), index + 1 < tokens.count {
                return String(tokens[index + 1])
            }
        }
        return nil
    }

    /// Kabel → WLAN; danach kann das Kabel ab
    static func switchToWiFi(serial: String) throws {
        guard let address = try wifiAddress(serial: serial) else {
            throw ADB.Failure(message: String(localized: "The phone is not connected to a Wi-Fi network."))
        }
        try ADB.run(["tcpip", String(tcpPort)], serial: serial, timeout: 10)
        // adbd startet auf dem Gerät neu
        var lastError: Error?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.6)
            // schlafende Telefone antworten oft nicht auf ARP; ein Paket vom Telefon zum Mac weckt die Verbindung
            if let mac = localAddress(near: address) {
                _ = try? ADB.run(["shell", "ping", "-c", "1", "-W", "1", mac], serial: serial, timeout: 5)
            }
            do {
                try connect(address: "\(address):\(tcpPort)")
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ADB.Failure(message: "adb connect")
    }

    /// eigene IPv4-Adresse im selben Netz wie `address`
    static func localAddress(near address: String) -> String? {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let own = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let net = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard net != 0, own & net == target.s_addr & net else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var value = in_addr(s_addr: own)
            inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        }
        return nil
    }

    /// "Gerät mit Kopplungscode koppeln": Adresse und Code aus dem Dialog auf dem Gerät
    static func pair(address: String, code: String) throws {
        let output = try ADB.run(["pair", address, code], timeout: 20)
        guard output.contains("Successfully paired") else {
            throw ADB.Failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// adb meldet Fehler beim Verbinden mit Status 0, daher die Ausgabe prüfen
    static func connect(address: String) throws {
        let output = try ADB.run(["connect", address], timeout: 15)
        guard output.contains("connected to"), !output.contains("failed"), !output.contains("unable") else {
            throw ADB.Failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
