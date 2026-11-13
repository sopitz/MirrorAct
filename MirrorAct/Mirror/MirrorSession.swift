// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import CoreGraphics

/// A mirrored device: source (cable, AirPlay or Android), state, image size, profile, control.
@MainActor
final class MirrorSession: ObservableObject, Identifiable {
    enum Kind { case cable, wireless, android }

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
    @Published var state: State = .connecting {
        didSet {
            // The device went away or connects anew: Translate ends here, before AirPlay and
            // Android clear the sink, while the device's last frame is still there to be shown
            // again without the translations. A new stream starts without the old ones, and
            // translates again only if the app moved the window to it a moment ago.
            if state != .live {
                translator.stop()
            } else if let deadline = translateResumeDeadline {
                cancelTranslateResume()
                if now() <= deadline { translator.start() }
            }
        }
    }
    /// Translate was on when the app moved this window to another connection: it goes on again
    /// if the new stream is live before this time, and otherwise stays off
    private var translateResumeDeadline: Date?
    private var translateResumeExpiry: Task<Void, Never>?
    /// How long the stream of a hand-over may take for Translate to go on again by itself. It
    /// is short on purpose: with a language model service the text on the screen leaves the
    /// Mac, which must not start again long after the user last turned Translate on. Switch to
    /// Wi-Fi, which restarts adb on the phone, normally fits.
    static let translateResumeWindow: TimeInterval = 10
    static var translateResumeNotice: String {
        String(localized: "Translate goes on again with the new connection – press Translate to keep it off")
    }
    /// the time, for the deadline above; the tests move it
    var now: () -> Date = Date.init
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var profile: DeviceProfile
    @Published var muted: Bool { didSet { onMuteChange?(muted) } }
    @Published var toast: String?
    @Published private(set) var recordingStartedAt: Date?
    /// most recently saved file (screenshot or recording), for dragging out of the tool rail
    @Published private(set) var lastExport: URL?
    /// unframed version of the last file for the editor (nil = can't be edited afterwards)
    @Published private(set) var lastEditable: URL?
    /// audio sample rate of this source (for recordings); nil = no audio
    var audioSampleRate: Double?
    var isRecording: Bool { recordingStartedAt != nil }

    /// profile from the device's own info (Android); takes precedence over model identifier and resolution
    var profileOverride: DeviceProfile? { didSet { updateProfile() } }

    /// control through the window (nil = display only)
    var control: DeviceControl? {
        didSet {
            oldValue?.onStateChange = nil
            control?.onStateChange = { [weak self] state in self?.controlState = state }
            controlState = control?.state
        }
    }
    /// control state; nil = device can't be controlled
    @Published private(set) var controlState: ControlState?
    var isControlReady: Bool { controlState == .ready }

    /// translates the text on the screen in place (see `ScreenTranslator`)
    let translator: ScreenTranslator
    @Published private(set) var isTranslating = false

    var onMuteChange: ((Bool) -> Void)?
    /// window was closed: stop the source
    var onClose: (() -> Void)?

    private var toastTask: Task<Void, Never>?
    /// shown in place of the toast whenever no toast is up, until it is withdrawn
    private var lastingNotice: String?

    init(id: String, kind: Kind, deviceName: String, modelIdentifier: String?, muted: Bool) {
        self.id = id
        self.kind = kind
        self.deviceName = deviceName
        self.modelIdentifier = modelIdentifier
        self.muted = muted
        translator = ScreenTranslator(sink: sink)
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
        translator.onMessage = { [weak self] message in self?.showToast(message) }
        translator.onStatus = { [weak self] status in self?.showLastingNotice(status) }
        translator.$isActive.assign(to: &$isTranslating)
    }

