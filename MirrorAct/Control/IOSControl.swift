// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Foundation

/// Control of an iPhone/iPad via the test agent (WebDriverAgent): launches it on the device with
/// `xcodebuild` and sends taps, swipes, text and buttons. Needs Xcode, Developer Mode on the
/// device and an agent built with your own team (scripts/build-agent.sh).
@MainActor
final class IOSControl: @preconcurrency DeviceControl {
    /// Point on the screen, 0…1 in the displayed orientation, with time since the touch began
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
    private var liveObserver: AnyCancellable?
    private var endedObserver: NSObjectProtocol?
    /// Device whose agent this control started or uses
    private var agentUDID: String? {
        didSet { if let agentUDID { lastAgentUDID = agentUDID } }
    }
    /// Device of the last agent; stays set after turning off, while the agent keeps running for a while
    private var lastAgentUDID: String?
    /// Agent taken over (AgentRunners.acquire): when turning off, only release it; it keeps running for a while
    private var holdsAgent = false
    /// set by end(): no automatic start until the device connects again
    private var ended = false

    /// current touch
    private var touchPath: [TouchPoint] = []
    private var touchStart: TimeInterval = 0
    /// current scroll (as a swipe gesture)
    private var scrollPath: [TouchPoint] = []
    private var scrollStart: TimeInterval = 0
    private var scrollFinish: DispatchWorkItem?

    init(session: MirrorSession) {
        self.session = session
        worker.onLost = { [weak self] message in
            DispatchQueue.main.async { self?.lost(message) }
        }
        endedObserver = NotificationCenter.default.addObserver(
            forName: AgentRunners.endedNotification, object: nil, queue: .main
        ) { [weak self] note in
            let udid = note.object as? String
            MainActor.assumeIsolated {
                guard let self, udid != nil, udid == self.agentUDID else { return }
                self.holdsAgent = false
                self.lost(String(localized: "the agent on the device stopped"))
            }
        }
        // start right away on connecting (first image), if set up that way
        liveObserver = session.$state.removeDuplicates().sink { [weak self] state in
            switch state {
            case .connecting: DispatchQueue.main.async { self?.ended = false }
            case .live: DispatchQueue.main.async { self?.startAutomatically() }
            case .disconnected: break
            }
        }
    }

    deinit {
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
    }

    private var isActive: Bool { state == .ready || state == .starting }

    /// Agent built with scripts/build-agent.sh?
    static var isAgentBuilt: Bool { ControlWorker.agentTestRun() != nil }

    /// Image in landscape (the agent's coordinates follow the app's orientation)
    private var landscape: Bool {
        guard let size = session?.frameSize, size != .zero else { return false }
        return size.width > size.height
    }

    /// Screen in iOS points, oriented like the image
    private var screenPoints: CGSize { session?.screenPointSize ?? CGSize(width: 390, height: 844) }

    // MARK: Start / Stop

    func start() {
        begin(automatic: false)
    }

    /// Start on connecting; if that fails (agent missing, device locked …), the "Control" button stays
    private func startAutomatically() {
        guard !ended, AppSettings.shared.autoStartControl, ControlWorker.agentTestRun() != nil else { return }
        switch state {
        case .off, .failed: begin(automatic: true)
        case .starting, .ready: break
        }
    }

    private func begin(automatic: Bool) {
        guard !isActive else { return }
        let name = session?.deviceName ?? ""
        state = .starting
        worker.start(deviceName: name, launch: { [weak self] udid, testRun, onOutput in
            // runs on the main thread
            MainActor.assumeIsolated {
                guard let self else { return nil }
                self.agentUDID = udid
                return AgentRunners.shared.launch(udid: udid, testRun: testRun, onOutput: onOutput)
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.state == .starting else { return }
                switch result {
                case let .success(udid):
                    self.agentUDID = udid
                    self.holdsAgent = AgentRunners.shared.acquire(udid: udid)
                    self.state = .ready
                    Log.info("Control ready: \(name)")
                case let .failure(error):
                    if error is CancellationError { return }
                    Log.error("Control\(automatic ? " (automatic start)" : ""): \(error.localizedDescription)")
                    self.releaseAgent()
                    // automatic: quietly fall back to the "Control" button; clicking it says what is missing
                    self.state = automatic ? .off : .failed(error.localizedDescription)
                }
            }
        })
    }

    func stop() {
        worker.stop()
        releaseAgent()
        touchPath = []
        scrollPath = []
        state = .off
    }

    /// Turn off and stop the agent right away instead of keeping it running: with the connection
    /// gone, it would stay on the device with nothing on the Mac using it
    func end() {
        let udid = agentUDID ?? lastAgentUDID
        ended = true
        stop()
        lastAgentUDID = nil
        if let udid { AgentRunners.shared.shutdown(udid: udid) }
    }

