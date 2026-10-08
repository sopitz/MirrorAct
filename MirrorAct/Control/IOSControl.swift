// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Bedienung eines iPhones/iPads über den Test-Agent (WebDriverAgent): startet ihn per `xcodebuild`
/// auf dem Gerät und schickt Tippen, Wischen, Text und Tasten. Braucht Xcode, den Entwicklermodus
/// auf dem Gerät und einen mit dem eigenen Team gebauten Agent (scripts/build-agent.sh).
@MainActor
final class IOSControl: @preconcurrency DeviceControl {
    /// Punkt auf dem Bildschirm, 0…1 in der angezeigten Ausrichtung, mit Zeit seit Berührungsbeginn
    struct TouchPoint {
        var x: CGFloat
        var y: CGFloat
        var time: TimeInterval
    }

    let buttons: [DeviceButton] = [.home, .recents, .notifications, .volumeUp, .volumeDown, .power]

    private(set) var state: ControlState = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((ControlState) -> Void)?

    private weak var session: MirrorSession?
    private let worker = ControlWorker()
    private var runner: Process?
    private var terminationObserver: NSObjectProtocol?

    /// laufende Berührung
    private var touchPath: [TouchPoint] = []
    private var touchStart: TimeInterval = 0
    /// laufendes Scrollen (als Wischgeste)
    private var scrollPath: [TouchPoint] = []
    private var scrollStart: TimeInterval = 0
    private var scrollFinish: DispatchWorkItem?

