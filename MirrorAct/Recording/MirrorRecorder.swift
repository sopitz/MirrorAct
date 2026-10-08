// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

/// Nimmt das gespiegelte Bild (und den Ton) als .mov auf.
/// - nur Bildschirm: H.264 in Bildschirmauflösung
/// - mit Gestaltung (Rahmen, Hintergrund …): über SceneRenderer; transparent → HEVC mit Alpha, sonst H.264
/// Zeitstempel sind Host-Zeit; das iPhone schickt nur bei Änderungen Bilder, darum
/// variable Bildrate (das letzte Bild wird beim Stoppen bis zum Ende verlängert).
final class MirrorRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "Die Aufnahme konnte nicht gestartet werden." }
    }

    let url: URL
    /// nur der Bildschirm (ohne Gestaltung) – lässt sich später im Editor rahmen
    let isPassthrough: Bool
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var scene: SceneRenderer?
    private let profile: DeviceProfile
    private let canvasSize: CGSize
    private let queue = DispatchQueue(label: "mirroract.recorder", qos: .userInitiated)

    private var sessionStarted = false
    private var finished = false
    private var lastVideoTime = CMTime.invalid
    private var lastFrame: CVPixelBuffer?

    init(url: URL, frameSize: CGSize, profile: DeviceProfile, withFrame: Bool, style: FrameStyle,
         audioSampleRate: Double?) throws {
        self.url = url
        self.profile = profile
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let passthrough = SceneRenderer.isPassthrough(style: style, showFrame: withFrame)
        isPassthrough = passthrough
        let needsAlpha = !passthrough && style.background == .transparent
        if passthrough {
            canvasSize = CGSize(width: SceneRenderer.even(frameSize.width), height: SceneRenderer.even(frameSize.height))
        } else {
            // Leinwand aus dem ersten Bild; spätere Drehungen werden eingepasst
            canvasSize = Self.limited(SceneRenderer.naturalCanvas(style: style, profile: profile, showFrame: withFrame,
                                                                 screenSize: frameSize))
            scene = SceneRenderer(style: style, profile: profile, showFrame: withFrame, fixedCanvas: canvasSize)
        }

        let pixels = canvasSize.width * canvasSize.height
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height),
        ]
        if needsAlpha {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixels * 4),
                AVVideoExpectedSourceFrameRateKey: 60,
            ]
        } else {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixels * 4),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height),
        ])
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput }
        writer.add(videoInput)

        if let rate = audioSampleRate {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotAddInput }
    }

    static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// höchstens 4K (längste Seite 3840, max. 3840×2160 Pixel), sonst lehnen die Encoder ab
    private static func limited(_ size: CGSize) -> CGSize {
        let maxSide: CGFloat = 3840, maxPixels: CGFloat = 3840 * 2160
        let factor = min(1, maxSide / max(size.width, size.height), (maxPixels / (size.width * size.height)).squareRoot())
        guard factor < 1 else { return size }
        return CGSize(width: SceneRenderer.even(size.width * factor - 1), height: SceneRenderer.even(size.height * factor - 1))
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        queue.async { self.writeVideo(pixelBuffer, at: time) }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.sessionStarted, !self.finished, let input = self.audioInput,
                  input.isReadyForMoreMediaData else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard self.lastVideoTime.isValid, time >= self.startTime else { return }
            input.append(sampleBuffer)
        }
    }

    private var startTime = CMTime.zero

    private func writeVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !finished, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            startTime = time
            sessionStarted = true
        }
        if lastVideoTime.isValid, time <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if scene == nil, size != canvasSize {
            // z. B. gedreht: schwarz umrandet in die feste Leinwand einpassen
            scene = SceneRenderer(style: .letterbox, profile: profile, showFrame: false, fixedCanvas: canvasSize)
        }
        var output: CVPixelBuffer? = pixelBuffer
        if let scene {
            output = nil
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
                if let output { scene.render(screen: pixelBuffer, into: output) }
            }
        }
        guard let output else { return }
        if adaptor.append(output, withPresentationTime: time) {
            lastVideoTime = time
            lastFrame = output
        }
    }

    /// Beendet die Aufnahme; completion auf dem Main-Thread mit der Datei oder einem Fehler
    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        let end = Self.now
        queue.async {
            guard !self.finished else { return }
            // letztes Bild bis zum Stopp stehen lassen
            if let frame = self.lastFrame, self.lastVideoTime.isValid,
               CMTimeSubtract(end, self.lastVideoTime).seconds > 0.02, self.videoInput.isReadyForMoreMediaData {
                if self.adaptor.append(frame, withPresentationTime: end) { self.lastVideoTime = end }
            }
            self.finished = true
            guard self.sessionStarted else {
                self.writer.cancelWriting()
                DispatchQueue.main.async { completion(.failure(RecorderError.cannotAddInput)) }
                return
            }
            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writer.endSession(atSourceTime: self.lastVideoTime)
            self.writer.finishWriting {
                let result: Result<URL, Error> = self.writer.status == .completed
                    ? .success(self.url) : .failure(self.writer.error ?? RecorderError.cannotAddInput)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}
