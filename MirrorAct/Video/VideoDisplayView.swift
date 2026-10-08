// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CoreMedia

/// Zeigt CVPixelBuffer sofort an (AVSampleBufferDisplayLayer, "DisplayImmediately").
final class VideoDisplayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { displayLayer }

    override var mouseDownCanMoveWindow: Bool { true }

    var cornerRadius: CGFloat {
        get { displayLayer.cornerRadius }
        set { displayLayer.cornerRadius = newValue }
    }
}

/// Nimmt Bilder aus beliebigen Threads entgegen, merkt sich das letzte (für Screenshots)
/// und reicht sie an die Anzeige weiter.
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var lastSize: CGSize = .zero
    private var layer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var activeRecorder: MirrorRecorder?

    /// auf dem Main-Thread: neue Bildgrösse (z. B. Drehung)
    var onSizeChange: ((CGSize) -> Void)?
    /// auf dem Main-Thread: erstes Bild nach attach/clear
    var onFirstFrame: (() -> Void)?
    private var deliveredFirstFrame = false

    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    /// laufende Aufnahme (bekommt jedes Bild und den Ton)
    var recorder: MirrorRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return activeRecorder }
        set { lock.lock(); activeRecorder = newValue; lock.unlock() }
    }

    func recordAudio(_ sampleBuffer: CMSampleBuffer) {
        recorder?.appendAudio(sampleBuffer)
    }

    var latest: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    var size: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return lastSize
    }

    func clear() {
        lock.lock()
        latestBuffer = nil
        deliveredFirstFrame = false
        let layer = self.layer
        lock.unlock()
        layer?.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    /// time: Host-Zeit des Bildes (für Aufnahmen); ohne Angabe "jetzt"
    func push(_ pixelBuffer: CVPixelBuffer, time: CMTime? = nil) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        lock.lock()
        latestBuffer = pixelBuffer
        let sizeChanged = size != lastSize
        lastSize = size
        let first = !deliveredFirstFrame
        deliveredFirstFrame = true
        let layer = self.layer
        if sizeChanged || formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &description)
            formatDescription = description
        }
        let description = formatDescription
        let recorder = activeRecorder
        lock.unlock()

        recorder?.appendVideo(pixelBuffer, at: time ?? MirrorRecorder.now)

        if sizeChanged || first {
            DispatchQueue.main.async { [weak self] in
                if sizeChanged { self?.onSizeChange?(size) }
                if first { self?.onFirstFrame?() }
            }
        }

        guard let layer, let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }
}
