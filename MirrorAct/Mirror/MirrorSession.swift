// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import CoreGraphics

/// Ein gespiegeltes Gerät: Quelle (Kabel oder AirPlay), Zustand, Bildgrösse, Profil.
@MainActor
final class MirrorSession: ObservableObject, Identifiable {
    enum Kind { case cable, wireless }

    enum State: Equatable {
        case connecting
        case live
        case disconnected(String?)
    }

    let id: String
    let kind: Kind
    let sink = FrameSink()

    @Published var deviceName: String
    @Published var modelIdentifier: String? { didSet { updateProfile() } }
    @Published var sourcePixelSize: CGSize? { didSet { updateProfile() } }
    @Published var state: State = .connecting
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var profile: DeviceProfile
    @Published var muted: Bool { didSet { onMuteChange?(muted) } }
    @Published var toast: String?
    @Published private(set) var recordingStartedAt: Date?
    /// zuletzt gesicherte Datei (Screenshot oder Aufnahme), zum Herausziehen aus der Kopfleiste
    @Published private(set) var lastExport: URL?
    /// ungerahmte Fassung der letzten Datei für den Editor (nil = nicht nachträglich bearbeitbar)
    @Published private(set) var lastEditable: URL?
    /// Abtastrate des Tons dieser Quelle (für Aufnahmen); nil = ohne Ton
    var audioSampleRate: Double?
    var isRecording: Bool { recordingStartedAt != nil }

    var onMuteChange: ((Bool) -> Void)?
    /// Fenster wurde geschlossen: Quelle beenden
    var onClose: (() -> Void)?

    private var toastTask: Task<Void, Never>?

    init(id: String, kind: Kind, deviceName: String, modelIdentifier: String?, muted: Bool) {
        self.id = id
        self.kind = kind
        self.deviceName = deviceName
        self.modelIdentifier = modelIdentifier
        self.muted = muted
        profile = DeviceProfile.resolve(modelIdentifier: modelIdentifier, screenPixels: nil,
                                        frameSize: CGSize(width: 1170, height: 2532))
        sink.onSizeChange = { [weak self] size in
            MainActor.assumeIsolated {
                self?.frameSize = size
                self?.updateProfile()
            }
        }
        sink.onFirstFrame = { [weak self] in
            MainActor.assumeIsolated { self?.state = .live }
        }
    }

    private func updateProfile() {
        let size = frameSize == .zero ? CGSize(width: 1170, height: 2532) : frameSize
        let resolved = DeviceProfile.resolve(modelIdentifier: modelIdentifier, screenPixels: sourcePixelSize,
                                             frameSize: size)
        if resolved != profile { profile = resolved }
    }

    var subtitle: String {
        if let toast { return toast }
        switch state {
        case .connecting: return kind == .cable ? String(localized: "Connecting via cable …") : String(localized: "Waiting for video …")
        case .live: return profile.marketingName ?? profile.displayName
        case let .disconnected(reason): return reason ?? String(localized: "Disconnected")
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Bildschirmgrösse in macOS-Punkten bei 100 % (ausgerichtet wie das Bild)
    var screenPointSize: CGSize {
        let frame = frameSize == .zero ? CGSize(width: 1170, height: 2532) : frameSize
        let landscape = frame.width > frame.height
        let shortSide = min(frame.width, frame.height), longSide = max(frame.width, frame.height)
        var width: CGFloat
        if let points = profile.pointSize {
            width = points.width
        } else {
            width = shortSide / (profile.family == .iPad ? 2 : 3)
        }
        let height = width * longSide / max(1, shortSide)
        return landscape ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    // MARK: Aufnahme

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        guard let latest = sink.latest else {
            NSSound.beep()
            showToast(String(localized: "No video to record yet"))
            return
        }
        let withFrame = AppSettings.shared.recordWithFrame
        let size = CGSize(width: CVPixelBufferGetWidth(latest), height: CVPixelBufferGetHeight(latest))
        let url = desktopURL(extension: "mov")
        do {
            let recorder = try MirrorRecorder(url: url, frameSize: size, profile: profile, withFrame: withFrame,
                                              style: AppSettings.shared.style, audioSampleRate: audioSampleRate)
            recorder.appendVideo(latest, at: MirrorRecorder.now)   // Startbild, auch wenn sich nichts bewegt
            sink.recorder = recorder
            recordingStartedAt = Date()
            Log.info("Recording started: \(url.lastPathComponent) (frame: \(withFrame), background: \(AppSettings.shared.style.background.rawValue))")
        } catch {
            Log.error("Recording: \(error.localizedDescription)")
            showToast(String(localized: "Recording failed"))
        }
    }

    func stopRecording() {
        guard let recorder = sink.recorder else { return }
        sink.recorder = nil
        recordingStartedAt = nil
        recorder.finish { [weak self] result in
            switch result {
            case let .success(url):
                Log.info("Recording saved: \(url.path)")
                self?.lastExport = url
                self?.lastEditable = recorder.isPassthrough ? url : nil
                self?.showToast(String(localized: "Recording saved – drag it out to share"))
            case let .failure(error):
                Log.error("Recording: \(error.localizedDescription)")
                self?.showToast(String(localized: "Recording failed"))
            }
        }
    }

    private func desktopURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = String(localized: "yyyy-MM-dd 'at' HH.mm.ss")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        return desktop.appendingPathComponent("\(deviceName) \(formatter.string(from: Date())).\(ext)")
    }

    // MARK: Screenshots

    func screenshotImage(withFrame: Bool) -> CGImage? {
        guard let buffer = sink.latest, let screen = FrameRenderer.cgImage(from: buffer) else { return nil }
        return FrameRenderer.render(screen: screen, profile: profile, showFrame: withFrame,
                                    style: AppSettings.shared.style)
    }

    /// ungerahmter Bildschirm im temporären Ordner (für den Editor)
    private func rawScreenshotCopy() -> URL? {
        guard let buffer = sink.latest, let screen = FrameRenderer.cgImage(from: buffer) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(deviceName) (Original).png")
        return FrameRenderer.writePNG(screen, to: url) ? url : nil
    }

    /// Screenshot als Datei im temporären Ordner (für Drag & Drop)
    func screenshotFileForDragging(withFrame: Bool) -> URL? {
        guard let image = screenshotImage(withFrame: withFrame) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = String(localized: "yyyy-MM-dd 'at' HH.mm.ss")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(deviceName) \(formatter.string(from: Date())).png")
        return FrameRenderer.writePNG(image, to: url) ? url : nil
    }

    func saveScreenshot(withFrame: Bool) {
        guard let image = screenshotImage(withFrame: withFrame) else {
            NSSound.beep()
            return
        }
        let url = desktopURL(extension: "png")
        if FrameRenderer.writePNG(image, to: url) {
            lastExport = url
            lastEditable = rawScreenshotCopy()
            showToast(String(localized: "Saved to the Desktop"))
        } else {
            showToast(String(localized: "Saving failed"))
        }
    }

    func copyScreenshot(withFrame: Bool) {
        guard let image = screenshotImage(withFrame: withFrame) else {
            NSSound.beep()
            return
        }
        FrameRenderer.copyToPasteboard(image)
        showToast(String(localized: "Copied to the clipboard"))
    }
}