    private func lost(_ message: String) {
        guard state == .ready else { return }
        Log.error("Control lost: \(message)")
        worker.stop()
        releaseAgent()
        state = .failed(String(localized: "Control was interrupted: \(message)"))
    }

    /// a taken-over agent keeps running for a while (next start is instant), a half-started one is terminated
    private func releaseAgent() {
        guard let udid = agentUDID else { return }
        if holdsAgent {
            AgentRunners.shared.release(udid: udid)
        } else {
            AgentRunners.shared.terminate(udid: udid)
        }
        agentUDID = nil
        holdsAgent = false
    }

    // MARK: Input

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
            // at most ~80 points per second; the last point is always kept current
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
                // tap or hold (duration as with the mouse, at least 50 ms)
                send([first, TouchPoint(x: first.x, y: first.y, time: max(0.05, duration))])
            } else {
                touchPath.append(TouchPoint(x: point.x, y: point.y, time: duration))
                send(touchPath)
            }
            touchPath = []
        }
    }

    /// Trackpad and mouse wheel as a swipe gesture: sent when the fingers lift,
    /// iOS then adds the momentum itself. Phases come from the NSEvent being processed.
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
        // mouse wheel without phases: collect briefly
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

    /// dx/dy: the content moves in this direction, so the finger does too (1 point = 1 iOS point)
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
            // the agent can't type arrow and function keys
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
                // swipe up from the bottom edge and hold briefly
                send([TouchPoint(x: 0.5, y: 0.998, time: 0), TouchPoint(x: 0.5, y: 0.93, time: 0.08),
                      TouchPoint(x: 0.5, y: 0.75, time: 0.25), TouchPoint(x: 0.5, y: 0.62, time: 0.4),
                      TouchPoint(x: 0.5, y: 0.62, time: 0.85)])
            }
        case .notifications:
            send([TouchPoint(x: 0.3, y: 0.002, time: 0), TouchPoint(x: 0.3, y: 0.15, time: 0.1),
                  TouchPoint(x: 0.3, y: 0.6, time: 0.3)])
        case .back:
            // back gesture from the left edge
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

// MARK: - Background

