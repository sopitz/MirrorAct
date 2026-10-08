// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import SwiftUI

/// Test der Android-Spiegelung ohne Klicken (nur Debug-Builds), über die
/// DistributedNotification "io.github.sopitz.MirrorAct.android-test" mit userInfo:
///   cmd=open serial=<adb-Seriennummer>       Fenster öffnen
///   cmd=wifi serial=…  ·  cmd=devices          auf WLAN umstellen · Geräteliste ins Log
///   cmd=touch phase=began|moved|ended x=0…1 y=0…1
///   cmd=scroll x y dy [precise=1]
///   cmd=text text=…  ·  cmd=press button=back|home|recents|…
///   cmd=frame path=<datei.png>               letztes Bild (ungerahmt) sichern
///   cmd=window path=<datei.png>              Screenshot mit Rahmen
///   cmd=guide|launcher|rail path=<datei.png>  Ansicht zeichnen
///   cmd=showcase device=… path=<ordner>      README-Bilder (Showcase) aus genau diesem Fenster
///   device=<Seriennummer> wählt das Fenster (sonst das vorderste), pid=<Prozess> die Instanz
@MainActor
enum AndroidDebug {
    static let notification = Notification.Name("io.github.sopitz.MirrorAct.android-test")

    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { handle(info) }
        }
    }

    private static func handle(_ info: [String: String]) {
        // pid=<Prozess>: nur diese Instanz (es können mehrere MirrorAct laufen)
        if let pid = info["pid"], pid != String(ProcessInfo.processInfo.processIdentifier) { return }
        let model = AppModel.shared
        func number(_ key: String) -> CGFloat { CGFloat(Double(info[key] ?? "") ?? 0) }
        // device=<Seriennummer>: dieses Fenster, sonst das vorderste
        let mirrors = NSApp.windows.compactMap { $0.windowController as? MirrorWindowController }
        let chosen = info["device"].flatMap { id in mirrors.first { $0.session.id.hasSuffix(id) }?.session }
        let session = chosen ?? model.keyMirror?.session
        switch info["cmd"] {
        case "open":
            guard let device = model.android.devices.first(where: { $0.serial == info["serial"] }) else {
                Log.error("AndroidDebug: device \(info["serial"] ?? "-") not found")
                return
            }
            model.openAndroidDevice(device)
        case "wifi":
            guard let device = model.android.devices.first(where: { $0.serial == info["serial"] }) else { return }
            model.switchAndroidToWiFi(device)
        case "devices":
            for device in model.android.devices {
                Log.info("AndroidDebug device \(device.serial) \(device.state) wireless \(device.isWireless) id \(device.stableID)")
            }
        case "touch":
            let phase: TouchPhase = info["phase"] == "began" ? .began : info["phase"] == "moved" ? .moved : .ended
            session?.control?.touch(phase, at: CGPoint(x: number("x"), y: number("y")))
        case "scroll":
            session?.control?.scroll(at: CGPoint(x: number("x"), y: number("y")), dx: 0, dy: number("dy"),
                                     precise: info["precise"] == "1")
        case "text":
            guard let text = info["text"],
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)
            else { return }
            _ = session?.control?.key(event)
        case "press":
            if let button = DeviceButton.allCases.first(where: { "\($0)" == info["button"] }) {
                session?.control?.press(button)
            }
        case "frame":
            if let path = info["path"], let buffer = session?.sink.latest, let image = FrameRenderer.cgImage(from: buffer) {
                _ = FrameRenderer.writePNG(image, to: URL(fileURLWithPath: path))
            }
        case "window":
            if let path = info["path"], let image = session?.screenshotImage(withFrame: true) {
                _ = FrameRenderer.writePNG(image, to: URL(fileURLWithPath: path))
            }
        case "showcase":
            // wie die Showcase-Notification, aber nur in dieser Instanz und nur mit ausdrücklich gewähltem
            // Gerät (sonst nähme es das vorderste Fenster – womöglich mit privaten Inhalten)
            if let path = info["path"], let chosen {
                Showcase.export(to: URL(fileURLWithPath: path), session: chosen)
            }
        case "guide":
            render(ConnectGuide(platform: .android).background(Color(white: 0.14)), info["path"])
        case "launcher":
            render(LauncherView(), info["path"])
        case "rail":
            if let session, let controller = model.keyMirror {
                let chrome = MirrorChrome()
                chrome.hovering = true
                render(MirrorToolRail(session: session, chrome: chrome, actions: controller.actions).padding(8)
                    .background(Color.black), info["path"])
            }
        default:
            break
        }
        func render<V: View>(_ view: V, _ path: String?) {
            guard let path else { return }
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let image = renderer.cgImage { _ = FrameRenderer.writePNG(image, to: URL(fileURLWithPath: path)) }
        }
        Log.info("AndroidDebug \(info["cmd"] ?? "-"): state \(String(describing: session?.state)), "
                 + "control \(String(describing: session?.controlState)), frame \(session?.frameSize ?? .zero)")
    }
}
#endif