    /// The stream is about to end. `handingOver`: the app moves this window to another
    /// connection to the same device right away (Android: the cable unplugged with Wi-Fi still
    /// there or the other way round, Switch to Wi-Fi). Then Translate, if it is on, goes on
    /// again once the new stream is live within `translateResumeWindow`; the window says so
    /// until then. A stream that stops otherwise, also one of a hand-over that never showed a
    /// frame, leaves Translate off. Call before the state changes.
    func streamWillEnd(handingOver: Bool) {
        guard handingOver else {
            cancelTranslateResume()
            return
        }
        // The stream of a hand-over failed and the app moves the window once more: a resume
        // still waiting keeps its deadline
        guard translator.isActive else { return }
        let window = Self.translateResumeWindow
        translateResumeDeadline = now().addingTimeInterval(window)
        showToast(Self.translateResumeNotice, seconds: window)
        translateResumeExpiry?.cancel()
        translateResumeExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled, let self, let deadline = self.translateResumeDeadline,
                  self.now() >= deadline else { return }
            self.cancelTranslateResume()
        }
    }

    /// The Translate button, ⇧⌘T and the Device menu. While the window waits for the stream of
    /// a hand-over, it keeps Translate off instead: the button is not lit then, and before the
    /// first frame there is nothing it could turn on.
    func toggleTranslation() {
        if translateResumeDeadline != nil {
            cancelTranslateResume()
            showToast(String(localized: "Translate stays off"))
        } else {
            translator.toggle()
        }
    }

    private func cancelTranslateResume() {
        translateResumeDeadline = nil
        translateResumeExpiry?.cancel()
        translateResumeExpiry = nil
        if toast == Self.translateResumeNotice {
            toastTask?.cancel()
            toast = lastingNotice
        }
    }

    private func updateProfile() {
        let size = frameSize == .zero ? CGSize(width: 1170, height: 2532) : frameSize
        let resolved = profileOverride
            ?? DeviceProfile.resolve(modelIdentifier: modelIdentifier, screenPixels: sourcePixelSize, frameSize: size)
        if resolved != profile { profile = resolved }
    }

    var subtitle: String {
        if let toast { return toast }
        switch state {
        case .connecting:
            switch kind {
            case .cable: return String(localized: "Connecting via cable …")
            case .wireless: return String(localized: "Waiting for video …")
            case .android: return String(localized: "Connecting …")
            }
        case .live: return profile.marketingName ?? profile.displayName
        case let .disconnected(reason): return reason ?? String(localized: "Disconnected")
        }
    }

    func showToast(_ text: String, seconds: TimeInterval = 2) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.toast = self.lastingNotice
        }
    }

    /// A notice that stays until it is replaced or withdrawn with nil ("macOS asks whether it may
    /// download …"). A toast goes over it for its time.
    func showLastingNotice(_ text: String?) {
        let isShown = toast == nil || toast == lastingNotice
        lastingNotice = text
        if isShown {
            toastTask?.cancel()
            toast = text
        }
    }

    /// screen size in macOS points at 100 % (oriented like the image)
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

    // MARK: Recording

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
            recorder.appendVideo(latest, at: MirrorRecorder.now)   // first frame, even if nothing moves
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

    /// unframed screen in the temporary folder (for the editor)
    private func rawScreenshotCopy() -> URL? {
        guard let buffer = sink.latest, let screen = FrameRenderer.cgImage(from: buffer) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(deviceName) (Original).png")
        return FrameRenderer.writePNG(screen, to: url) ? url : nil
    }

    /// screenshot as a file in the temporary folder (for drag & drop)
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

    // MARK: Text

    /// Reads the text on the screen (Vision, on this Mac) and copies it to the clipboard:
    /// the text of the device, also while its translation is shown
    func copyText() {
        guard let buffer = sink.latestSource ?? sink.latest else {
            NSSound.beep()
            showToast(String(localized: "No video to copy text from yet"))
            return
        }
        Task { [weak self] in
            guard let lines = await TextRecognizer.recognize(buffer) else {
                self?.showToast(String(localized: "Text recognition failed"))
                return
            }
            guard !lines.isEmpty else {
                NSSound.beep()
                self?.showToast(String(localized: "No text found"))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TextLayout.plainText(lines), forType: .string)
            self?.showToast(String(localized: "Text copied to the clipboard"))
        }
    }
}