    init(session: MirrorSession) {
        self.session = session
        worker.onLost = { [weak self] message in
            DispatchQueue.main.async { self?.lost(message) }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runner?.interrupt() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        runner?.interrupt()
    }

    private var isActive: Bool { state == .ready || state == .starting }

    /// Bild im Querformat (Koordinaten des Agents folgen der Ausrichtung der App)
    private var landscape: Bool {
        guard let size = session?.frameSize, size != .zero else { return false }
        return size.width > size.height
    }

    /// Bildschirm in iOS-Punkten, ausgerichtet wie das Bild
    private var screenPoints: CGSize { session?.screenPointSize ?? CGSize(width: 390, height: 844) }

    // MARK: Start / Stopp

    func start() {
        guard !isActive else { return }
        let name = session?.deviceName ?? ""
        state = .starting
        worker.start(deviceName: name, launch: { [weak self] udid, testRun, onOutput in
            // läuft auf dem Main-Thread
            MainActor.assumeIsolated { self?.launchRunner(udid: udid, testRun: testRun, onOutput: onOutput) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.state == .starting else { return }
                switch result {
                case .success:
                    self.state = .ready
                    Log.info("Control ready: \(name)")
                case let .failure(error):
                    if error is CancellationError { return }
                    Log.error("Control: \(error.localizedDescription)")
                    self.stopRunner()
                    self.state = .failed(error.localizedDescription)
                }
            }
        })
    }

    func stop() {
        worker.stop()
        stopRunner()
        touchPath = []
        scrollPath = []
        state = .off
    }

    private func lost(_ message: String) {
        guard state == .ready else { return }
        Log.error("Control lost: \(message)")
        worker.stop()
        stopRunner()
        state = .failed(String(localized: "Control was interrupted: \(message)"))
    }

    private func launchRunner(udid: String, testRun: URL, onOutput: @escaping @Sendable (String) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "test-without-building", "-xctestrun", testRun.path,
                             "-destination", "id=\(udid)", "-destination-timeout", "30"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                onOutput(String(decoding: data, as: UTF8.self))
            }
        }
        let worker = self.worker
        process.terminationHandler = { [weak self] finished in
            Log.info("Control agent ended (\(finished.terminationStatus))")
            worker.runnerEnded()
            DispatchQueue.main.async {
                guard let self, self.runner === finished else { return }
                self.runner = nil
                if self.state == .ready { self.lost(String(localized: "the agent on the device stopped")) }
            }
        }
        do {
            try process.run()
        } catch {
            Log.error("xcodebuild: \(error.localizedDescription)")
            return nil
        }
        runner = process
        return process
    }

    private func stopRunner() {
        guard let runner else { return }
        self.runner = nil
        if runner.isRunning { runner.interrupt() }
    }

    // MARK: Eingaben

    func touch(_ phase: TouchPhase, at point: CGPoint) {
        guard state == .ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch phase {
        case .began:
            touchStart = now
            touchPath = [TouchPoint(x: point.x, y: point.y, time: 0)]
        case .moved:
            guard !touchPath.isEmpty else { return }
            let sample = TouchPoint(x: point.x, y: point.y, time: now - touchStart)
            // höchstens ~80 Punkte pro Sekunde; der letzte Punkt bleibt immer aktuell
            if touchPath.count > 1, sample.time - touchPath[touchPath.count - 2].time < 0.012 {
                touchPath[touchPath.count - 1] = sample
            } else {
                touchPath.append(sample)
            }
        case .ended:
            guard let first = touchPath.first else { return }
            let duration = now - touchStart
            let points = screenPoints
            let moved = touchPath.map { hypot(($0.x - first.x) * points.width, ($0.y - first.y) * points.height) }
                .max() ?? 0
            let distance = max(moved, hypot((point.x - first.x) * points.width, (point.y - first.y) * points.height))
            if distance < 8 {
                // Tippen oder Halten (Dauer wie mit der Maus, mindestens 50 ms)
                send([first, TouchPoint(x: first.x, y: first.y, time: max(0.05, duration))])
            } else {
                touchPath.append(TouchPoint(x: point.x, y: point.y, time: duration))
                send(touchPath)
            }
            touchPath = []
        }
    }

    /// Trackpad und Mausrad als Wischgeste: beim Loslassen der Finger abgeschickt,
    /// iOS rollt dann selbst nach. Phasen kommen aus dem gerade verarbeiteten NSEvent.
    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, precise: Bool) {
        guard state == .ready else { return }
        if let event = NSApp.currentEvent, event.type == .scrollWheel,
           !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) || scrollPath.isEmpty {
                beginScroll(at: point)
            }
            if event.phase.contains(.changed) { addScroll(dx, dy) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { finishScroll() }
            return
        }
        // Mausrad ohne Phasen: kurz sammeln
        if scrollPath.isEmpty { beginScroll(at: point) }
        let factor: CGFloat = precise ? 1 : 40
        addScroll(dx * factor, dy * factor)
        scrollFinish?.cancel()
        let finish = DispatchWorkItem { [weak self] in self?.finishScroll() }
        scrollFinish = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: finish)
    }

    private func beginScroll(at point: CGPoint) {
        scrollStart = ProcessInfo.processInfo.systemUptime
        scrollPath = [TouchPoint(x: point.x, y: point.y, time: 0)]
    }

    /// dx/dy: Inhalt bewegt sich in diese Richtung, also auch der Finger (1 Punkt = 1 iOS-Punkt)
    private func addScroll(_ dx: CGFloat, _ dy: CGFloat) {
        guard let last = scrollPath.last, dx != 0 || dy != 0 else { return }
        let points = screenPoints
        let x = min(0.98, max(0.02, last.x + dx / max(1, points.width)))
        let y = min(0.98, max(0.02, last.y + dy / max(1, points.height)))
        let time = ProcessInfo.processInfo.systemUptime - scrollStart
        if scrollPath.count > 1, time - scrollPath[scrollPath.count - 2].time < 0.012 {
            scrollPath[scrollPath.count - 1] = TouchPoint(x: x, y: y, time: time)
        } else {
            scrollPath.append(TouchPoint(x: x, y: y, time: time))
        }
    }

    private func finishScroll() {
        scrollFinish?.cancel()
        scrollFinish = nil
        defer { scrollPath = [] }
        guard scrollPath.count > 1, let first = scrollPath.first, let last = scrollPath.last else { return }
        let points = screenPoints
        guard hypot((last.x - first.x) * points.width, (last.y - first.y) * points.height) >= 4 else { return }
        send(scrollPath)
    }

    func key(_ event: NSEvent) -> Bool {
        guard state == .ready, event.type == .keyDown else { return false }
        let text: String
        switch event.keyCode {
        case 51: text = "\u{8}"           // ⌫
        case 117: text = "\u{7F}"         // ⌦
        case 36, 76: text = "\n"          // Return, Enter
        case 48: text = "\t"
        case 53: return false             // Esc
        default:
            guard let characters = event.characters, !characters.isEmpty else { return false }
            // Pfeil- und Funktionstasten kann der Agent nicht tippen
            let printable = characters.unicodeScalars.filter { scalar in
                !(0xF700...0xF8FF).contains(scalar.value) && scalar.value >= 0x20 && scalar.value != 0x7F
            }
            guard !printable.isEmpty else { return false }
            text = String(String.UnicodeScalarView(printable))
        }
        worker.enqueue(.text(text))
        return true
    }

    func paste(_ text: String) {
        guard state == .ready, !text.isEmpty else { return }
        worker.enqueue(.text(text))
    }

    func press(_ button: DeviceButton) {
        guard state == .ready else { return }
        switch button {
        case .home: worker.enqueue(.button("home"))
        case .volumeUp: worker.enqueue(.button("volumeup"))
        case .volumeDown: worker.enqueue(.button("volumedown"))
        case .power: worker.enqueue(.power)
        case .recents:
            if session?.profile.homeButton == true {
                worker.enqueue(.doubleHome)
            } else {
                // vom unteren Rand nach oben wischen und kurz halten
                send([TouchPoint(x: 0.5, y: 0.998, time: 0), TouchPoint(x: 0.5, y: 0.93, time: 0.08),
                      TouchPoint(x: 0.5, y: 0.75, time: 0.25), TouchPoint(x: 0.5, y: 0.62, time: 0.4),
                      TouchPoint(x: 0.5, y: 0.62, time: 0.85)])
            }
        case .notifications:
            send([TouchPoint(x: 0.3, y: 0.002, time: 0), TouchPoint(x: 0.3, y: 0.15, time: 0.1),
                  TouchPoint(x: 0.3, y: 0.6, time: 0.3)])
        case .back:
            // Zurück-Geste vom linken Rand
            send([TouchPoint(x: 0.002, y: 0.5, time: 0), TouchPoint(x: 0.15, y: 0.5, time: 0.08),
                  TouchPoint(x: 0.7, y: 0.5, time: 0.3)])
        case .rotate:
            break
        }
    }

    private func send(_ path: [TouchPoint]) {
        guard !path.isEmpty else { return }
        worker.enqueue(.touch(path, landscape: landscape))
    }
}

