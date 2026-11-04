// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Running agents (`xcodebuild test-without-building`) per device. After control is turned off
/// or the window is closed, an agent keeps running for a while so the next control session is
/// ready right away; when the connection to the device ends, it stops at once (`shutdown`).
/// Quitting MirrorAct stops them all.
@MainActor
final class AgentRunners {
    static let shared = AgentRunners()
    /// how long an agent keeps running without a window
    static let keepAlive: TimeInterval = 5 * 60
    /// object: UDID of the device whose agent ended
    static let endedNotification = Notification.Name("io.github.sopitz.MirrorAct.agentEnded")

    private struct Entry {
        let process: Process
        /// Address the agent reports (for devices usbmuxd doesn't know)
        var host: String?
        var users = 0
        var idleTimer: Timer?
    }

    private var entries: [String: Entry] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    /// launches the agent; one still running for the same device is terminated first
    func launch(udid: String, testRun: URL, onOutput: @escaping @Sendable (String) -> Void) -> Process? {
        terminate(udid: udid)
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
        process.terminationHandler = { [weak self] finished in
            Log.info("Control agent ended (\(finished.terminationStatus))")
            DispatchQueue.main.async {
                guard let self, self.entries[udid]?.process === finished else { return }
                self.entries[udid]?.idleTimer?.invalidate()
                self.entries[udid] = nil
                NotificationCenter.default.post(name: Self.endedNotification, object: udid)
            }
        }
        do {
            try process.run()
        } catch {
            Log.error("xcodebuild: \(error.localizedDescription)")
            return nil
        }
        entries[udid] = Entry(process: process)
        // the timeout runs until someone takes it over (acquire)
        scheduleIdle(udid: udid)
        return process
    }

    func setHost(_ host: String?, udid: String) {
        entries[udid]?.host = host
    }

    /// Address of a running agent for this device
    func host(udid: String) -> String? {
        entries[udid]?.host
    }

    /// Control uses the agent; false = MirrorAct didn't launch it (e.g. an earlier run)
    @discardableResult
    func acquire(udid: String) -> Bool {
        guard entries[udid] != nil else { return false }
        entries[udid]?.users += 1
        entries[udid]?.idleTimer?.invalidate()
        entries[udid]?.idleTimer = nil
        return true
    }

    /// Control no longer needs the agent: keep it running for `keepAlive`
    func release(udid: String) {
        guard let entry = entries[udid] else { return }
        entries[udid]?.users = max(0, entry.users - 1)
        if entries[udid]?.users == 0 { scheduleIdle(udid: udid) }
    }

    /// terminate right away (start cancelled or failed)
    func terminate(udid: String) {
        guard let entry = entries.removeValue(forKey: udid) else { return }
        entry.idleTimer?.invalidate()
        if entry.process.isRunning { entry.process.interrupt() }
    }

    /// The connection to the device ended: stop its agent now instead of keeping it running, unless
    /// another window still uses it. The agent is asked to quit as well, so this also stops one
    /// that MirrorAct didn't launch (earlier run) or whose xcodebuild no longer reaches the device.
    func shutdown(udid: String) {
        let entry = entries[udid]
        guard (entry?.users ?? 0) == 0 else { return }
        entries[udid] = nil
        entry?.idleTimer?.invalidate()
        let host = entry?.host, process = entry?.process
        DispatchQueue.global(qos: .utility).async {
            var asked = false
            for route in AgentConnection.routes(udid: udid, host: host) {
                do {
                    try AgentConnection(route: route).request("GET", "/wda/shutdown", timeout: 3, retry: false)
                    Log.info("Control: agent asked to quit (\(route))")
                    asked = true
                    break
                } catch {
                    continue
                }
            }
            // once the agent quits, xcodebuild finishes the test run by itself; interrupting it
            // right away cuts off its result bundle, so only do that if it doesn't exit in time
            if asked, let process {
                let deadline = Date().addingTimeInterval(10)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            }
            if process?.isRunning == true { process?.interrupt() }
        }
    }

    private func scheduleIdle(udid: String) {
        entries[udid]?.idleTimer?.invalidate()
        entries[udid]?.idleTimer = Timer.scheduledTimer(withTimeInterval: Self.keepAlive, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.entries[udid]?.users == 0 else { return }
                Log.info("Control: agent idle for \(Int(Self.keepAlive)) s, stopping")
                self.terminate(udid: udid)
            }
        }
    }

    private func terminateAll() {
        for udid in Array(entries.keys) { terminate(udid: udid) }
    }
}
