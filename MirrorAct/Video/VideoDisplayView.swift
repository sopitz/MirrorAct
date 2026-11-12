// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CoreMedia

/// Displays CVPixelBuffers immediately (AVSampleBufferDisplayLayer, "DisplayImmediately").
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

    /// Corner radius of the screen when all four corners are equal
    var cornerRadius: CGFloat {
        get { displayLayer.cornerRadius }
        set { displayLayer.cornerRadius = newValue }
    }

    /// Outline of the screen when its corners differ (e.g. at a hinge), as a mask, in this view's
    /// coordinates (y down, like the frame); nil = rectangle with `cornerRadius`
    var screenPath: CGPath? {
        didSet {
            guard let screenPath else { displayLayer.mask = nil; return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let mask = displayLayer.mask as? CAShapeLayer ?? CAShapeLayer()
            // the layer is not flipped: y up
            var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
            mask.frame = bounds
            mask.path = screenPath.copy(using: &flip)
            displayLayer.mask = mask
            CATransaction.commit()
        }
    }
}

/// Sees every frame before it is shown and recorded and may replace it, e.g. with a copy that
/// has the translations drawn in. Called on the thread that delivers the frame, one call at a time.
protocol FrameProcessor: AnyObject {
    func process(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CVPixelBuffer
}

/// Accepts frames from any thread, keeps the latest one (for screenshots)
/// and passes them on to the display.
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    /// held while a frame is processed and shown, so that frames stay in order
    private let presenting = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var latestSourceBuffer: CVPixelBuffer?
    private var lastSize: CGSize = .zero
    private var layer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var activeRecorder: MirrorRecorder?
    private var activeProcessor: FrameProcessor?

    /// on the main thread: new frame size (e.g. rotation)
    var onSizeChange: ((CGSize) -> Void)?
    /// on the main thread: first frame after attach/clear
    var onFirstFrame: (() -> Void)?
    private var deliveredFirstFrame = false

    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    /// active recording (receives every frame and the audio)
    var recorder: MirrorRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return activeRecorder }
        set { lock.lock(); activeRecorder = newValue; lock.unlock() }
    }

    func recordAudio(_ sampleBuffer: CMSampleBuffer) {
        recorder?.appendAudio(sampleBuffer)
    }

    /// changes the frames on their way to the display and the recorder (nil = shown as they arrive)
    var processor: FrameProcessor? {
        get { lock.lock(); defer { lock.unlock() }; return activeProcessor }
        set { lock.lock(); activeProcessor = newValue; lock.unlock() }
    }

    /// the latest frame as shown (with what the processor drew into it)
    var latest: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    /// the latest frame as the device sent it
    var latestSource: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestSourceBuffer
    }

    var size: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return lastSize
    }

    func clear() {
        lock.lock()
        latestBuffer = nil
        latestSourceBuffer = nil
        deliveredFirstFrame = false
        let layer = self.layer
        lock.unlock()
        layer?.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    /// time: host time of the frame (for recordings); "now" if omitted
    func push(_ pixelBuffer: CVPixelBuffer, time: CMTime? = nil) {
        presenting.lock()
        defer { presenting.unlock() }
        present(pixelBuffer, time: time ?? MirrorRecorder.now)
    }

    /// Runs the latest frame through the processor again and shows the result. A still screen
    /// sends no new frames, so this is how something that arrives later (a translation) gets
    /// into the picture and into a running recording.
    func redisplay() {
        presenting.lock()
        defer { presenting.unlock() }
        guard let source = latestSource else { return }
        present(source, time: MirrorRecorder.now)
    }

    private func present(_ source: CVPixelBuffer, time: CMTime) {
        let pixelBuffer = processor?.process(source, time: time) ?? source
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        lock.lock()
        latestSourceBuffer = source
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

        recorder?.appendVideo(pixelBuffer, at: time)

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
