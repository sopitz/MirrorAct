// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Control of a device through the mirror window. The window converts mouse and trackpad input to
/// screen coordinates: (0, 0) top left, (1, 1) bottom right, oriented like the video image.
/// Input only arrives while `state == .ready`.
protocol DeviceControl: AnyObject {
    /// Buttons for the context menu (all) and the tool rail (the first three, in the device's order)
    var buttons: [DeviceButton] { get }
    /// Symbol of a button as it looks on the device (default: `button.symbol`)
    func glyph(for button: DeviceButton) -> DeviceButton.Glyph

    /// Android: always ready; iPhone: only after start() (agent on the device)
    var state: ControlState { get }
    /// can be turned on and off (menu "Control Device"); false = always on while connected
    var startsOnDemand: Bool { get }
    /// on the main thread
    var onStateChange: ((ControlState) -> Void)? { get set }
    func start()
    /// when turning off and when closing the window
    func stop()

    func touch(_ phase: TouchPhase, at point: CGPoint)
    /// Mouse wheel or trackpad; values like NSEvent.scrollingDeltaX/Y (points for precise scrolling, otherwise lines)
    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, precise: Bool)
    /// keyDown/keyUp without ⌘ (menu shortcuts take precedence); true = handled
    func key(_ event: NSEvent) -> Bool
    func press(_ button: DeviceButton)
    /// Paste text from the Mac's clipboard (⌘V)
    func paste(_ text: String)
}

extension DeviceControl {
    func glyph(for button: DeviceButton) -> DeviceButton.Glyph { DeviceButton.Glyph(symbol: button.symbol) }
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
    /// Message for the user (may span several lines)
    case failed(String)
}

enum TouchPhase {
    case began, moved, ended
}

enum DeviceButton: CaseIterable, Identifiable {
    case back, home, recents, notifications, volumeUp, volumeDown, power, rotate

    var id: Self { self }

    /// SF Symbol, optionally rotated (Samsung's "|||" is three horizontal lines rotated by 90°)
    struct Glyph: Equatable {
        var symbol: String
        var rotation: Double = 0
    }

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
