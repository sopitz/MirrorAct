// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import CoreMedia
import CoreVideo
import Foundation

/// Translates the text on the mirrored screen in place.
///
/// While it is on, every frame passes through `process` (it is the sink's `FrameProcessor`): the
/// `OverlayTracker` moves the known paragraphs with the content and the `TranslationCompositor`
/// draws their translations into a copy of the frame. Display, screenshots and recordings
/// therefore all show the translations, exactly on their text, also while it scrolls.
/// Reading the picture (Vision) and translating run beside the frames; the text recognition
/// always gets the frame as the device sent it.
final class ScreenTranslator: ObservableObject, FrameProcessor, @unchecked Sendable {
    /// on the main thread
    @Published private(set) var isActive = false

    /// short notices for the user, called on the main thread
    var onMessage: ((String) -> Void)?

    private let sink: FrameSink
    private let compositor = TranslationCompositor()

    /// protects everything below up to `tasks`; never held while reading, translating or drawing
    private let state = NSLock()
    private let tracker = OverlayTracker()
    private var running = false
    /// Counts the turns of translating. Work of an earlier turn that is still on its way when
    /// translating is turned off and on again (another language …) must not reach this one.
    private var turn = 0
    /// the frame given to the last `advance`, as the device sent it
    private var source: CVPixelBuffer?
    private var wakeRecognition: AsyncStream<Void>.Continuation?
    private var wakeTranslation: AsyncStream<Void>.Continuation?

    private var tasks: [Task<Void, Never>] = []
    private var engine: TranslationEngine?
    private var settingsChanges: AnyCancellable?
    private var lastNotice: (text: String, time: TimeInterval)?

    /// texts per translation request
    private static let batchSize = 40
    /// longest wait for a scrolling picture to rest before a remote engine is asked anyway
    private static let longestWaitForRest: TimeInterval = 1.5

    init(sink: FrameSink) {
        self.sink = sink
    }

    /// seconds of a steady clock, for the tracker
    private static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func locked<T>(_ body: () -> T) -> T {
        state.lock()
        defer { state.unlock() }
        return body()
    }

    /// Whether `turn` is the turn that is on. Call with `state` held.
    private func isCurrent(_ turn: Int) -> Bool {
        running && self.turn == turn
    }

    // MARK: On and off (main thread)

    @MainActor
    func toggle() {
        isActive ? stop() : start()
    }

