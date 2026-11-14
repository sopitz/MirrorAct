// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Combine
import SwiftUI

/// Tests Android mirroring without clicking (debug builds only), via the
/// DistributedNotification "io.github.sopitz.MirrorAct.android-test" with userInfo:
///   cmd=open serial=<adb-serial>             open window
///   cmd=wifi serial=…  ·  cmd=devices          switch to Wi-Fi · device list to log
///   cmd=touch phase=began|moved|ended x=0…1 y=0…1
///   cmd=scroll x y dy [precise=1]
///   cmd=text text=…  ·  cmd=press button=back|home|recents|…
///   cmd=frame path=<file.png>                save latest image (without frame)
///   cmd=window path=<file.png>               screenshot with frame
///   cmd=guide|launcher|rail path=<file.png>  render view
///   cmd=showcase device=… path=<folder>      README images (showcase) from exactly this window
///   cmd=translate on=1|0                     Translate on or off (without on=: toggle)
///   cmd=copytext                             Text: copy the text on the screen to the clipboard
///   cmd=dump path=<folder>                   one and the same frame: source.png (as sent), shown.png
///                                            (as shown) and placement.json (what the translator draws,
///                                            what the tracker knows and still has to read)
///   cmd=textsettings path=<file.png>         draw the Text tab of the settings (written a second later)
///   cmd=record on=1|0  ·  cmd=present on=1|0 recording · presentation on or off (without on=: toggle)
///   cmd=translator                           log the translator's state as the user sees it
///   cmd=close                                close the mirror window (as its close button does)
///   cmd=screenshot kind=save|copy|intent [frame=1] [path=<file.png> for intent]
///                                            Save Screenshot · Copy Screenshot · the Shortcuts action
///   cmd=setting key=translationLanguage|translationEngine|llmProvider|llmModel|llmBaseURL|recordWithFrame
///               value=…                      change a setting while running; the stored value is put back
///   device=<serial> selects the window (otherwise the frontmost), pid=<process> the instance
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
        // pid=<process>: only this instance (several MirrorAct instances can run)
        if let pid = info["pid"], pid != String(ProcessInfo.processInfo.processIdentifier) { return }
        let model = AppModel.shared
        func number(_ key: String) -> CGFloat { CGFloat(Double(info[key] ?? "") ?? 0) }
        // device=<serial>: this window, otherwise the frontmost
        let mirrors = NSApp.windows.compactMap { $0.windowController as? MirrorWindowController }
        let chosen = info["device"].flatMap { id in mirrors.first { $0.session.id.hasSuffix(id) }?.session }
        let session = chosen ?? model.keyMirror?.session
        let wanted: Bool? = info["on"].map { $0 == "1" }
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
            // like the showcase notification, but only in this instance and only with an explicitly chosen
            // device (otherwise it would take the frontmost window – possibly with private content)
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
        case "translate":
            guard let session else { break }
            followToasts(of: session)
            if wanted ?? !session.translator.isActive { session.translator.start() } else { session.translator.stop() }
        case "copytext":
            guard let session else { break }
            followToasts(of: session)
            session.copyText()
        case "dump":
            if let path = info["path"], let session { dump(session, to: URL(fileURLWithPath: path)) }
        case "textsettings":
            if let path = info["path"] {
                snapshot(TextSettingsView().settingsPage(maxHeight: 2000).frame(width: SettingsView.width), to: path)
            }
        case "record":
            guard let session else { break }
            followToasts(of: session)
            if wanted ?? !session.isRecording { session.startRecording() } else { session.stopRecording() }
        case "present":
            if let controller = mirrors.first(where: { $0.session === session }),
               (wanted ?? !controller.isPresenting) != controller.isPresenting {
                controller.togglePresentation()
                Log.info("AndroidDebug present: \(controller.isPresenting ? "on" : "off")")
            }
        case "close":
            // as the close button of the window's own chrome does
            mirrors.first(where: { $0.session === session })?.close()
        case "screenshot":
            // the three ways a user takes a screenshot: Save (Desktop), Copy (clipboard), Shortcuts
            guard let session else { break }
            followToasts(of: session)
            let withFrame = info["frame"] == "1"
            switch info["kind"] {
            case "save": session.saveScreenshot(withFrame: withFrame)
            case "copy": session.copyScreenshot(withFrame: withFrame)
            case "intent":
                guard let path = info["path"] else { break }
                Task { @MainActor in
                    let intent = DeviceScreenshotIntent()
                    intent.withFrame = withFrame
                    do {
                        let result = try await intent.perform()
                        if let data = result.value?.data {
                            try data.write(to: URL(fileURLWithPath: path))
                            Log.info("AndroidDebug intent screenshot: \(data.count) bytes → \(path)")
                        }
                    } catch {
                        Log.error("AndroidDebug intent screenshot: \(error)")
                    }
                }
            default: break
            }
        case "setting":
            // Changes a setting in memory, as the settings window would, then puts the stored
            // value back, so that the shared preferences keep what they had before.
            guard let key = info["key"], let value = info["value"] else { break }
            let defaults = UserDefaults.standard
            let storedKey = ["llmModel": "llmModels", "llmBaseURL": "llmBaseURLs"][key] ?? key
            let before = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[storedKey]
            let settings = AppSettings.shared
            switch key {
            case "translationLanguage": settings.translationLanguage = value
            case "translationEngine": settings.translationEngine = value
            case "llmProvider": settings.llmProvider = value
            case "llmModel": settings.llmModels[settings.llmProvider] = value.isEmpty ? nil : value
            case "llmBaseURL": settings.llmBaseURLs[settings.llmProvider] = value.isEmpty ? nil : value
            case "recordWithFrame": settings.recordWithFrame = value == "1"
            default: Log.error("AndroidDebug setting: unknown key \(key)")
            }
            if let before { defaults.set(before, forKey: storedKey) } else { defaults.removeObject(forKey: storedKey) }
            Log.info("AndroidDebug setting \(key) = \(value) (stored value put back)")
        case "translator":
            guard let session else { break }
            let settings = AppSettings.shared
            // what the settings would use, without asking the keychain
            let configured = settings.translationEngine == "llm"
                ? LLMTranslationEngine.name(for: LLMConnection(provider: TranslationEngines.llmProvider(id: settings.llmProvider),
                                                               baseURL: settings.llmBaseURLs[settings.llmProvider],
                                                               model: settings.llmModels[settings.llmProvider]))
                : "Apple"
            Log.info("AndroidDebug translator: \(session.translator.isActive ? "on" : "off"), "
                     + "engine \(session.translator.debugEngineName ?? "-") (settings: \(configured) into "
                     + "\(settings.translationTarget.minimalIdentifier)), message \(session.toast ?? "-")")
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

    /// toasts of the windows that commands were sent to, into the log (they vanish after two seconds)
    private static var toastWatchers: [String: AnyCancellable] = [:]

    private static func followToasts(of session: MirrorSession) {
        guard toastWatchers[session.id] == nil else { return }
        toastWatchers[session.id] = session.$toast.compactMap { $0 }.sink { Log.info("AndroidDebug toast: \($0)") }
    }

    /// Views with AppKit controls (Form, Picker) stay empty in an ImageRenderer: these are drawn
    /// in a window off the screen instead, once they had a moment to load what they show.
    private static func snapshot<V: View>(_ view: V, to path: String) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.14, alpha: 1)
        window.contentView = hosting
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let image = rep.cgImage { _ = FrameRenderer.writePNG(image, to: URL(fileURLWithPath: path)) }
            }
            window.orderOut(nil)
            window.contentView = nil
            Log.info("AndroidDebug snapshot \(Int(hosting.bounds.width))×\(Int(hosting.bounds.height)) → \(path)")
        }
    }

    /// source.png, shown.png and placement.json of one and the same frame
    private static func dump(_ session: MirrorSession, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (source, shown, placement) = session.sink.debugSnapshot { source, shown in
            (source, shown, session.translator.debugPlacement())
        }
        // "time" is the moment of the snapshot; the PNGs are encoded on a background queue, so
        // that several dumps a second are possible and the main thread is not held up
        let time = Date().timeIntervalSince1970
        let images = [("source.png", source), ("shown.png", shown)].compactMap { name, buffer in
            buffer.flatMap { FrameRenderer.cgImage(from: $0) }.map { (name, $0) }
        }
        let size = source.map { ["width": CVPixelBufferGetWidth($0), "height": CVPixelBufferGetHeight($0)] }
        let json: [String: Any] = [
            "time": time, "translating": session.translator.isActive,
            "engine": session.translator.debugEngineName ?? NSNull(), "sameBuffer": source === shown,
            "frame": size ?? NSNull(), "placed": placement.placed, "tracked": placement.tracked,
            "reading": placement.reading,
        ]
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let summary = "\(placement.placed.count) placed, \(placement.tracked.count) tracked → \(folder.path)"
        dumpQueue.async {
            for (name, image) in images { _ = FrameRenderer.writePNG(image, to: folder.appendingPathComponent(name)) }
            // written last: its presence means the dump is complete
            try? data?.write(to: folder.appendingPathComponent("placement.json"))
            Log.info("AndroidDebug dump: \(summary)")
        }
    }

    private static let dumpQueue = DispatchQueue(label: "AndroidDebug.dump", qos: .utility)
}
#endif
