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

/// Takes the frames and the audio of a running recording: `MirrorRecorder`, in the tests a
/// stand-in that notes what it gets.
protocol FrameRecording: AnyObject {
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
}

extension MirrorRecorder: FrameRecording {}

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
    private var activeRecording: FrameRecording?
    private var activeProcessor: FrameProcessor?
    /// time of the last frame given to the recording
    private var lastTime = CMTime.invalid
    /// host time and lag of the recent frames: how far their times lay behind "now" (cable:
    /// the capture delay, which varies a little; 0 otherwise)
    private var recentLags: [(arrival: CMTime, lag: CMTime)] = []
    /// a frame changed by the processor went to the display since the last `clear`
    private var showedProcessed = false

    /// on the main thread: new frame size (e.g. rotation)
    var onSizeChange: ((CGSize) -> Void)?
    /// on the main thread: first frame after attach/clear
    var onFirstFrame: (() -> Void)?
    private var deliveredFirstFrame = false

    /// how long without a new frame makes the screen count as still (about three frames)
    private static let stillAfter = CMTime(value: 50, timescale: 1000)
    /// for a frame shown again on a still screen, the delays of the frames of the last second
    /// before it went still count
    private static let lagMemory = CMTime(value: 1, timescale: 1)

    /// host time "now"; the tests hand in a clock of their own
    private let clock: () -> CMTime

    init(clock: @escaping () -> CMTime = { MirrorRecorder.now }) {
        self.clock = clock
    }

    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    /// active recording (receives every frame and the audio)
    var recorder: MirrorRecorder? {
        get { recording as? MirrorRecorder }
        set { recording = newValue }
    }

    /// what receives the frames and the audio of `recorder`
    var recording: FrameRecording? {
        get { lock.lock(); defer { lock.unlock() }; return activeRecording }
        set { lock.lock(); activeRecording = newValue; lock.unlock() }
    }

    func recordAudio(_ sampleBuffer: CMSampleBuffer) {
        recording?.appendAudio(sampleBuffer)
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
        presenting.lock()
        defer { presenting.unlock() }
        lock.lock()
        // The flush keeps the picture on the screen but drops what is queued. Translate may have
        // been turned off just before (the device went away) and its clean frame still be in the
        // queue, behind a picture with the translations: that frame is shown again afterwards.
        let restore = showedProcessed ? latestSourceBuffer : nil
        let description = formatDescription
        showedProcessed = false
        latestBuffer = nil
        latestSourceBuffer = nil
        deliveredFirstFrame = false
        lastTime = .invalid
        recentLags = []
        let layer = self.layer
        lock.unlock()
        layer?.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        if let layer, let restore, let description,
           CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: restore) {
            Self.enqueue(restore, description: description, on: layer)
        }
    }

    /// time: host time of the frame (for recordings); "now" if omitted
    func push(_ pixelBuffer: CVPixelBuffer, time: CMTime? = nil) {
        presenting.lock()
        defer { presenting.unlock() }
        let now = clock()
        let time = time ?? now
        lock.lock()
        recentLags.append((now, max(.zero, CMTimeSubtract(now, time))))
        let oldest = CMTimeSubtract(now, Self.lagMemory)
        if let stale = recentLags.firstIndex(where: { $0.arrival >= oldest }), stale > 0 {
            recentLags.removeFirst(stale)
        }
        lock.unlock()
        present(pixelBuffer, time: time)
    }

    /// Runs the latest frame through the processor again and shows the result. A still screen
    /// sends no new frames, so this is how something that arrives later (a translation) gets
    /// into the picture and into a running recording.
    func redisplay() {
        presenting.lock()
        defer { presenting.unlock() }
        guard let source = latestSource else { return }
        // On the timeline of the source: a cable frame carries the time it was captured, a
        // little before it arrives, and the recording drops a frame that is not later than the
        // one before. This one must be later than the last frame, and earlier than the next
        // live one. While frames flow, that one is due any moment and its delay may be a few
        // milliseconds longer than the last one's, so this one lies just a microsecond after
        // the last frame. On a still screen it moves on with the time that has passed, less
        // the longest delay of the recent frames.
        lock.lock()
        let now = clock()
        let afterLast = lastTime.isValid ? CMTimeAdd(lastTime, CMTime(value: 1, timescale: 1_000_000)) : now
        var time = afterLast
        let flowing = recentLags.last.map { CMTimeSubtract(now, $0.arrival) < Self.stillAfter } ?? false
        if !flowing {
            let longestLag = recentLags.map(\.lag).max() ?? .zero
            time = max(CMTimeSubtract(now, longestLag), afterLast)
        }
        lock.unlock()
        present(source, time: time)
    }

    private func present(_ source: CVPixelBuffer, time: CMTime) {
        let pixelBuffer = processor?.process(source, time: time) ?? source
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        lock.lock()
        latestSourceBuffer = source
        latestBuffer = pixelBuffer
        lastTime = lastTime.isValid ? max(lastTime, time) : time
        if pixelBuffer !== source { showedProcessed = true }
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
        let recorder = activeRecording
        lock.unlock()

        recorder?.appendVideo(pixelBuffer, at: time)

        if sizeChanged || first {
            DispatchQueue.main.async { [weak self] in
                if sizeChanged { self?.onSizeChange?(size) }
                if first { self?.onFirstFrame?() }
            }
        }

        guard let layer, let description else { return }
        Self.enqueue(pixelBuffer, description: description, on: layer)
    }

    private static func enqueue(_ pixelBuffer: CVPixelBuffer, description: CMVideoFormatDescription,
                                on layer: AVSampleBufferDisplayLayer) {
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

#if DEBUG
extension FrameSink {
    /// Debug builds: the latest frame as the device sent it and as it is shown, read while no
    /// other frame can be presented, so that `body` sees both of one and the same frame (and
    /// whatever the processor placed into it).
    func debugSnapshot<T>(_ body: (_ source: CVPixelBuffer?, _ shown: CVPixelBuffer?) -> T) -> T {
        presenting.lock()
        defer { presenting.unlock() }
        return body(latestSource, latest)
    }
}
#endif