// MARK: - Hintergrund

/// Verbindung und Befehlswarteschlange; alles Blockierende läuft auf `queue`
private final class ControlWorker: @unchecked Sendable {
    enum Command {
        case touch([IOSControl.TouchPoint], landscape: Bool)
        case text(String)
        case button(String)
        case doubleHome
        case power
    }

    struct StartError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    typealias Launcher = (_ udid: String, _ testRun: URL, _ onOutput: @escaping @Sendable (String) -> Void) -> Process?

    var onLost: ((String) -> Void)?

    private let queue = DispatchQueue(label: "mirroract.control", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [Command] = []
    private var draining = false
    /// erhöht bei jedem Start/Stopp; alte Befehle und Starts verfallen
    private var generation = 0
    private var runnerRunning = false

    // nur auf `queue`
    private var connection: AgentConnection?
    private var sessionID: String?
    /// Bildschirm in Punkten, Hochformat
    private var screen = CGSize(width: 390, height: 844)

    // MARK: Start

    func start(deviceName: String, launch: @escaping Launcher,
               completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let current = bumpGeneration()
        queue.async { [self] in
            do {
                try connect(deviceName: deviceName, generation: current, launch: launch)
                completion(.success(()))
            } catch {
                connection?.disconnect()
                connection = nil
                completion(.failure(error))
            }
        }
    }

    func stop() {
        _ = bumpGeneration()
        queue.async { [self] in
            connection?.disconnect()
            connection = nil
            sessionID = nil
        }
    }

    func runnerEnded() {
        lock.withLock { runnerRunning = false }
    }

    private func bumpGeneration() -> Int {
        lock.withLock {
            generation += 1
            pending.removeAll()
            return generation
        }
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.withLock { generation == value }
    }

    private func connect(deviceName: String, generation current: Int, launch: Launcher) throws {
        guard let testRun = Self.agentTestRun() else {
            throw StartError(message: String(localized: "The control agent is not built yet. In the MirrorAct folder, run: scripts/build-agent.sh"))
        }
        let known = DeviceInfoLookup.devices()
        guard let device = known.first(where: { $0.name == deviceName }) ?? (known.count == 1 ? known.first : nil),
              let udid = device.udid else {
            throw StartError(message: String(localized: "Xcode doesn’t know “\(deviceName)” yet. Connect it by cable once, unlock it and trust this Mac."))
        }
        guard device.developerModeEnabled else {
            throw StartError(message: String(localized: "Turn on Developer Mode on the device: Settings → Privacy & Security → Developer Mode. The device restarts; confirm afterwards."))
        }
        guard isCurrent(current) else { throw CancellationError() }

        // läuft der Agent schon (z. B. nach einem Absturz von MirrorAct)? Dann direkt verbinden.
        if let mux = USBMux.device(udid: udid) {
            let candidate = AgentConnection(route: .usbmux(mux))
            if candidate.isAlive() {
                Log.info("Control: agent already running")
                try openSession(candidate)
                return
            }
        }

        let output = RunnerOutput()
        let started = Date()
        lock.withLock { runnerRunning = true }
        // auf dem Main-Thread, wo auch stop() läuft: nach einem Stopp nichts mehr starten
        let launched: Process?? = DispatchQueue.main.sync {
            isCurrent(current) ? .some(launch(udid, testRun, { output.append($0) })) : .none
        }
        guard let launched else { throw CancellationError() }
        guard launched != nil else {
            throw StartError(message: String(localized: "Xcode (xcodebuild) could not be started."))
        }
        Log.info("Control: starting agent on \(deviceName) (\(udid))")

        var serverURL: URL?
        while serverURL == nil {
            guard isCurrent(current) else { throw CancellationError() }
            serverURL = output.serverURL
            if serverURL != nil { break }
            let running = lock.withLock { runnerRunning }
            if !running || Date().timeIntervalSince(started) > 120 {
                throw StartError(message: output.failureReason())
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Log.info("Control: agent at \(serverURL!.absoluteString) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")

        // usbmuxd (Kabel, sonst WLAN-Kopplung), sonst direkt an die Adresse, die der Agent meldet
        var routes: [AgentConnection.Route] = []
        if let mux = USBMux.device(udid: udid) { routes.append(.usbmux(mux)) }
        if let host = serverURL?.host { routes.append(.network(host: host)) }
        for attempt in 0..<20 {
            guard isCurrent(current) else { throw CancellationError() }
            if let connection = routes.lazy.map({ AgentConnection(route: $0) }).first(where: { $0.isAlive() }) {
                try openSession(connection)
                return
            }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.25) }
        }
        throw StartError(message: String(localized: "The agent started, but the Mac can’t reach it."))
    }

    private func openSession(_ connection: AgentConnection) throws {
        let capabilities: [String: Any] = [
            "shouldWaitForQuiescence": false,
            "waitForIdleTimeout": 0,
            "disableAutomaticScreenshots": true,
            "maxTypingFrequency": 60,
        ]
        let session = try connection.request("POST", "/session",
                                             body: ["capabilities": ["alwaysMatch": capabilities]], timeout: 60)
        guard let id = (session as? [String: Any])?["sessionId"] as? String else {
            throw StartError(message: String(localized: "The agent did not open a session."))
        }
        // nach Gesten nicht auf das Ende von Animationen warten
        try connection.request("POST", "/session/\(id)/appium/settings", body: ["settings": [
            "animationCoolOffTimeout": 0,
            "waitForIdleTimeout": 0,
        ]])
        if let size = try? connection.request("GET", "/session/\(id)/window/size") as? [String: Any],
           let width = size["width"] as? Double, let height = size["height"] as? Double, width > 0, height > 0 {
            screen = CGSize(width: min(width, height), height: max(width, height))
        }
        Log.info("Control: session \(id) via \(connection.route), screen \(Int(screen.width))×\(Int(screen.height)) pt")
        self.connection = connection
        sessionID = id
    }

    /// gebauter Agent in ~/Library/Application Support/MirrorAct/Agent
    static func agentTestRun() -> URL? {
        let dir = AppSettings.shared.supportDirectory.appendingPathComponent("Agent", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "xctestrun" }
    }

    // MARK: Befehle

    func enqueue(_ command: Command) {
        let start = lock.withLock {
            pending.append(command)
            defer { draining = true }
            return !draining
        }
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let next: (Command, Int)? = lock.withLock {
                guard !pending.isEmpty else {
                    draining = false
                    return nil
                }
                var command = pending.removeFirst()
                // schnell getippter Text: zusammen schicken
                if case var .text(text) = command {
                    while case let .text(more)? = pending.first {
                        text += more
                        pending.removeFirst()
                    }
                    command = .text(text)
                }
                return (command, generation)
            }
            guard let (command, current) = next else { return }
            guard let connection, let sessionID else { continue }
            let started = Date()
            do {
                try execute(command, connection: connection, session: sessionID)
                Log.debug("Control: \(command.name) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch {
                guard isCurrent(current) else { continue }
                // ein Fehler bei einer Geste (z. B. Gerät gesperrt) ist kein Verbindungsabbruch
                if connection.isAlive() {
                    Log.error("Control: \(command.name) failed: \(error.localizedDescription)")
                } else {
                    onLost?(error.localizedDescription)
                }
            }
        }
    }

    private func execute(_ command: Command, connection: AgentConnection, session: String) throws {
        switch command {
        case let .touch(path, landscape):
            // eigener Befehl des Agents (Agent/MirrorActCommands.m): ohne Abfrage der Bedienungshierarchie
            let size = landscape ? CGSize(width: screen.height, height: screen.width) : screen
            try connection.request("POST", "/mirroract/touch",
                                   body: ["landscape": landscape, "points": Self.points(path, size: size)])
        case let .text(text):
            try connection.request("POST", "/session/\(session)/wda/keys", body: ["value": [text]])
        case let .button(name):
            try connection.request("POST", "/session/\(session)/wda/pressButton", body: ["name": name])
        case .doubleHome:
            try connection.request("POST", "/session/\(session)/wda/pressButton", body: ["name": "home"])
            try connection.request("POST", "/session/\(session)/wda/pressButton", body: ["name": "home"])
        case .power:
            let locked = try connection.request("GET", "/wda/locked") as? Bool ?? false
            try connection.request("POST", locked ? "/wda/unlock" : "/wda/lock")
        }
    }

    /// [[x, y, t]] in iOS-Punkten, t in Sekunden ab Berührungsbeginn
    static func points(_ path: [IOSControl.TouchPoint], size: CGSize) -> [[Double]] {
        path.map { point in
            let x = min(max(point.x, 0), 1) * size.width, y = min(max(point.y, 0), 1) * size.height
            return [(x * 10).rounded() / 10, (y * 10).rounded() / 10, (point.time * 1000).rounded() / 1000]
        }
    }
}

private extension ControlWorker.Command {
    var name: String {
        switch self {
        case let .touch(path, _): path.count <= 2 ? "tap" : "gesture (\(path.count) points)"
        case let .text(text): "text (\(text.count))"
        case let .button(name): "button \(name)"
        case .doubleHome: "app switcher"
        case .power: "lock/unlock"
        }
    }
}

/// Ausgabe von `xcodebuild`: Adresse des Agents und lesbare Fehlermeldungen
private final class RunnerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MirrorAct-Agent.log")

