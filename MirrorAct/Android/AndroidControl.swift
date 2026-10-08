// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Bedienung eines Android-Geräts: Maus, Trackpad und Tastatur als Steuernachrichten des
/// scrcpy-Servers (Format: app/src/control_msg.c im scrcpy-Projekt, alles Big Endian).
final class AndroidControl: DeviceControl {
    private let client: ScrcpyClient
    private let samsung: Bool
    private var clipboardSequence: UInt64 = 0
    let buttons: [DeviceButton]

    init(client: ScrcpyClient, info: AndroidDeviceInfo?) {
        self.client = client
        samsung = info?.manufacturer?.lowercased() == "samsung"
        // wie die Navigationsleiste des Telefons: Samsung standardmässig Apps | Home | Zurück (umstellbar)
        let navigation: [DeviceButton] = samsung && info?.samsungKeyOrder != 1
            ? [.recents, .home, .back] : [.back, .home, .recents]
        buttons = navigation + [.notifications, .volumeUp, .volumeDown, .power, .rotate]
    }

    /// Symbole wie auf dem Telefon: Samsung «|||  ▢  <», sonst Android-Standard «◁  ○  □»
    func glyph(for button: DeviceButton) -> DeviceButton.Glyph {
        switch (samsung, button) {
        case (true, .recents): DeviceButton.Glyph(symbol: "line.3.horizontal", rotation: 90)
        case (true, .home): DeviceButton.Glyph(symbol: "app")
        case (true, .back): DeviceButton.Glyph(symbol: "chevron.backward")
        case (false, .back): DeviceButton.Glyph(symbol: "arrowtriangle.backward")
        case (false, .home): DeviceButton.Glyph(symbol: "circle")
        case (false, .recents): DeviceButton.Glyph(symbol: "square")
        default: DeviceButton.Glyph(symbol: button.symbol)
        }
    }
    /// immer bedienbar, solange die Verbindung steht
    let startsOnDemand = false

    // MARK: Berührung und Scrollen

    /// "Finger" statt Maus: Android behandelt die Eingabe wie eine Berührung des Bildschirms
    private static let fingerPointer = UInt64(bitPattern: -2)

