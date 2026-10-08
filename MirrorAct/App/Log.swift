// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Log in ~/Library/Logs/MirrorAct.log und ins System-Log
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.sopitz.MirrorAct", category: "app")
    private static let queue = DispatchQueue(label: "mirroract.log")
    private static let handle: FileHandle? = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MirrorAct.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("FEHLER", message) }
    static func debug(_ message: String) {
        #if DEBUG
        write("DEBUG", message)
        #endif
    }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        queue.async {
            let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
            handle?.write(Data(line.utf8))
        }
    }
}
