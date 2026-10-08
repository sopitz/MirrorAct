// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Bedienung eines Geräts über das Spiegelfenster. Das Fenster rechnet Maus und Trackpad in
/// Bildschirmkoordinaten um: (0, 0) oben links, (1, 1) unten rechts, ausgerichtet wie das Videobild.
/// Eingaben kommen nur an, solange `state == .ready`.
protocol DeviceControl: AnyObject {
    /// Tasten für Kontextmenü (alle) und Werkzeugleiste (die ersten drei)
    var buttons: [DeviceButton] { get }

    /// Android: immer bereit; iPhone: erst nach start() (Agent auf dem Gerät)
    var state: ControlState { get }
    /// lässt sich ein- und ausschalten (Menü «Gerät bedienen»); false = immer an, solange verbunden
    var startsOnDemand: Bool { get }
    /// auf dem Main-Thread
    var onStateChange: ((ControlState) -> Void)? { get set }
    func start()
    /// beim Ausschalten und beim Schliessen des Fensters
    func stop()

    func touch(_ phase: TouchPhase, at point: CGPoint)
    /// Mausrad oder Trackpad; Werte wie NSEvent.scrollingDeltaX/Y (Punkte bei präzisem Scrollen, sonst Zeilen)
    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, precise: Bool)
    /// keyDown/keyUp ohne ⌘ (Menükürzel gehen vor); true = verarbeitet
    func key(_ event: NSEvent) -> Bool
    func press(_ button: DeviceButton)
    /// Text aus der Zwischenablage des Macs einfügen (⌘V)
    func paste(_ text: String)
}

extension DeviceControl {
    var state: ControlState { .ready }
    var startsOnDemand: Bool { true }
    var onStateChange: ((ControlState) -> Void)? {
        get { nil }
        set {}
    }
    func start() {}
    func stop() {}
}

enum ControlState: Equatable {
    case off, starting, ready
    /// Meldung für den Benutzer (mehrzeilig möglich)
    case failed(String)
}

enum TouchPhase {
    case began, moved, ended
}

enum DeviceButton: CaseIterable, Identifiable {
    case back, home, recents, notifications, volumeUp, volumeDown, power, rotate

    var id: Self { self }

    var title: String {
        switch self {
        case .back: String(localized: "Back")
        case .home: String(localized: "Home")
        case .recents: String(localized: "Recent Apps")
        case .notifications: String(localized: "Notifications")
        case .volumeUp: String(localized: "Volume Up")
        case .volumeDown: String(localized: "Volume Down")
        case .power: String(localized: "Screen On/Off")
        case .rotate: String(localized: "Rotate")
        }
    }

    var symbol: String {
        switch self {
        case .back: "chevron.backward"
        case .home: "circle"
        case .recents: "square.on.square"
        case .notifications: "bell"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .power: "power"
        case .rotate: "rotate.right"
        }
    }
}
