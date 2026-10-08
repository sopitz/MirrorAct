// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// HTTP/1.1 zum Agent (WebDriverAgent) auf dem Gerät, über das Kabel (usbmuxd) oder WLAN.
/// Blockierend und nicht threadsicher: nur von der Warteschlange der Steuerung aus benutzen.
final class AgentConnection {
    enum Route: CustomStringConvertible {
        /// über usbmuxd (Kabel oder WLAN-Kopplung)
        case usbmux(USBMux.Device)
        /// direkt per TCP
        case network(host: String)

        var description: String {
            switch self {
            case let .usbmux(device): device.isUSB ? "USB" : "usbmuxd (Wi-Fi)"
            case let .network(host): "Wi-Fi (\(host))"
            }
        }
    }

    struct AgentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let port: UInt16 = 8100

    let route: Route
    private var fd: Int32 = -1

    init(route: Route) {
        self.route = route
    }

    deinit { disconnect() }

    func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Antwortet der Agent? (kurzer Versuch, ohne Wiederholung)
    func isAlive() -> Bool {
        (try? request("GET", "/status", timeout: 3, retry: false)) != nil
    }

    /// führt einen Befehl aus und liefert "value" der JSON-Antwort
    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                 timeout: Double = 20, retry: Bool = true) throws -> Any? {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(payload.count)\r\n\r\n"
        let message = Data(head.utf8) + payload

        let response: (status: Int, body: Data)
        do {
            response = try roundTrip(message, timeout: timeout)
        } catch where retry {
            // Keep-alive-Verbindung kann inzwischen geschlossen sein: einmal neu verbinden
            disconnect()
            response = try roundTrip(message, timeout: timeout)
        }

        let json = response.body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: response.body)
        let value = (json as? [String: Any])?["value"]
        if response.status >= 400 {
            let detail = (value as? [String: Any])?["message"] as? String ?? "HTTP \(response.status)"
            throw AgentError(message: detail)
        }
        return value
    }

    private func open() throws {
        guard fd < 0 else { return }
        switch route {
        case let .usbmux(device):
            fd = try USBMux.connect(deviceID: device.id, port: Self.port)
        case let .network(host):
            fd = try Socket.connectTCP(host: host, port: Self.port)
        }
    }

    private func roundTrip(_ message: Data, timeout: Double) throws -> (status: Int, body: Data) {
        try open()
        Socket.setTimeout(fd, seconds: timeout)
        do {
            try Socket.write(fd, message)
            return try readResponse()
        } catch {
            disconnect()
            throw error
        }
    }

    private func readResponse() throws -> (status: Int, body: Data) {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            buffer += try Socket.readSome(fd)
            headerEnd = buffer.range(of: separator)
            guard buffer.count < 1 << 20 else { throw AgentError(message: "invalid response") }
        }
        let headerText = String(decoding: buffer[..<headerEnd!.lowerBound], as: UTF8.self)
        var rest = Data(buffer[headerEnd!.upperBound...])

        let lines = headerText.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        if let length = headers["content-length"].flatMap(Int.init) {
            if rest.count < length { rest += try Socket.read(fd, count: length - rest.count) }
            return (status, rest.prefix(length))
        }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            return (status, try readChunked(rest))
        }
        // ohne Länge: bis die Gegenstelle schliesst
        while let more = try? Socket.readSome(fd) { rest += more }
        disconnect()
        return (status, rest)
    }

    private func readChunked(_ start: Data) throws -> Data {
        var pending = start
        var body = Data()
        let newline = Data("\r\n".utf8)
        while true {
            while pending.range(of: newline) == nil { pending += try Socket.readSome(fd) }
            let lineEnd = pending.range(of: newline)!
            let sizeText = String(decoding: pending[..<lineEnd.lowerBound], as: UTF8.self)
            let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16) ?? 0
            pending = Data(pending[lineEnd.upperBound...])
            if pending.count < size + 2 { pending += try Socket.read(fd, count: size + 2 - pending.count) }
            if size == 0 { return body }
            body += pending.prefix(size)
            pending = Data(pending.dropFirst(size + 2))
        }
    }
}
