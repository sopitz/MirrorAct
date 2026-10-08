// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMediaIO
import Foundation

/// Per Kabel verbundene iPhones/iPads, die macOS als Bildschirm-Aufnahmegerät anbietet
/// (derselbe Weg wie QuickTime "Neue Filmaufnahme").
@MainActor
final class USBDeviceMonitor: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String          // AVCaptureDevice.uniqueID
        let name: String
        let modelID: String
    }

    @Published private(set) var devices: [Device] = []

    private var discovery: AVCaptureDevice.DiscoverySession?
    private var observation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    static func allowScreenCaptureDevices() {
        for selector in [kCMIOHardwarePropertyAllowScreenCaptureDevices,
                         kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices] {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(selector),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var allow: UInt32 = 1
            CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                      UInt32(MemoryLayout<UInt32>.size), &allow)
        }
    }

    func start() {
        Self.allowScreenCaptureDevices()
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                                         position: .unspecified)
        self.discovery = discovery
        observation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let found = (discovery?.devices ?? []).filter { $0.hasMediaType(.muxed) }
        let list = found.map { Device(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
        if list != devices {
            devices = list
            Log.info("USB-Geräte: \(list.map { "\($0.name) [\($0.modelID)]" })")
        }
    }

    func captureDevice(for id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }
}

/// Bild (und Ton) eines per Kabel verbundenen Geräts
final class USBCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Ton für Aufnahmen: so konfiguriert, dass der Rekorder die Rate kennt
    static let audioSampleRate: Double = 48000

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirroract.usb.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "mirroract.usb.audio", qos: .userInitiated)
    private var audioOutput: AVCaptureAudioPreviewOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    /// Bild mit Host-Zeit
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Ton mit Host-Zeit (nur für Aufnahmen)
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((String?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    var muted = false {
        didSet { audioOutput?.volume = muted ? 0 : 1 }
    }

    func start(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        video.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(video) { session.addOutput(video) }

        let audio = AVCaptureAudioPreviewOutput()
        audio.volume = muted ? 0 : 1
        if session.canAddOutput(audio) {
            session.addOutput(audio)
            audioOutput = audio
        }
        let audioData = AVCaptureAudioDataOutput()
        audioData.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioData.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioData) {
            session.addOutput(audioData)
            audioDataOutput = audioData
        }
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onStop?(error?.localizedDescription)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device,
                                            queue: .main) { [weak self] _ in
            self?.onStop?(nil)
        })

        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioDataOutput {
            guard let onAudio, let retimed = retimedToHostClock(sampleBuffer) else { return }
            onAudio(retimed)
        } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            onFrame?(pixelBuffer, hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }
    }

    private func hostTime(_ time: CMTime) -> CMTime {
        guard time.isValid, let clock = session.synchronizationClock else { return CMClockGetTime(CMClockGetHostTimeClock()) }
        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
    }

    private func retimedToHostClock(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy
    }

    enum CaptureError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "Das Gerät ist bereits in einer anderen App geöffnet (z. B. QuickTime)." }
    }

    /// Kamera- und Mikrofonfreigabe (für Bildschirm-Aufnahmegeräte nötig)
    static func requestAccess() async -> Bool {
        let video = await request(.video)
        _ = await request(.audio)
        return video
    }

    private static func request(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}