    func touch(_ phase: TouchPhase, at point: CGPoint) {
        guard let position = position(point) else { return }
        let action: UInt8, pressure: UInt16, buttons: UInt32
        switch phase {
        case .began: (action, pressure, buttons) = (0, 0xFFFF, 1)   // ACTION_DOWN
        case .moved: (action, pressure, buttons) = (2, 0xFFFF, 1)   // ACTION_MOVE
        case .ended: (action, pressure, buttons) = (1, 0, 0)        // ACTION_UP
        }
        var message = Message(type: 2)
        message.u8(action)
        message.u64(Self.fingerPointer)
        message.append(position)
        message.u16(pressure)
        message.u32(1)          // action button: primär
        message.u32(buttons)
        client.send(message.data)
    }

    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, precise: Bool) {
        guard let position = position(point) else { return }
        // wie SDL: präzise Trackpad-Werte (Punkte) auf Rad-Schritte verkleinern
        let factor: CGFloat = precise ? 0.1 : 1
        func fixed(_ value: CGFloat) -> UInt16 {
            let normalized = max(-1, min(1, value * factor / 16))
            return UInt16(bitPattern: Int16(max(-0x8000, min(0x7FFF, (normalized * 0x8000).rounded()))))
        }
        var message = Message(type: 3)
        message.append(position)
        message.u16(fixed(dx))
        message.u16(fixed(dy))
        message.u32(0)
        client.send(message.data)
    }

    /// Punkt (0…1) → Pixel im Videobild + Bildgrösse; der Server verwirft Ereignisse zu einer alten Grösse
    private func position(_ point: CGPoint) -> Message.Position? {
        let size = client.videoSize
        guard size.width > 0, size.height > 0 else { return nil }
        let x = Int32(max(0, min(size.width - 1, (point.x * size.width).rounded(.down))))
        let y = Int32(max(0, min(size.height - 1, (point.y * size.height).rounded(.down))))
        return Message.Position(x: x, y: y, width: UInt16(size.width), height: UInt16(size.height))
    }

    // MARK: Tasten

    func press(_ button: DeviceButton) {
        switch button {
        case .back:
            // zurück, oder Bildschirm einschalten, wenn er aus ist
            for action: UInt8 in [0, 1] {
                var message = Message(type: 4)
                message.u8(action)
                client.send(message.data)
            }
        case .home: tap(keycode: 3)
        case .recents: tap(keycode: 187)
        case .volumeUp: tap(keycode: 24)
        case .volumeDown: tap(keycode: 25)
        case .power: tap(keycode: 26)
        case .notifications: client.send(Message(type: 5).data)
        case .rotate: client.send(Message(type: 11).data)
        }
    }

    private func tap(keycode: UInt32) {
        sendKey(keycode, down: true, repeat: 0, meta: 0)
        sendKey(keycode, down: false, repeat: 0, meta: 0)
    }

    private func sendKey(_ keycode: UInt32, down: Bool, repeat: UInt32, meta: UInt32) {
        var message = Message(type: 0)
        message.u8(down ? 0 : 1)
        message.u32(keycode)
        message.u32(`repeat`)
        message.u32(meta)
        client.send(message.data)
    }

    func key(_ event: NSEvent) -> Bool {
        let down = event.type == .keyDown
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { return false }
        var meta: UInt32 = 0
        if flags.contains(.shift) { meta |= 0x41 }      // META_SHIFT_ON | META_SHIFT_LEFT_ON
        if flags.contains(.option) { meta |= 0x12 }     // META_ALT_ON | META_ALT_LEFT_ON
        if flags.contains(.control) { meta |= 0x3000 }  // META_CTRL_ON | META_CTRL_LEFT_ON

        if let keycode = Self.specialKeys[event.keyCode] {
            sendKey(keycode, down: down, repeat: event.isARepeat ? 1 : 0, meta: meta)
            return true
        }
        // ⌃ + Buchstabe/Ziffer (z. B. ⌃A) als Tastencode
        if flags.contains(.control), let char = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
           let keycode = Self.keycode(for: char) {
            sendKey(keycode, down: down, repeat: event.isARepeat ? 1 : 0, meta: meta)
            return true
        }
        // alles andere als Text: Umlaute und Sonderzeichen so, wie sie die Mac-Tastatur liefert
        guard let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control
                                                     || (0xF700...0xF8FF).contains($0.value) }) else { return false }
        if down {
            var message = Message(type: 1)
            message.string(text)
            client.send(message.data)
        }
        return true
    }

    /// macOS-Tastencode → Android-Tastencode
    private static let specialKeys: [UInt16: UInt32] = [
        36: 66, 76: 66,     // Return, Enter → ENTER
        48: 61,             // Tab
        51: 67,             // ⌫ → DEL
        117: 112,           // ⌦ → FORWARD_DEL
        53: 4,              // Esc → BACK
        123: 21, 124: 22, 125: 20, 126: 19,   // Pfeile
        115: 122, 119: 123, // Home, End
        116: 92, 121: 93,   // Bild auf/ab
    ]

    private static func keycode(for char: Unicode.Scalar) -> UInt32? {
        switch char.value {
        case 0x61...0x7A: return 29 + char.value - 0x61   // a…z → KEYCODE_A…
        case 0x30...0x39: return 7 + char.value - 0x30    // 0…9 → KEYCODE_0…
        default: return nil
        }
    }

    // MARK: Zwischenablage

    func paste(_ text: String) {
        clipboardSequence += 1
        var message = Message(type: 9)
        message.u64(clipboardSequence)
        message.u8(1)               // gleich einfügen
        message.string(text)
        client.send(message.data)
    }
}

/// Steuernachricht im Binärformat des scrcpy-Servers
private struct Message {
    struct Position {
        let x: Int32, y: Int32, width: UInt16, height: UInt16
    }

    private(set) var data = Data()

    init(type: UInt8) { data.append(type) }

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }

    mutating func append(_ position: Position) {
        u32(UInt32(bitPattern: position.x))
        u32(UInt32(bitPattern: position.y))
        u16(position.width)
        u16(position.height)
    }

    /// Länge (4 Byte) + UTF-8; der Server nimmt höchstens 300 Byte Text bzw. 256 KiB Zwischenablage
    mutating func string(_ text: String) {
        var bytes = Array(text.utf8)
        let limit = data.first == 1 ? 300 : (1 << 18) - 14
        if bytes.count > limit {
            bytes = Array(bytes.prefix(limit))
            while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }   // kein halbes Zeichen
            if let last = bytes.last, last & 0x80 != 0 { bytes.removeLast() }
        }
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
}
