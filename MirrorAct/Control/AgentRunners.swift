// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

/// Laufende Agents (`xcodebuild test-without-building`) je Gerät. Nach dem Ausschalten der
/// Bedienung oder dem Schliessen des Fensters läuft ein Agent noch eine Weile weiter, damit die
/// nächste Bedienung sofort bereit ist; beim Beenden von MirrorAct werden alle gestoppt.
@MainActor
final class AgentRunners {
    static let shared = AgentRunners()
    /// so lange läuft ein Agent ohne Fenster weiter
    static let keepAlive: TimeInterval = 5 * 60
    /// object: UDID des Geräts, dessen Agent beendet wurde
    static let endedNotification = Notification.Name("io.github.sopitz.MirrorAct.agentEnded")

    private struct Entry {
        let process: Process
        /// Adresse, die der Agent meldet (für Geräte, die usbmuxd nicht kennt)
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

    /// startet den Agent; ein noch laufender für dasselbe Gerät wird vorher beendet
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
        // bis jemand ihn übernimmt (acquire), läuft die Frist
        scheduleIdle(udid: udid)
        return process
    }

    func setHost(_ host: String?, udid: String) {
        entries[udid]?.host = host
    }

    /// Adresse eines laufenden Agents für dieses Gerät
    func host(udid: String) -> String? {
        entries[udid]?.host
    }

    /// Bedienung nutzt den Agent; false = MirrorAct hat ihn nicht gestartet (z. B. früherer Lauf)
    @discardableResult
    func acquire(udid: String) -> Bool {
        guard entries[udid] != nil else { return false }
        entries[udid]?.users += 1
        entries[udid]?.idleTimer?.invalidate()
        entries[udid]?.idleTimer = nil
        return true
    }

    /// Bedienung braucht den Agent nicht mehr: noch `keepAlive` laufen lassen
    func release(udid: String) {
        guard let entry = entries[udid] else { return }
        entries[udid]?.users = max(0, entry.users - 1)
        if entries[udid]?.users == 0 { scheduleIdle(udid: udid) }
    }

    /// sofort beenden (Start abgebrochen oder fehlgeschlagen)
    func terminate(udid: String) {
        guard let entry = entries.removeValue(forKey: udid) else { return }
        entry.idleTimer?.invalidate()
        if entry.process.isRunning { entry.process.interrupt() }
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
