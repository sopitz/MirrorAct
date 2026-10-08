// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Darwin
import Foundation

/// Client für den scrcpy-Server auf dem Android-Gerät (Protokoll der Version 4.1, siehe
/// doc/develop.md im scrcpy-Projekt). Der Server wird per adb auf das Gerät kopiert und gestartet,
/// verbindet sich über `adb reverse` mit einem lokalen Port und öffnet nacheinander drei Sockets:
/// Video (H.264/H.265, Annex B), Ton (AAC) und Steuerung (Eingaben hin, Zwischenablage zurück).
final class ScrcpyClient: @unchecked Sendable {
    static let serverVersion = "4.1"
    private static let devicePath = "/data/local/tmp/mirroract-server.jar"

    struct Options {
        var audio = true
        var maxFPS = 60
        var videoBitRate = 16_000_000
        var hevc = false
    }

    let serial: String
    let options: Options

    /// dekodierte Bilder (Thread des Videostroms)
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// AAC: AudioSpecificConfig, danach einzelne Pakete (Thread des Tonstroms)
    var onAudioConfig: ((Data) -> Void)?
    var onAudioPacket: ((Data) -> Void)?
    /// Zwischenablage des Geräts hat sich geändert (Thread der Steuerung)
    var onClipboard: ((String) -> Void)?
    /// auf dem Main-Thread, höchstens einmal; nil = ohne besonderen Grund getrennt
    var onStop: ((String?) -> Void)?

    private let decoder = AnnexBDecoder()
    private let writeQueue = DispatchQueue(label: "mirroract.scrcpy.control", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var serverProcess: Process?
    private var serverLog = ""
    private var sockets: [Int32] = []
    private var controlFD: Int32 = -1
    private var currentVideoSize: CGSize = .zero

    init(serial: String, options: Options) {
        self.serial = serial
        self.options = options
        decoder.onFrame = { [weak self] buffer in self?.onFrame?(buffer) }
        decoder.onError = { message in Log.error("Android video: \(message)") }
    }

    /// Grösse des Videobilds (für Eingaben, die der Server darauf bezieht)
    var videoSize: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return currentVideoSize
    }

    func start() {
        Thread.detachNewThread { [self] in
            do {
                try connect()
            } catch {
                finish(reason: error.localizedDescription)
            }
        }
    }

    /// vom Benutzer beendet: ohne Rückmeldung
    func stop() {
        onStop = nil
        finish(reason: nil)
    }

    /// Steuernachricht senden (Reihenfolge bleibt erhalten)
    func send(_ message: Data) {
        writeQueue.async { [self] in
            lock.lock()
            let fd = controlFD
            lock.unlock()
            guard fd >= 0 else { return }
            if !Self.writeAll(fd, message) {
                finish(reason: nil)
            }
        }
    }

    // MARK: Verbindungsaufbau

    private func connect() throws {
        guard let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else {
            throw ADB.Failure(message: String(localized: "The scrcpy server is missing from the app (scripts/bootstrap-scrcpy.sh)"))
        }
        try ADB.run(["push", server.path, Self.devicePath], serial: serial, timeout: 60)

        let listener = try Self.listen()
        defer { close(listener.fd) }
        let scid = Int.random(in: 0..<0x7FFF_FFFF)
        let socketName = String(format: "scrcpy_%08x", scid)
        try ADB.run(["reverse", "localabstract:\(socketName)", "tcp:\(listener.port)"], serial: serial)
        defer { _ = try? ADB.run(["reverse", "--remove", "localabstract:\(socketName)"], serial: serial, timeout: 5) }

        try launchServer(scid: scid)

        // Reihenfolge laut Protokoll: Video, Ton, Steuerung
        let video = try accept(listener.fd, timeout: 20)
        let audio = options.audio ? try accept(listener.fd, timeout: 5) : -1
        let control = try accept(listener.fd, timeout: 5)
        lock.lock()
        controlFD = control
        lock.unlock()

        if audio >= 0 {
            Thread.detachNewThread { [self] in readAudio(audio) }
        }
        Thread.detachNewThread { [self] in readControl(control) }
        readVideo(video)
    }

