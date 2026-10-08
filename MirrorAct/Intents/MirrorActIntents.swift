// SPDX-License-Identifier: GPL-3.0-or-later
import AppIntents
import AppKit
import UniformTypeIdentifiers

/// Kurzbefehle: Screenshots einrahmen (auch als Finder-Schnellaktion nutzbar),
/// Screenshot vom gespiegelten Gerät, Aufnahme starten/beenden.

struct FrameScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Screenshot einrahmen"
    static var description = IntentDescription(
        "Setzt iPhone- oder iPad-Screenshots in den Gerätrahmen, mit der Gestaltung aus MirrorAct (Rahmenfarbe, Hintergrund, Format).")

    @Parameter(title: "Screenshots", supportedContentTypes: [.image])
    var files: [IntentFile]

    @Parameter(title: "Mit Gerätrahmen", default: true)
    var withFrame: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$files) einrahmen") {
            \.$withFrame
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let style = AppSettings.shared.style
        var results: [IntentFile] = []
        for file in files {
            guard let source = CGImageSourceCreateWithData(file.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let size = CGSize(width: image.width, height: image.height)
            let profile = DeviceProfile.resolve(modelIdentifier: nil, screenPixels: size, frameSize: size)
            guard let framed = FrameRenderer.render(screen: image, profile: profile, showFrame: withFrame, style: style),
                  let data = IntentSupport.png(framed) else { continue }
            let base = (file.filename as NSString).deletingPathExtension
            results.append(IntentFile(data: data, filename: "\(base) (Rahmen).png", type: .png))
        }
        guard !results.isEmpty else { throw IntentSupport.Failure.noImages }
        return .result(value: results)
    }
}

struct DeviceScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Screenshot vom iPhone"
    static var description = IntentDescription(
        "Screenshot des gerade gespiegelten Geräts, mit der Gestaltung aus MirrorAct.")

    @Parameter(title: "Mit Gerätrahmen", default: true)
    var withFrame: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let image: CGImage? = await MainActor.run {
            AppModel.shared.keyMirror?.session.screenshotImage(withFrame: withFrame)
        }
        guard let image, let data = IntentSupport.png(image) else { throw IntentSupport.Failure.noDevice }
        let name: String = await MainActor.run { AppModel.shared.keyMirror?.session.deviceName ?? "iPhone" }
        return .result(value: IntentFile(data: data, filename: "\(name).png", type: .png))
    }
}

struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Aufnahme starten oder beenden"
    static var description = IntentDescription("Startet bzw. beendet die Videoaufnahme des gespiegelten Geräts.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recording: Bool? = await MainActor.run {
            guard let session = AppModel.shared.keyMirror?.session else { return nil }
            session.toggleRecording()
            return session.isRecording
        }
        guard let recording else { throw IntentSupport.Failure.noDevice }
        return .result(dialog: recording ? "Aufnahme läuft" : "Aufnahme beendet")
    }
}

struct MirrorActShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DeviceScreenshotIntent(),
                    phrases: ["Screenshot mit \(.applicationName)", "\(.applicationName) Screenshot"],
                    shortTitle: "Screenshot vom iPhone", systemImageName: "camera")
        AppShortcut(intent: ToggleRecordingIntent(),
                    phrases: ["Aufnahme mit \(.applicationName)", "\(.applicationName) Aufnahme"],
                    shortTitle: "Aufnahme starten/beenden", systemImageName: "record.circle")
    }
}

enum IntentSupport {
    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case noImages, noDevice
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noImages: return "Keine lesbaren Bilder übergeben."
            case .noDevice: return "Kein Gerät wird gerade gespiegelt."
            }
        }
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