    init() {
        try? Data().write(to: Self.logURL)
    }

    func append(_ chunk: String) {
        lock.withLock { text += chunk }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(chunk.utf8))
            try? handle.close()
        }
    }

    var serverURL: URL? {
        let all = lock.withLock { text }
        guard let start = all.range(of: "ServerURLHere->"),
              let end = all.range(of: "<-ServerURLHere", range: start.upperBound..<all.endIndex) else { return nil }
        return URL(string: String(all[start.upperBound..<end.lowerBound]))
    }

    /// verständliche Meldung für die häufigsten Fehler, sonst die Fehlerzeilen von xcodebuild
    func failureReason() -> String {
        let all = lock.withLock { text }
        let lower = all.lowercased()
        if lower.contains("developer mode") {
            return String(localized: "Turn on Developer Mode on the device: Settings → Privacy & Security → Developer Mode. The device restarts; confirm afterwards.")
        }
        if lower.contains("ui automation") {
            return String(localized: "Turn on UI automation on the device: Settings → Developer → Enable UI Automation.")
        }
        if lower.contains("not been explicitly trusted") || lower.contains("untrusted developer") {
            return String(localized: "Trust the developer certificate on the device: Settings → General → VPN & Device Management.")
        }
        if lower.contains("is locked") || lower.contains("passcode") {
            return String(localized: "Unlock the device and try again.")
        }
        if lower.contains("unable to find a destination") || lower.contains("unable to find a device") {
            return String(localized: "Xcode can’t reach the device. Connect it by cable and unlock it.")
        }
        let lines = all.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let l = line.lowercased()
                return l.hasPrefix("error") || l.contains("error domain") || l.contains("failure reason")
                    || l.contains("not supported") || l.hasPrefix("reason")
            }
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }.prefix(3)
        let detail = unique.isEmpty ? String(localized: "no details") : unique.joined(separator: "\n")
        return String(localized: "The agent could not be started on the device:\n\(detail)\n\nFull output: ~/Library/Logs/MirrorAct-Agent.log")
    }
}