    private func launchServer(scid: Int) throws {
        guard let executable = ADB.executable else { throw ADB.Failure(message: String(localized: "adb not found")) }
        var arguments = ["-s", serial, "shell", "CLASSPATH=\(Self.devicePath)", "app_process", "/",
                         "com.genymobile.scrcpy.Server", Self.serverVersion,
                         String(format: "scid=%08x", scid), "log_level=info",
                         "video_codec=\(options.hevc ? "h265" : "h264")",
                         "video_bit_rate=\(options.videoBitRate)",
                         "max_fps=\(options.maxFPS)",
                         "clipboard_autosync=true"]
        arguments += options.audio ? ["audio_codec=aac"] : ["audio=false"]

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.serverLog = String((self.serverLog + text).suffix(4000))
            self.lock.unlock()
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                Log.info("Android server: \(line)")
            }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.finish(reason: self?.serverError)
        }
        try process.run()
        lock.lock()
        serverProcess = process
        lock.unlock()
    }

    /// letzte Fehlermeldung des Servers (für die Anzeige)
    private var serverError: String? {
        lock.lock()
        let log = serverLog
        lock.unlock()
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        return lines.last { $0.contains("ERROR") || $0.contains("Exception") }
            .map { $0.replacingOccurrences(of: "[server] ", with: "") }
    }

    private func accept(_ listener: Int32, timeout: TimeInterval) throws -> Int32 {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isStopped { throw ADB.Failure(message: serverError ?? String(localized: "Connection to the phone failed")) }
            let ready = poll(&pfd, 1, 200)
            if ready > 0 { break }
            if Date() > deadline {
                throw ADB.Failure(message: serverError ?? String(localized: "The phone did not respond"))
            }
        }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { throw ADB.Failure(message: "accept: \(errno)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        sockets.append(fd)
        lock.unlock()
        return fd
    }

    private static func listen() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADB.Failure(message: "socket: \(errno)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw ADB.Failure(message: "bind/listen: \(errno)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    // MARK: Ströme

    private static let codecH264: UInt32 = 0x6832_3634
    private static let codecH265: UInt32 = 0x6832_3635
    private static let codecAAC: UInt32 = 0x0061_6163
    private static let flagSession: UInt8 = 0x80
    private static let flagConfig: UInt8 = 0x40

    private func readVideo(_ fd: Int32) {
        // Gerätename (64 Byte) auf dem ersten Socket, dann die Codec-Kennung
        guard Self.read(fd, count: 64) != nil, let codec = Self.readU32(fd) else {
            finish(reason: nil)
            return
        }
        guard codec == Self.codecH264 || codec == Self.codecH265 else {
            finish(reason: codec == 1 ? serverError ?? String(localized: "The phone could not start the video") : "Video codec \(codec)")
            return
        }
        let hevc = codec == Self.codecH265
        while let header = Self.read(fd, count: 12) {
            if header[0] & Self.flagSession != 0 {
                // neue Aufnahme (Start, Drehung): Bildgrösse
                let size = CGSize(width: Int(Self.u32(header, at: 4)), height: Int(Self.u32(header, at: 8)))
                lock.lock()
                currentVideoSize = size
                lock.unlock()
                continue
            }
            let length = Int(Self.u32(header, at: 8))
            guard let payload = Self.read(fd, count: length) else { break }
            payload.withUnsafeBytes { raw in
                decoder.decode(raw.bindMemory(to: UInt8.self), hevc: hevc)
            }
        }
        finish(reason: nil)
    }

    private func readAudio(_ fd: Int32) {
        guard let codec = Self.readU32(fd) else { return }
        guard codec == Self.codecAAC else {
            // 0: Gerät liefert keinen Ton (vor Android 11 oder nicht erlaubt), 1: Fehler
            Log.info("Android audio unavailable (\(codec))")
            return
        }
        while let header = Self.read(fd, count: 12) {
            let length = Int(Self.u32(header, at: 8))
            guard let payload = Self.read(fd, count: length) else { break }
            if header[0] & Self.flagConfig != 0 {
                Log.info("Android audio: AAC, config \(payload.map { String(format: "%02x", $0) }.joined())")
                onAudioConfig?(payload)
            } else {
                onAudioPacket?(payload)
            }
        }
    }

    /// Nachrichten vom Gerät: 0 Zwischenablage, 1 Bestätigung, 2 UHID-Ausgabe
    private func readControl(_ fd: Int32) {
        while let type = Self.read(fd, count: 1)?.first {
            switch type {
            case 0:
                guard let length = Self.readU32(fd), let text = Self.read(fd, count: Int(length)) else { return }
                onClipboard?(String(decoding: text, as: UTF8.self))
            case 1:
                guard Self.read(fd, count: 8) != nil else { return }
            case 2:
                guard let head = Self.read(fd, count: 4),
                      Self.read(fd, count: Int(UInt16(head[2]) << 8 | UInt16(head[3]))) != nil else { return }
            default:
                Log.error("Android control: unknown message \(type)")
                return
            }
        }
    }

    // MARK: Ende

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func finish(reason: String?) {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let open = sockets
        sockets = []
        controlFD = -1
        let process = serverProcess
        serverProcess = nil
        let callback = onStop
        lock.unlock()

        for fd in open {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        if process?.isRunning == true { process?.terminate() }
        if let callback {
            DispatchQueue.main.async { callback(reason) }
        }
    }

    // MARK: Lesen und Schreiben

    private static func read(_ fd: Int32, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }

    private static func readU32(_ fd: Int32) -> UInt32? {
        read(fd, count: 4).map { u32($0, at: 0) }
    }

    private static func u32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