    @MainActor
    func start() {
        guard !isActive else { return }
        guard sink.latestSource != nil else {
            NSSound.beep()
            onMessage?(String(localized: "No video to translate yet"))
            return
        }
        let settings = AppSettings.shared
        let engine: TranslationEngine
        do {
            engine = try TranslationEngines.make(for: settings)
        } catch {
            NSSound.beep()
            onMessage?(error.localizedDescription)
            return
        }
        let target = settings.translationTarget
        self.engine = engine
        engine.notify = { [weak self] message in
            DispatchQueue.main.async { self?.onMessage?(message) }
        }
        Log.info("Translating the screen with \(engine.name) into \(target.minimalIdentifier)")

        let (recognitions, wakeRecognition) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (translations, wakeTranslation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let turn: Int = locked {
            tracker.reset()
            source = nil
            running = true
            self.turn += 1
            self.wakeRecognition = wakeRecognition
            self.wakeTranslation = wakeTranslation
            return self.turn
        }
        isActive = true
        tasks = [
            Task { [weak self] in await self?.recognitionLoop(recognitions, turn: turn) },
            Task { [weak self] in await self?.translationLoop(translations, engine: engine, target: target, turn: turn) },
        ]
        // another language, engine, model or key: start over with it
        settingsChanges = settings.translationSettingsChanged
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.stop()
                    self.start()
                }
            }
        sink.processor = self
        // the picture may be still: run the current frame through the tracker to start reading
        sink.redisplay()
        if engine.isRemote {
            onMessage?(String(localized: "Translating with \(engine.name) – the text on the screen is sent there"))
        }
    }

    @MainActor
    func stop() {
        guard isActive else { return }
        isActive = false
        settingsChanges = nil
        locked {
            running = false
            source = nil
            wakeRecognition?.finish()
            wakeTranslation?.finish()
            wakeRecognition = nil
            wakeTranslation = nil
        }
        sink.processor = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        engine?.cancel()
        engine?.notify = nil
        engine = nil
        compositor.reset()
        // a still picture would keep the translations until the next frame
        sink.redisplay()
    }

    // MARK: Frames (thread that delivers them)

    func process(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CVPixelBuffer {
        guard let thumbnail = FramePixels.thumbnail(of: pixelBuffer) else { return pixelBuffer }
        state.lock()
        guard running else {
            state.unlock()
            return pixelBuffer
        }
        let update = tracker.advance(thumbnail.image, scale: thumbnail.scale, time: Self.clock)
        source = pixelBuffer
        let wake = update.recognitionDue == nil ? nil : wakeRecognition
        state.unlock()
        wake?.yield()
        // The compositor draws into a copy in the frame's own pixel format, so a frame without
        // translations can be shown as it is.
        guard !update.placed.isEmpty else { return pixelBuffer }
        return compositor.compose(pixelBuffer, blocks: update.placed) ?? pixelBuffer
    }

    // MARK: Reading the picture

    private func recognitionLoop(_ wakeups: AsyncStream<Void>, turn: Int) async {
        for await _ in wakeups {
            while !Task.isCancelled {
                guard let due = locked({ isCurrent(turn) ? tracker.recognitionDue : nil }) else { break }
                let wait = due - Self.clock
                if wait > 0 {
                    // in short steps: scrolling can make the reading due at once
                    try? await Task.sleep(nanoseconds: UInt64(min(wait, 0.015) * 1_000_000_000))
                    continue
                }
                if await !recognizeOnce(turn: turn) { break }
            }
        }
    }

    /// One pass; false = nothing was started
    private func recognizeOnce(turn: Int) async -> Bool {
        let started: (frame: CVPixelBuffer, request: RecognitionRequest)? = locked {
            guard isCurrent(turn), let frame = source, let request = tracker.beginRecognition(time: Self.clock) else {
                return nil
            }
            return (frame, request)
        }
        guard let started else { return false }
        let frame = started.frame, request = started.request

        guard let lines = await TextRecognizer.recognize(frame, region: request.isFullFrame ? nil : request.region) else {
            locked {
                if isCurrent(turn) { tracker.abandonRecognition(request) }
            }
            // do not retry a failing recognition in a tight loop
            try? await Task.sleep(nanoseconds: 500_000_000)
            return true
        }
        let blocks = recognizedBlocks(from: lines, in: frame)
        let finished: (wake: AsyncStream<Void>.Continuation?, known: [TrackedBlock])? = locked {
            guard isCurrent(turn) else { return nil }
            tracker.finishRecognition(request, blocks: blocks, time: Self.clock)
            return (wakeTranslation, tracker.blocks)
        }
        guard let finished else { return false }
        finished.wake?.yield()
        // Blocks whose translation is known already (text that came back into view) are drawn
        // here, so that Core Text does not hold up the frames.
        compositor.prepare(finished.known)
        // blocks may have gone or moved on a picture that is still
        sink.redisplay()
        return true
    }

    /// Paragraphs worth translating, in frame pixels, with the colors to draw them in
    private func recognizedBlocks(from lines: [RecognizedLine], in frame: CVPixelBuffer) -> [RecognizedBlock] {
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let paragraphs = TextLayout.blocks(lines, imageSize: size).filter { TextLayout.isTranslatable($0.text) }
        return paragraphs.map { paragraph in
            let rect = CGRect(x: paragraph.rect.minX * size.width, y: paragraph.rect.minY * size.height,
                              width: paragraph.rect.width * size.width, height: paragraph.rect.height * size.height)
            // the frame's own colors, so that a box matches its surroundings exactly
            let colors = FramePixels.blockColors(in: rect, of: frame)
            return RecognizedBlock(text: paragraph.text, rect: rect, lineCount: paragraph.lineCount, colors: colors,
                                   confidence: paragraph.confidence)
        }
    }

    // MARK: Translating

    private func translationLoop(_ wakeups: AsyncStream<Void>, engine: TranslationEngine, target: Locale.Language,
                                 turn: Int) async {
        for await _ in wakeups {
            while !Task.isCancelled {
                if engine.prefersSettledText { await waitForRest(turn: turn) }
                let texts = locked {
                    isCurrent(turn) ? tracker.textsAwaitingTranslation(limit: Self.batchSize, time: Self.clock) : []
                }
                if texts.isEmpty { break }
                do {
                    let translations = try await engine.translate(texts, into: target)
                    // turned off (and on again, perhaps into another language) meanwhile
                    let postponed: Bool? = locked {
                        guard isCurrent(turn) else { return nil }
                        var postponed = false
                        for (index, text) in texts.enumerated() {
                            if index < translations.count, let translation = translations[index] {
                                tracker.setTranslation(translation, for: text)
                            } else {
                                // "not now" (a language is still loading …): offered again after a pause
                                tracker.translationFailed(for: text, time: Self.clock)
                                postponed = true
                            }
                        }
                        return postponed
                    }
                    guard let postponed else { return }
                    // draw the texts here, not on the thread that delivers the frames
                    compositor.prepare(locked { tracker.blocks })
                    sink.redisplay()
                    if postponed { wakeTranslationLater(turn: turn) }
                } catch {
                    let stillOn: Bool = locked {
                        guard isCurrent(turn) else { return false }
                        for text in texts { tracker.translationFailed(for: text, time: Self.clock) }
                        return true
                    }
                    if Task.isCancelled || !stillOn { return }
                    await failed(error, turn: turn)
                    break
                }
            }
        }
    }

    /// Waits until the picture has stopped moving, but not forever.
    private func waitForRest(turn: Int) async {
        let start = Self.clock
        while !Task.isCancelled, Self.clock - start < Self.longestWaitForRest {
            if locked({ !isCurrent(turn) || tracker.isSettled(at: Self.clock) }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func failed(_ error: Error, turn: Int) async {
        let failure = error as? TranslationFailure
        let message = failure?.message ?? String(localized: "Translation failed: \(error.localizedDescription)")
        Log.error("Translation: \(message)")
        await MainActor.run {
            // a failure of an earlier turn neither shows nor turns off the one that is on now
            guard locked({ isCurrent(turn) }) else { return }
            // the same notice at most every ten seconds
            let now = Self.clock
            if lastNotice?.text != message || now - (lastNotice?.time ?? 0) > 10 {
                lastNotice = (message, now)
                onMessage?(message)
            }
            if failure?.isPermanent == true { stop() }
        }
        guard failure?.isPermanent != true else { return }
        wakeTranslationLater(turn: turn)
    }

    /// Texts whose translation failed or was postponed are offered again by the tracker after
    /// `retryDelay`; nothing else would wake the loop on a still picture.
    private func wakeTranslationLater(turn: Int) {
        let retry = OverlayTracker.Configuration().retryDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((retry + 0.2) * 1_000_000_000))
            guard let self else { return }
            let wake = self.locked { self.isCurrent(turn) ? self.wakeTranslation : nil }
            wake?.yield()
        }
    }
}