/// Connection and command queue; everything blocking runs on `queue`
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
    /// incremented on every start/stop; old commands and starts expire
    private var generation = 0

    // only on `queue`
    private var connection: AgentConnection?
    private var sessionID: String?
    /// Screen in points, portrait
    private var screen = CGSize(width: 390, height: 844)

    // MARK: Start

    /// completion: UDID of the device whose agent the control uses
    func start(deviceName: String, launch: @escaping Launcher,
               completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        let current = bumpGeneration()
        queue.async { [self] in
            do {
                let udid = try connect(deviceName: deviceName, generation: current, launch: launch)
                completion(.success(udid))
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

    private func connect(deviceName: String, generation current: Int, launch: Launcher) throws -> String {
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

        // is the agent still running (after a window was closed or a crash)? Then connect right away.
        let knownHost = DispatchQueue.main.sync { MainActor.assumeIsolated { AgentRunners.shared.host(udid: udid) } }
        if let running = AgentConnection.routes(udid: udid, host: knownHost).lazy.map({ AgentConnection(route: $0) })
            .first(where: { $0.isAlive() }) {
            Log.info("Control: agent already running (\(running.route))")
            try openSession(running)
            return udid
        }

        // while locked, xcodebuild doesn't start the agent (and doesn't exit on its own afterwards)
        guard !DeviceInfoLookup.isLocked(udid: udid) else {
            throw StartError(message: String(localized: "Unlock the device and try again."))
        }
        guard isCurrent(current) else { throw CancellationError() }

        let started = Date()
        var serverURL: URL?
        do {
            // this build is already on the device: launch without reinstalling (saves a few seconds)
            let build = Self.agentBuildID()
            if let build, Self.installedBuild(udid: udid) == build,
               let installed = Self.installedTestRun(from: testRun, build: build) {
                do {
                    serverURL = try launchAgent(udid: udid, testRun: installed, deviceName: deviceName,
                                                generation: current, launch: launch)
                } catch let error as StartError {
                    Log.info("Control: installed agent did not start, installing it again (\(error.message))")
                    Self.setInstalledBuild(nil, udid: udid)
                }
            }
            if serverURL == nil {
                serverURL = try launchAgent(udid: udid, testRun: testRun, deviceName: deviceName,
                                            generation: current, launch: launch)
                Self.setInstalledBuild(build, udid: udid)
            }
        } catch is DeviceLocked {
            // locked only after the check above
            throw StartError(message: String(localized: "Unlock the device and try again."))
        }
        let host = serverURL?.host
        Log.info("Control: agent at \(serverURL?.absoluteString ?? "?") after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        DispatchQueue.main.async { MainActor.assumeIsolated { AgentRunners.shared.setHost(host, udid: udid) } }

        for attempt in 0..<20 {
            guard isCurrent(current) else { throw CancellationError() }
            if let connection = AgentConnection.routes(udid: udid, host: host).lazy.map({ AgentConnection(route: $0) })
                .first(where: { $0.isAlive() }) {
                try openSession(connection)
                return udid
            }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.25) }
        }
        throw StartError(message: String(localized: "The agent started, but the Mac can’t reach it."))
    }

    struct DeviceLocked: Error {}

    /// launches the agent via xcodebuild and waits for its address
    private func launchAgent(udid: String, testRun: URL, deviceName: String, generation current: Int,
                             launch: Launcher) throws -> URL {
        let output = RunnerOutput()
        let started = Date()
        // on the main thread, where stop() runs too: start nothing after a stop
        let launched: Process?? = DispatchQueue.main.sync {
            isCurrent(current) ? .some(launch(udid, testRun, { output.append($0) })) : .none
        }
        guard let launched else { throw CancellationError() }
        guard let process = launched else {
            throw StartError(message: String(localized: "Xcode (xcodebuild) could not be started."))
        }
        Log.info("Control: starting agent on \(deviceName) (\(udid))")

        while true {
            guard isCurrent(current) else { throw CancellationError() }
            if let url = output.serverURL { return url }
            if output.deviceLocked {
                Log.info("Control: device is locked")
                if process.isRunning { process.interrupt() }
                throw DeviceLocked()
            }
            if !process.isRunning || Date().timeIntervalSince(started) > 120 {
                if process.isRunning { process.interrupt() }
                Thread.sleep(forTimeInterval: 0.3)   // wait for the last output
                throw StartError(message: output.failureReason())
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
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
        // after gestures, don't wait for animations to finish
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

    private static var agentDirectory: URL {
        AppSettings.shared.supportDirectory.appendingPathComponent("Agent", isDirectory: true)
    }

    /// built agent in ~/Library/Application Support/MirrorAct/Agent
    static func agentTestRun() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: agentDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "xctestrun" }
    }

    /// ID of the built agent (scripts/build-agent.sh writes a new one on every build)
    static func agentBuildID() -> String? {
        let url = agentDirectory.appendingPathComponent("build-id")
        let id = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return id?.isEmpty == false ? id : nil
    }

    /// which build was last installed on this device
    static func installedBuild(udid: String) -> String? {
        UserDefaults.standard.string(forKey: "agentBuild.\(udid)")
    }

    static func setInstalledBuild(_ build: String?, udid: String) {
        UserDefaults.standard.set(build, forKey: "agentBuild.\(udid)")
    }

    /// Variant of the xctestrun file that launches the agent installed on the device
    /// (UseDestinationArtifacts, see `man xcodebuild.xctestrun`)
    static func installedTestRun(from testRun: URL, build: String) -> URL? {
        let dir = AppSettings.shared.supportDirectory.appendingPathComponent("AgentLaunch", isDirectory: true)
        let url = dir.appendingPathComponent("installed-\(build).xctestrun")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = try? Data(contentsOf: testRun),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        for (key, value) in plist where key != "__xctestrun_metadata__" {
            guard var target = value as? [String: Any],
                  let host = target["TestHostBundleIdentifier"] as? String,
                  let bundle = (target["TestBundlePath"] as? String)?.components(separatedBy: "/").last
            else { continue }
            for path in ["TestHostPath", "TestBundlePath", "DependentProductPaths"] { target[path] = nil }
            target["UseDestinationArtifacts"] = true
            target["TestBundleDestinationRelativePath"] = "__TESTHOST__/PlugIns/\(bundle)"
            target["UITargetAppBundleIdentifier"] = host
            plist[key] = target
        }
        // older variants belong to earlier builds
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? out.write(to: url)) != nil else { return nil }
        return url
    }

    // MARK: Commands

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
                // quickly typed text: send it together
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
                // an error during a gesture (e.g. device locked) is not a lost connection
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
            // the agent's own command (Agent/MirrorActCommands.m): without querying the UI hierarchy
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

    /// [[x, y, t]] in iOS points, t in seconds since the touch began
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

/// Output of `xcodebuild`: the agent's address and readable error messages
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

    /// xcodebuild: "Unlock … to Continue" – after that it doesn't exit on its own
    var deviceLocked: Bool {
        let all = lock.withLock { text }
        return all.contains("because the device is locked") || all.contains("com.apple.dt.deviceprep Code=-3")
    }

    var serverURL: URL? {
        let all = lock.withLock { text }
        guard let start = all.range(of: "ServerURLHere->"),
              let end = all.range(of: "<-ServerURLHere", range: start.upperBound..<all.endIndex) else { return nil }
        return URL(string: String(all[start.upperBound..<end.lowerBound]))
    }

    /// clear message for the most common errors, otherwise xcodebuild's error lines
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
