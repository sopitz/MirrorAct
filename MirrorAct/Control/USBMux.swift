// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Verbindung zu einem Port auf dem iPhone über usbmuxd – derselbe Kanal, den Xcode und der
/// Finder über das Kabel nutzen. Protokoll: 16-Byte-Kopf (Länge, Version 1, Typ 8 = Plist, Tag)
/// und eine XML-Plist; nach einem erfolgreichen "Connect" ist der Socket eine rohe TCP-Leitung.
enum USBMux {
    struct Device {
        let id: Int
        let serial: String
        let isUSB: Bool
    }

    enum MuxError: LocalizedError {
        case unavailable(String)
        case refused(Int)

        var errorDescription: String? {
            switch self {
            case let .unavailable(detail): "usbmuxd: \(detail)"
            case let .refused(code): "usbmuxd: connection refused (\(code))"
            }
        }
    }

    private static let socketPath = "/var/run/usbmuxd"

    static func devices() throws -> [Device] {
        let fd = try openSocket()
        defer { close(fd) }
        let reply = try exchange(fd, ["MessageType": "ListDevices"])
        let list = reply["DeviceList"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let properties = entry["Properties"] as? [String: Any],
                  let id = (entry["DeviceID"] ?? properties["DeviceID"]) as? Int,
                  let serial = properties["SerialNumber"] as? String else { return nil }
            return Device(id: id, serial: serial, isUSB: properties["ConnectionType"] as? String == "USB")
        }
    }

    /// Gerät mit dieser UDID (Schreibweise mit oder ohne Bindestrich), per Kabel bevorzugt;
    /// über WLAN gekoppelte Geräte reicht usbmuxd ebenfalls durch
    static func device(udid: String) -> Device? {
        let wanted = normalized(udid)
        let matches = (try? devices())?.filter { normalized($0.serial) == wanted } ?? []
        return matches.first { $0.isUSB } ?? matches.first
    }

    /// offener Socket, verbunden mit `port` auf dem Gerät
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        do {
            let reply = try exchange(fd, ["MessageType": "Connect", "DeviceID": deviceID,
                                          "PortNumber": Int(port.bigEndian)])
            let code = reply["Number"] as? Int ?? -1
            guard code == 0 else { throw MuxError.refused(code) }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func normalized(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").uppercased()
    }

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MuxError.unavailable(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8.prefix(buffer.count - 1))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw MuxError.unavailable(detail)
        }
        Socket.setTimeout(fd, seconds: 5)
        return fd
    }

    private static func exchange(_ fd: Int32, _ message: [String: Any]) throws -> [String: Any] {
        var body = message
        body["ClientVersionString"] = "MirrorAct"
        body["ProgName"] = "MirrorAct"
        body["kLibUSBMuxVersion"] = 3
        let payload = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(16 + payload.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        try Socket.write(fd, header + payload)
        let head = try Socket.read(fd, count: 16)
        let length = head.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length >= 16, length < 1 << 24 else { throw MuxError.unavailable("invalid reply") }
        let reply = try Socket.read(fd, count: Int(length) - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: reply, format: nil) as? [String: Any]
        else { throw MuxError.unavailable("invalid reply") }
        return plist
    }
}

/// Blockierende Socket-Hilfen (laufen auf der Warteschlange der Steuerung)
enum Socket {
    struct Closed: LocalizedError {
        var errorDescription: String? { "connection closed" }
    }

    static func setTimeout(_ fd: Int32, seconds: Double) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { throw Closed() }
                offset += sent
            }
        }
    }

    /// genau `count` Bytes
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let got = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { throw Closed() }
                offset += got
            }
        }
        return data
    }

    /// was gerade ankommt (mindestens 1 Byte)
    static func readSome(_ fd: Int32, max: Int = 64 * 1024) throws -> Data {
        var data = Data(count: max)
        let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, max) }
        guard got > 0 else { throw Closed() }
        return data.prefix(got)
    }

    /// TCP-Verbindung mit Zeitlimit für den Aufbau
    static func connectTCP(host: String, port: UInt16, timeout: Double = 5) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { throw Closed() }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
            if !ok, errno == EINPROGRESS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                ok = poll(&poller, 1, Int32(timeout * 1000)) == 1
                    && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
            }
            if ok {
                _ = fcntl(fd, F_SETFL, flags)
                setTimeout(fd, seconds: 5)
                return fd
            }
            close(fd)
        }
        throw Closed()
    }
}
