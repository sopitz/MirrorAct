// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorAct

// Measures how well an `OverlayTracker` keeps translations on their text.
//
// `TrackingBench.run` plays a scenario of the simulator (TrackingSimulator.swift) and stands in
// for everything around the tracker, call for call the way `ScreenTranslator` drives it:
// - Time advances in ticks of 1/60 s. A frame arrives up to a fifth of a tick late; results of
//   the recognition and the translator come in 4 ms before a frame, so times never repeat.
// - `advance` for every frame the source sends: 60 or 30 per second less the dropped ones, from
//   a wireless source only when the picture changed, from a cable also when it did not.
// - The loop that reads sleeps until an `advance` returns a `recognitionDue`. Awake, it looks at
//   `OverlayTracker.recognitionDue` every tick and calls `beginRecognition` once that time has
//   come; it goes back to sleep when the property is nil or `beginRecognition` returns nil. A
//   pass reads the frame given to the last `advance` and returns (0.05 s + 0.20 s × requested
//   area / frame area) ± 15 % later with what a recognizer would have found in that region:
//   the lines of every layer of the picture below the status bar (`TextLayout.content`) grouped
//   by `TextLayout.blocks`, in the pixels of that frame. A line of which less than 60 % can be
//   seen (hidden, or outside the region) is missing; from 60 to 95 % it is missing in half of
//   the cases and otherwise comes back with a
//   garbled text of its own and the visible part as rectangle. In a frame damaged by fast
//   motion (`SimLayer.loss`, 0…100) a line is missing in 0.3 × loss % of the cases: about one
//   in ten at 5 % of the view per frame. The edges of the rectangles are
//   off by a pixel or two, and now and then a line that was read before is read with one letter
//   changed. The confidence does not tell a cut line from a whole one: a cut line gets 0.3, 0.5
//   or 1, and one whole line in eight is always reported with 0.5 or 0.3. Scenarios with
//   `reportsConfidence` false deliver nil, as recognizers on other platforms may.
// - A pass that fails (`SimScenario.failingPasses`) ends with `abandonRecognition`; the loop
//   then pauses for half a second.
// - After every pass the translator is asked for work (`textsAwaitingTranslation`, at most 40
//   texts); it answers "T:" + text after its latency and is asked again until nothing is left.
//   A translator that prefers settled text first waits for `isSettled`, at most 1.5 s. Texts
//   that are put off (`SimScenario.postponedPercent`) get `translationFailed` the first time,
//   and the translator asks again 0.2 s after the tracker's retry delay.
// - After a pass and after a batch of translations the frame that arrived last goes through
//   `advance` once more (a redraw), also while frames keep arriving: the tracker sees the same
//   picture twice in the middle of a scroll.
// - A scenario with a `sequel` goes on with frames of another size (the phone was turned).
//
// What is measured
// ----------------
// A display frame is one tick of what the viewer sees: the last frame that arrived with the
// translations the last `advance` placed. Each placed translation is traced back through its
// "T:" text to the lines it stands for; where that text occurs several times, the occurrence
// nearest to the placed rectangle counts. A placed translation of which nothing would be drawn
// (an empty `visibleRect`, all of it outside of the frame, or a sliver no thicker than a
// thumbnail pixel) does not count as placed. A translation of an earlier reading of a paragraph
// shown over the rectangle of a newer reading of it (more or fewer of its lines: the contract's
// `TrackedBlock.isStale`) is on its text as long as it stays inside that paragraph; it is
// counted as `staleReadings`, gets no alignment samples and does not cover the paragraph.
// - misplaced (block × display frames): an edge of the rectangle is more than half a line
//   height away from the text; or nothing of the text can be seen; or the drawn part
//   (`visibleRect`, else `rect`) reaches more than one thumbnail pixel into something that lies
//   above the text (a bar, a button, a pop-up, a keyboard) or beyond what the layer of the text
//   shows; or the text is not on the screen, or cannot be traced back at all.
// - alignment error of the other blocks: distance between the centre of the placed rectangle
//   and that of the text, in frame pixels; separately for display frames in which the text
//   moved and those in which it did not. Jitter is the change of that error from one display
//   frame to the next.
// - coverage: of the display frames × paragraphs that are completely visible and have been for
//   longer than the allowance, the share on which one correctly placed translation covers the
//   whole paragraph. Allowance = 0.4 s for reading + 0.1 s grace, and unless the translation
//   of the text had been delivered before: + 2 × the latency of the translator (+ 1.5 s when
//   it waits for rest; + the retry delay for a text that is put off). Counted separately for
//   text that moved during the last 0.1 s and text at rest.
// - latency: time from "completely visible" to "first covered" for paragraphs that scrolled
//   into view, less the latency of the translator where the translation was new.
// - flicker: how often a paragraph that stayed completely visible got its translation back
//   after losing it.
// - half-read: translations of a line the recognition saw only a part of, and translations of
//   only some of the lines of a paragraph that has been completely visible for longer than the
//   allowance (block × display frames, and how often one appeared).
// - cost: recognition passes and their total area; translation requests; texts drawn (a text is
//   drawn again whenever the id, the text, the rounded size or the line count of its block
//   changes: `BlockTextCache`); the time of `advance`.
// - contract slips (reported, and a regression test fails on any): `FrameUpdate.recognitionDue`
//   differs from the property, a wrong `FrameChange` for the first frame, a new size or an
//   identical picture, movement reported without `.scrolled`, a recognition region outside of
//   the frame or `isFullFrame` not matching it, `beginRecognition` nil although it was due.
// - not scored, for finding out why: the error of `FrameUpdate.scrollX/Y` against the true
//   movement of the largest moving part of the picture.
//
// Score (0…100 per scenario; the overall score is the mean over scenarios and seeds)
// ---------------------------------------------------------------------------------
//   score = 100 × M × W × (0.25 Cr (0.7 + 0.3 Ar) + 0.30 Cm (0.5 + 0.5 Am) + 0.15 L
//                          + 0.20 C·F + 0.10 C·K)
//
//   M   misplacement    exp(−s / 0.5), s = misplaced block × display frames / 60 (block
//                       seconds): 0.1 s costs a sixth of the score, 1 s almost all of it
//   W   waste           1 while the area read stays below three times its budget, beyond that
//                       √(3 × budget / area): reading a still screen over and over
//   Cr  coverage at rest, Cm coverage of moving text: covered / due paragraph × display frames
//                       (C: both together, weighted like their terms)
//   Ar  alignment at rest: a(mean error); Am while moving: 0.6 a(mean error) + 0.4 j(mean
//                       jitter); in thumbnail pixels, a falls from 1 at 0.5 to 0 at 2.5,
//                       j from 1 at 0.25 to 0 at 1.25
//   L   latency         0.6 l(median) + 0.4 l(95th percentile): l falls from 1 at 0.15 s
//                       (0.3 s for the percentile) to 0 at 0.75 s (1.5 s); a paragraph that
//                       scrolled in and never got a translation within its allowance counts
//                       as 3 s
//   F   tidiness        1 / (1 + 5 × (flickers + half-read translations that appeared)
//                       / paragraphs that were covered at some time)
//   K   cost            0.5 k(area read / budget) + 0.25 k(translation requests / budget)
//                       + 0.25 k(texts drawn / budget): k is 1 up to the budget and falls to 0
//                       at three times the budget. Budgets: area = 1.5 frames + 2 × what
//                       scrolled into view or changed; requests = 3 + 1.5 × the paragraphs
//                       that were completely visible at some time; drawn texts = 4 + 3 × those
//                       paragraphs + 1.5 × each time a paragraph was seen in another picture of
//                       itself (a step of a zoom or a fade). The time of `advance` is reported, not scored: it depends
//                       on the machine and the build.
//   A term whose input does not occur gives its weight to the coverage at rest: Cm when no
//   text that was due ever moved, L when nothing scrolled into view or the translator waits
//   for rest. Misplacement multiplies everything, so it weighs far more than missing coverage;
//   drawing nothing gives 0.

// MARK: - What is measured

/// The tracker, or a stand-in that is driven like one
protocol TrackingSubject: AnyObject {
    /// The picture of this tick of this scenario comes next (for stand-ins that know the truth)
    func prepare(_ scenario: SimScenario, tick: Int)
    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate
    var recognitionDue: TimeInterval? { get }
    func beginRecognition(time: TimeInterval) -> RecognitionRequest?
    func finishRecognition(_ request: RecognitionRequest, blocks: [RecognizedBlock], time: TimeInterval)
    func abandonRecognition(_ request: RecognitionRequest)
    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String]
    func setTranslation(_ translation: String, for text: String)
    func translationFailed(for text: String, time: TimeInterval)
    func isSettled(at time: TimeInterval) -> Bool
    /// The paragraphs known on the current frame, as `OverlayTracker.blocks`: the caller draws
    /// their texts ahead of time. A stand-in may return none.
    var blocks: [TrackedBlock] { get }
    /// It is the real tracker: what the contract says about `FrameUpdate` is checked
    var followsContract: Bool { get }
}

/// The real thing
final class OverlayTrackerSubject: TrackingSubject {
    let tracker: OverlayTracker

    init(tracker: OverlayTracker = OverlayTracker()) {
        self.tracker = tracker
    }

    func prepare(_ scenario: SimScenario, tick: Int) {}

    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
        tracker.advance(thumbnail, scale: scale, time: time)
    }

    var recognitionDue: TimeInterval? { tracker.recognitionDue }

    func beginRecognition(time: TimeInterval) -> RecognitionRequest? {
        tracker.beginRecognition(time: time)
    }

    func finishRecognition(_ request: RecognitionRequest, blocks: [RecognizedBlock], time: TimeInterval) {
        tracker.finishRecognition(request, blocks: blocks, time: time)
    }

    func abandonRecognition(_ request: RecognitionRequest) {
        tracker.abandonRecognition(request)
    }

    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
        tracker.textsAwaitingTranslation(limit: limit, time: time)
    }

    func setTranslation(_ translation: String, for text: String) {
        tracker.setTranslation(translation, for: text)
    }

    func translationFailed(for text: String, time: TimeInterval) {
        tracker.translationFailed(for: text, time: time)
    }

    func isSettled(at time: TimeInterval) -> Bool {
        tracker.isSettled(at: time)
    }

    var blocks: [TrackedBlock] { tracker.blocks }

    var followsContract: Bool { true }
}

/// Everything measured in one run of one scenario
struct TrackingResult: Codable, Equatable {
    var scenario = ""
    var seed: UInt64 = 0
    var subject = ""

    /// 0…100
    var score = 0.0
    /// the factors of the score, 0…1 (see the top of this file)
    var misplacementFactor = 1.0
    var wasteFactor = 1.0
    /// coverage at rest and of moving text together
    var coverage = 1.0
    var coverageResting = 1.0
    /// nil = no text that was due ever moved
    var coverageMoving: Double?
    var alignmentResting = 0.0
    var alignmentMoving = 0.0
    var tidinessScore = 1.0
    /// nil = not scored: no paragraph scrolled into view, or the translator waits for rest
    var latencyScore: Double?
    var costScore = 1.0

    /// block × display frames with a translation that is not on its text
    var misplaced = 0
    /// of these: beside the text; text not visible; drawn over something above; text unknown
    var misplacedOffText = 0
    var misplacedHidden = 0
    var misplacedCovering = 0
    var misplacedUnknown = 0
    /// the most misplaced blocks in one display frame, and the longest run of display frames with any
    var misplacedMostAtOnce = 0
    var misplacedLongestRun = 0
    /// tick of the first display frame with one, −1 = none
    var misplacedFirstTick = -1
    /// block × display frames placed at all
    var placed = 0

    /// alignment error in frame pixels while the text moved
    var movingSamples = 0
    var movingMean = 0.0
    var moving95 = 0.0
    var movingMax = 0.0
    /// … and while it did not
    var restingSamples = 0
    var restingMean = 0.0
    var resting95 = 0.0
    var restingMax = 0.0
    /// change of the error between two display frames
    var jitterMovingMean = 0.0
    var jitterMoving95 = 0.0
    var jitterRestingMean = 0.0

    /// paragraph × display frames on which a translation was due, and on which there was one
    var dueParagraphFrames = 0
    var coveredParagraphFrames = 0
    /// of these: while the text moved
    var dueMoving = 0
    var coveredMoving = 0
    /// seconds from completely visible to covered, for paragraphs that scrolled into view
    var latencyMedian = 0.0
    var latency95 = 0.0
    var latencySamples = 0
    var flickers = 0
    var coveredParagraphs = 0
    /// block × display frames with a translation of half-read text, and how often one appeared
    var halfRead = 0
    var halfReadStarts = 0
    /// block × display frames with the translation of an earlier reading of a paragraph over the
    /// rectangle of a newer one (allowed: `TrackedBlock.isStale`; not covered, not aligned)
    var staleReadings = 0

    /// error of `FrameUpdate.scrollX/Y` in frame pixels (not scored)
    var scrollErrorMean = 0.0
    var scrollErrorMax = 0.0
    /// what the tracker did that the contract does not allow
    var contractSlips = 0

    var frames = 0
    var redraws = 0
    /// milliseconds per `advance`: for pictures that differ from the one before, and for the
    /// same picture again; only meaningful in a release build
    var advanceChangedMs = 0.0
    var advanceSameMs = 0.0
    var advanceMaxMs = 0.0
    var passes = 0
    var failedPasses = 0
    /// total area of the recognition requests in frames
    var areaRead = 0.0
    var areaBudget = 0.0
    var translationRequests = 0
    var translationBatches = 0
    var translationBudget = 0.0
    /// texts the code that draws had to draw, and of these: not ahead of time from
    /// `OverlayTracker.blocks` but on the thread that delivers the frames
    var textsDrawn = 0
    var textsDrawnLate = 0
    var drawBudget = 0.0

    /// the first things that went wrong, with their ticks: for the message of a failing test
    var events: [String] = []

    /// The same without what differs from run to run
    var withoutTimes: TrackingResult {
        var copy = self
        copy.advanceChangedMs = 0
        copy.advanceSameMs = 0
        copy.advanceMaxMs = 0
        return copy
    }
}

/// What the display shows during one tick, for looking at a run (`TrackingBench.observer`)
struct TrackingFrameView {
    /// tick counted over all parts of the scenario
    var clock: Int
    var scenario: SimScenario
    /// tick of the frame that is shown, within `scenario`
    var shownTick: Int
    var placed: [PlacedBlock]
    /// one per placed block: "onText", "offText", "hidden", "covering", "unknown", "notDrawn"
    var verdicts: [String]
}

// MARK: - The bench

final class TrackingBench {
    static let translationPrefix = "T:"
    /// seconds a paragraph may be visible before its translation is expected: reading it …
    static let readingAllowance = 0.4
    /// … and a little more
    static let grace = 0.1
    /// longest wait of a translator that prefers settled text
    static let longestWaitForRest = 1.5
    static let batchSize = 40
    /// latency booked for a paragraph that was never covered although it had the time
    static let neverCovered = 3.0
    /// seconds the loop that reads pauses after a failed pass
    static let pauseAfterFailure = 0.5
    /// seconds after the tracker's retry delay at which the translator asks again
    static let retrySlack = 0.2
    /// frames that may be read: this many, plus `freshFactor` × what scrolled in or changed
    static let areaBase = 1.5
    static let freshFactor = 2.0
    /// a part of the picture that changes all the time earns its area once per so many ticks
    static let changeInterval = 30

    /// the scenario with all its parts
    let root: SimScenario
    /// the part that is being played
    private(set) var scenario: SimScenario
    /// Gets a line for every misplaced translation and every paragraph left without one
    var log: ((String) -> Void)?
    /// Gets every display frame with what was placed in it
    var observer: ((TrackingFrameView) -> Void)?

    private var random: SimRandom
    /// by sprite: first word of a text the recognition can return for a line → those texts
    private var readings: [[String: [Reading]]] = []
    /// by sprite: the lines a placed text can stand for, once worked out
    private var knownChains: [[String: [[Reading]]]] = []
    /// lines that were returned with their text at least once
    private var readBefore: Set<Int> = []
    /// source texts whose translation the tracker has received
    private var delivered: Set<String> = []
    /// how often the translation of a text was asked for
    private var attempts: [String: Int] = [:]
    /// the loop that reads pauses until this tick after a failed pass
    private var readerPausedUntil = 0

    init(scenario: SimScenario) {
        root = scenario
        self.scenario = scenario
        random = SimRandom(seed: scenario.seed).branch(0x7265_6164)
        begin(scenario)
    }

    /// A text the recognition can return for a line
    private struct Reading {
        var line: Int
        var words: [String]
        /// the rectangle returned for a line that was only seen in part, in pixels of the sprite;
        /// nil = the whole line
        var part: SimRect?
    }

    private func resetRun() {
        random = SimRandom(seed: root.seed).branch(0x7265_6164)
        readBefore = []
        delivered = []
        attempts = [:]
        readerPausedUntil = 0
        begin(root)
    }

    /// Makes `part` the scenario that is played: the texts its sprites can show
    private func begin(_ part: SimScenario) {
        scenario = part
        readings = []
        knownChains = []
        readBefore = []
        for sprite in part.sprites {
            var index: [String: [Reading]] = [:]
            for (number, line) in sprite.lines.enumerated() {
                let words = line.text.components(separatedBy: " ")
                index[words[0], default: []].append(Reading(line: number, words: words, part: nil))
                if line.alternate != line.text {
                    let other = line.alternate.components(separatedBy: " ")
                    index[other[0], default: []].append(Reading(line: number, words: other, part: nil))
                }
            }
            readings.append(index)
            knownChains.append([:])
        }
    }

    // MARK: Running a scenario

    private struct Pass {
        var request: RecognitionRequest
        var blocks: [RecognizedBlock]
        var startTick: Int
        var endTick: Int
        var fails: Bool
    }

    private struct Batch {
        var texts: [String]
        var postponed: Set<String>
        var endTick: Int
    }

    /// The state of the stand-in for the code around the tracker
    private struct Link {
        /// tick, within the part, of the frame that arrived last
        var shownTick: Int?
        var thumbnail: LumaImage?
        var placed: [PlacedBlock] = []
        var reportedScroll = CGPoint.zero
        var pass: Pass?
        var passesStarted = 0
        var batch: Batch?
        var isReaderAwake = false
        var isTranslatorAwake = false
        var translatorWakeAt: Int?
        var waitingSince: Int?
        var advances = 0
        var changedTime = 0.0
        var changedCount = 0
        var sameTime = 0.0
        var sameCount = 0
        var longest = 0.0
    }

    func run(_ subject: TrackingSubject, name: String = "") -> TrackingResult {
        resetRun()
        var tally = Tally()
        var link = Link()
        var firstTick = 0
        for (number, part) in root.parts.enumerated() {
            if number > 0 {
                begin(part)
                tally.beginSequel()
                link.shownTick = nil
                link.thumbnail = nil
            }
            for tick in 0..<part.tickCount {
                step(subject, tick: tick, clock: firstTick + tick, link: &link, tally: &tally)
            }
            firstTick += part.tickCount
        }

        var result = tally.result()
        result.scenario = root.name
        result.seed = root.seed
        result.subject = name
        result.advanceChangedMs = link.changedCount > 0 ? link.changedTime / Double(link.changedCount) * 1000 : 0
        result.advanceSameMs = link.sameCount > 0 ? link.sameTime / Double(link.sameCount) * 1000 : 0
        result.advanceMaxMs = link.longest * 1000
        // a translator that waits for rest decides when a translation arrives, not the tracker
        TrackingScore.rate(&result, scale: root.scale, scoresLatency: !root.translatorWaitsForRest)
        return result
    }

    /// Thousandths of a tick by which the frame of a tick is late, 0 ..< 200
    private func lateness(ofTick clock: Int) -> Int {
        var jitter = SimRandom(seed: root.seed ^ 0x6C61_7465).branch(UInt64(clock))
        return jitter.below(200)
    }

    /// One tick: results that came in, the frame, the loops that read and translate, the verdict
    private func step(_ subject: TrackingSubject, tick: Int, clock: Int, link: inout Link, tally: inout Tally) {
        let ticksPerSecond = Double(SimScenario.ticksPerSecond)
        let frameTime = (Double(clock) + Double(lateness(ofTick: clock)) / 1000) / ticksPerSecond
        let resultTime = frameTime - 0.004
        let loopTime = frameTime + 0.001

        // results that have come in since the last frame
        var wantsRedraw = false
        if let running = link.pass, running.endTick <= clock {
            link.pass = nil
            if running.fails {
                subject.abandonRecognition(running.request)
                let pause = Int((TrackingBench.pauseAfterFailure * ticksPerSecond).rounded(.up))
                readerPausedUntil = clock + pause
                tally.failedPasses += 1
                tally.excuse(ticks: clock - running.startTick + pause + 6)
            } else {
                subject.finishRecognition(running.request, blocks: running.blocks, time: resultTime)
                link.isTranslatorAwake = true
                wantsRedraw = true
            }
        }
        if let running = link.batch, running.endTick <= clock {
            link.batch = nil
            for text in running.texts {
                if running.postponed.contains(text) {
                    subject.translationFailed(for: text, time: resultTime)
                } else {
                    subject.setTranslation(TrackingBench.translationPrefix + text, for: text)
                    delivered.insert(text)
                }
            }
            if !running.postponed.isEmpty {
                let wait = TrackingBench.retryDelay + TrackingBench.retrySlack
                link.translatorWakeAt = clock + Int((wait * ticksPerSecond).rounded(.up))
            }
            // the texts of the blocks are drawn ahead of time, off the thread of the frames
            for block in subject.blocks {
                if let translation = block.translation, let key = DrawKey(id: block.id, text: translation, rect: block.rect,
                                                                         lineCount: block.lineCount) {
                    tally.prepared.insert(key)
                }
            }
            link.isTranslatorAwake = true
            wantsRedraw = true
        }
        if let wake = link.translatorWakeAt, wake <= clock {
            link.translatorWakeAt = nil
            link.isTranslatorAwake = true
        }
        // … are drawn at once: the frame that arrived last goes through the tracker again
        if wantsRedraw, let image = link.thumbnail, let shown = link.shownTick {
            advance(subject, image, shownTick: shown, time: resultTime + 0.0005, isSame: true, link: &link, tally: &tally)
            tally.redraws += 1
        }

        // the frame of this tick
        var isNewFrame = false
        var isSame = false
        if scenario.frameDue[tick] {
            if let last = link.shownTick {
                if scenario.pictureDiffers(tick, from: last) {
                    link.thumbnail = scenario.thumbnail(at: tick)
                    link.shownTick = tick
                    isNewFrame = true
                } else if !scenario.sendsOnlyChanges {
                    // a cable sends the same picture again
                    if scenario.noiseOnRepeats {
                        link.thumbnail = scenario.thumbnail(at: tick)
                    } else {
                        isSame = true
                    }
                    isNewFrame = true
                }
            } else {
                link.thumbnail = scenario.thumbnail(at: tick)
                link.shownTick = tick
                isNewFrame = true
            }
        }
        if isNewFrame, let image = link.thumbnail, let shown = link.shownTick {
            advance(subject, image, shownTick: shown, time: frameTime, isSame: isSame, link: &link, tally: &tally)
            tally.frames += 1
        }

        // the loop that reads
        if link.isReaderAwake, link.pass == nil, clock >= readerPausedUntil, let shown = link.shownTick {
            if let due = subject.recognitionDue {
                if due <= loopTime {
                    if let request = subject.beginRecognition(time: loopTime) {
                        start(request, shownTick: shown, clock: clock, link: &link, tally: &tally)
                    } else {
                        link.isReaderAwake = false
                        if subject.followsContract {
                            tally.slip("beginRecognition returned nil although recognitionDue had come", clock: clock,
                                       scenario: scenario.name, log: log)
                        }
                    }
                }
            } else {
                link.isReaderAwake = false
            }
        }

        // the loop that translates
        if link.batch == nil, link.isTranslatorAwake {
            var mayAsk = true
            if root.translatorWaitsForRest {
                let since = link.waitingSince ?? clock
                link.waitingSince = since
                let waited = Double(clock - since) / ticksPerSecond
                mayAsk = subject.isSettled(at: loopTime) || waited >= TrackingBench.longestWaitForRest
            }
            if mayAsk {
                link.waitingSince = nil
                let texts = subject.textsAwaitingTranslation(limit: TrackingBench.batchSize, time: loopTime)
                if texts.isEmpty {
                    link.isTranslatorAwake = false
                } else {
                    tally.translationRequests += texts.count
                    tally.translationBatches += 1
                    var postponed: Set<String> = []
                    for text in texts {
                        let attempt = (attempts[text] ?? 0) + 1
                        attempts[text] = attempt
                        if attempt == 1, isPutOff(text) { postponed.insert(text) }
                    }
                    let ticks = Int((root.translatorLatency * ticksPerSecond).rounded(.up))
                    link.batch = Batch(texts: texts, postponed: postponed, endTick: clock + max(1, ticks))
                }
            }
        }

        if let shown = link.shownTick {
            judge(link.placed, shownTick: shown, clock: clock, isNewFrame: isNewFrame && !isSame,
                  reportedScroll: link.reportedScroll, tally: &tally)
        }
    }

    /// One call of `advance`, timed
    private func advance(_ subject: TrackingSubject, _ image: LumaImage, shownTick: Int, time: TimeInterval, isSame: Bool,
                         link: inout Link, tally: inout Tally) {
        subject.prepare(scenario, tick: shownTick)
        let start = ProcessInfo.processInfo.systemUptime
        let update = subject.advance(image, scale: scenario.scale, time: time)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if isSame {
            link.sameTime += elapsed
            link.sameCount += 1
        } else {
            link.changedTime += elapsed
            link.changedCount += 1
        }
        link.longest = max(link.longest, elapsed)
        link.placed = update.placed
        link.reportedScroll = CGPoint(x: update.scrollX, y: update.scrollY)
        // the loop that reads is woken by an update that announces work
        if update.recognitionDue != nil { link.isReaderAwake = true }

        if subject.followsContract {
            var slips: [String] = []
            let due = subject.recognitionDue
            if (due == nil) != (update.recognitionDue == nil) || abs((due ?? 0) - (update.recognitionDue ?? 0)) > 1e-6 {
                slips.append("FrameUpdate.recognitionDue differs from OverlayTracker.recognitionDue")
            }
            if link.advances == 0, update.change != .first { slips.append("the first frame is not reported as .first") }
            if tally.lastSize.width > 0, tally.lastSize != CGSize(width: image.width, height: image.height) {
                if update.change != .resized { slips.append("a frame of another size is not reported as .resized") }
                if !update.placed.isEmpty { slips.append("translations placed on the first frame of another size") }
            } else if link.advances > 0, isSame, update.change != .unchanged {
                slips.append("the same picture again is reported as \(update.change)")
            }
            if update.change != .scrolled, update.scrollX != 0 || update.scrollY != 0 {
                slips.append("movement reported without .scrolled")
            }
            for text in slips {
                tally.slip(text, clock: Int((time * Double(SimScenario.ticksPerSecond)).rounded()), scenario: scenario.name,
                           log: log)
            }
        }
        tally.lastSize = CGSize(width: image.width, height: image.height)
        link.advances += 1
    }

    /// Starts a recognition pass on the frame that arrived last
    private func start(_ request: RecognitionRequest, shownTick: Int, clock: Int, link: inout Link, tally: inout Tally) {
        let frame = scenario.frameRect
        var region = frame
        if !request.isFullFrame {
            region = SimRect(covering: request.region).intersection(frame)
        }
        if TrackingBench.misfits(request, frame: frame, scale: scenario.scale) {
            tally.slip("recognition region \(TrackingBench.describe(request.region)) (isFullFrame \(request.isFullFrame)) "
                       + "does not fit the frame", clock: clock, scenario: scenario.name, log: log)
        }
        let share = Double(region.area) / Double(frame.area)
        link.passesStarted += 1
        tally.passes += 1
        tally.areaRead += share
        let fails = root.failingPasses.contains(link.passesStarted)
        // (a pass that the bench lets fail has to be made again: its area is not held against the tracker)
        if fails { tally.failedArea += share }
        let latency = (0.05 + 0.20 * share) * Double(85 + random.below(31)) / 100
        let ticks = Int((latency * Double(SimScenario.ticksPerSecond)).rounded(.up))
        link.pass = Pass(request: request, blocks: fails ? [] : recognize(region, tick: shownTick), startTick: clock,
                         endTick: clock + max(1, ticks), fails: fails)
    }

    /// The region of a request is empty, reaches out of the frame, or `isFullFrame` is wrong.
    /// The tracker never learns the size of the frame, only that of the thumbnail and the
    /// factor: the columns and rows that do not fill a whole cell of the thumbnail
    /// (`LumaImage.downsampled` leaves them out) are its to guess, so a region may end up to a
    /// cell short of or beyond the right and bottom edges.
    private static func misfits(_ request: RecognitionRequest, frame: SimRect, scale: Int) -> Bool {
        let region = request.region
        guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
              region.width >= 1, region.height >= 1 else { return true }
        let bounds = frame.cgRect
        let cell = CGFloat(scale)
        if region.minX < bounds.minX - 0.5 || region.minY < bounds.minY - 0.5 || region.maxX > bounds.maxX + cell
            || region.maxY > bounds.maxY + cell { return true }
        let isWhole = abs(region.minX) < 0.5 && abs(region.minY) < 0.5 && abs(region.maxX - bounds.maxX) < cell
            && abs(region.maxY - bounds.maxY) < cell
        return isWhole != request.isFullFrame
    }

    /// The first translation of this text is answered with "not now"
    private func isPutOff(_ text: String) -> Bool {
        guard root.postponedPercent > 0 else { return false }
        return Int(TrackingBench.hash(of: text, seed: root.seed) % 100) < root.postponedPercent
    }

    /// FNV-1a over the bytes of a text
    private static func hash(of text: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ seed
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        // the low bits of FNV are weak
        return hash >> 24
    }

    // MARK: The recognizer

    private struct ReadLine {
        var text: String
        var rect: CGRect
        var confidence: Double
        var background: UInt8
        var foreground: UInt8
    }

    /// How sure a recognizer is of a line it sees completely: always the same for the same text
    private func certainty(of text: String) -> Double {
        let draw = Int(TrackingBench.hash(of: text, seed: root.seed ^ 0x636F_6E66) % 100)
        return draw < 88 ? 1.0 : (draw < 97 ? 0.5 : 0.3)
    }

    /// What a recognizer returns for `region` of the frame of `tick` (of the part that is being
    /// played), the way the caller of the tracker passes it on: paragraphs worth translating,
    /// in frame pixels
    func recognize(_ region: SimRect, tick: Int) -> [RecognizedBlock] {
        guard !region.isEmpty else { return [] }
        let scene = scenario.scenes[tick]
        var blocks: [RecognizedBlock] = []
        var read: [ReadLine] = []
        var layerOfLines = -1
        for sight in scenario.lineSights(at: tick, within: region) {
            // Lines of different layers are never one paragraph. (`TextLayout.blocks` would now
            // and then join the title of a bar and a line that passes right below it.)
            if sight.layer != layerOfLines {
                blocks += paragraphs(of: read)
                read = []
                layerOfLines = sight.layer
            }
            let sprite = scenario.sprites[sight.sprite]
            let line = sprite.lines[sight.line]
            let share = sight.visibleArea * 1000 / max(1, line.rect.area)
            guard share >= 600 else { continue }
            let layer = scene.layers[sight.layer]
            // A frame of fast motion is damaged by the encoder: now and then a line cannot be read
            // at all. (Reading in motion is worth less than reading at rest.)
            if layer.loss > 0, random.below(100) < layer.loss * 3 / 10 { continue }
            var text = line.text
            var confidence = certainty(of: line.text)
            if share < 950 {
                // cut off: nothing to translate in it is simply not found; text is found half
                // of the time, but not read correctly – and the recognizer does not know
                guard line.isTranslatable, random.chance(50) else { continue }
                text = garbled(line.text, sprite: sight.sprite)
                let draw = random.below(10)
                confidence = draw < 4 ? 0.3 : (draw < 7 ? 0.5 : 1.0)
                let words = text.components(separatedBy: " ")
                readings[sight.sprite][words[0], default: []]
                    .append(Reading(line: sight.line, words: words, part: sight.visible.offsetBy(dx: -layer.x, dy: -layer.y)))
            } else {
                let key = sight.sprite << 24 | sight.line
                if readBefore.contains(key), line.alternate != line.text, random.chance(scenario.misreadingPercent) {
                    text = line.alternate
                }
                readBefore.insert(key)
            }
            // the box of a recognizer is never exact
            let noise = scenario.rectNoise(lineHeight: line.rect.height)
            let left = sight.visible.x + random.int(-noise, noise), top = sight.visible.y + random.int(-noise, noise)
            let right = max(left + 2, sight.visible.maxX + random.int(-noise, noise))
            let bottom = max(top + 2, sight.visible.maxY + random.int(-noise, noise))
            let paragraph = sprite.paragraphs[line.paragraph]
            read.append(ReadLine(text: text, rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                                 confidence: confidence, background: paragraph.background,
                                 foreground: paragraph.foreground))
        }
        blocks += paragraphs(of: read)
        return blocks
    }

    /// The lines of one layer as the paragraphs `TextLayout.blocks` makes of them
    private func paragraphs(of read: [ReadLine]) -> [RecognizedBlock] {
        guard !read.isEmpty else { return [] }
        let size = CGSize(width: scenario.frameWidth, height: scenario.frameHeight)
        let lines = read.map { line in
            RecognizedLine(text: line.text, rect: CGRect(x: line.rect.minX / size.width, y: line.rect.minY / size.height,
                                                         width: line.rect.width / size.width,
                                                         height: line.rect.height / size.height))
        }
        var blocks: [RecognizedBlock] = []
        for block in TextLayout.blocks(TextLayout.content(lines, imageSize: size), imageSize: size)
        where TextLayout.isTranslatable(block.text) {
            let rect = CGRect(x: (block.rect.minX * size.width).rounded(), y: (block.rect.minY * size.height).rounded(),
                              width: (block.rect.width * size.width).rounded(),
                              height: (block.rect.height * size.height).rounded())
            // its lines: for its colors, and it is as certain as the least certain of them
            var colors = BlockColors.blackOnWhite
            var confidence = 1.0
            var hasColors = false
            for line in read where TrackingBench.contains(rect, line.rect, slack: 0.5) && block.text.contains(line.text) {
                if !hasColors {
                    colors = BlockColors(background: TrackingBench.gray(line.background),
                                         foreground: TrackingBench.gray(line.foreground))
                    hasColors = true
                }
                confidence = min(confidence, line.confidence)
            }
            blocks.append(RecognizedBlock(text: block.text, rect: rect, lineCount: block.lineCount, colors: colors,
                                          confidence: root.reportsConfidence ? confidence : nil,
                                          cutOffEdges: block.cutOffEdges))
        }
        return blocks
    }

    /// `inner` lies inside `outer`. (Not `CGRect.contains`: outside of Apple's platforms it
    /// compares sums that rounding makes differ.)
    private static func contains(_ outer: CGRect, _ inner: CGRect, slack: CGFloat = 0) -> Bool {
        inner.minX >= outer.minX - slack && inner.maxX <= outer.maxX + slack
            && inner.minY >= outer.minY - slack && inner.maxY <= outer.maxY + slack
    }

    static func describe(_ rect: CGRect) -> String {
        String(format: "(%.1f, %.1f, %.1f × %.1f)", Double(rect.minX), Double(rect.minY), Double(rect.width),
               Double(rect.height))
    }

    private static func gray(_ level: UInt8) -> RGBColor {
        RGBColor(red: level, green: level, blue: level)
    }

    /// A text of its own that resembles `text`: about a third of its letters are wrong
    private func garbled(_ text: String, sprite: Int) -> String {
        var bytes = Array(text.utf8)
        while true {
            var hasLetters = false
            for index in bytes.indices where bytes[index] >= 97 && bytes[index] <= 122 {
                hasLetters = true
                if random.chance(35) { bytes[index] = 97 + UInt8(random.below(26)) }
            }
            if !hasLetters { bytes.append(97 + UInt8(random.below(26))) }
            let result = String(decoding: bytes, as: UTF8.self)
            if result != text, chains(for: result, sprite: sprite).isEmpty {
                // (the empty answer was remembered; the text is about to become known)
                knownChains[sprite][result] = nil
                return result
            }
        }
    }

    // MARK: Tracing a placed text back to its lines

    /// The lines of a sprite that `text` can stand for: it is one of the texts the recognition
    /// returned for a line, or several of them joined by spaces (lines of a paragraph, top to
    /// bottom). Every result is one possible sequence of lines; a text that occurs several
    /// times gives several.
    private func chains(for text: String, sprite: Int) -> [[Reading]] {
        if let known = knownChains[sprite][text] { return known }
        let index = readings[sprite]
        var found: [[Reading]] = []
        if !index.isEmpty {
            let words = text.components(separatedBy: " ")
            let lines = scenario.sprites[sprite].lines
            var steps = 0
            func extend(_ chain: [Reading], from position: Int) {
                if position == words.count {
                    found.append(chain)
                    return
                }
                guard let options = index[words[position]] else { return }
                for option in options {
                    steps += 1
                    guard found.count < 512, steps < 100_000 else { return }
                    let end = position + option.words.count
                    guard end <= words.count else { continue }
                    var matches = true
                    for offset in 1..<max(1, option.words.count) where words[position + offset] != option.words[offset] {
                        matches = false
                        break
                    }
                    guard matches else { continue }
                    if let last = chain.last, !TrackingBench.follows(lines[option.line].rect, lines[last.line].rect,
                                                                     isSameLine: option.line == last.line) { continue }
                    extend(chain + [option], from: end)
                }
            }
            extend([], from: 0)
        }
        knownChains[sprite][text] = found
        return found
    }

    /// A line at `below` can be the one after a line at `above` in a block of text
    private static func follows(_ below: SimRect, _ above: SimRect, isSameLine: Bool) -> Bool {
        !isSameLine && below.y >= above.y + above.height / 2 && below.y - above.maxY <= 2 * max(above.height, below.height)
    }

    // MARK: Judging a display frame

    private enum Verdict: String {
        case onText
        case offText
        case hidden
        case covering
        case unknown
        /// nothing of it would be drawn: it does not count
        case notDrawn
    }

    private struct Judgement {
        var verdict = Verdict.unknown
        /// of the text, when it was found in the frame
        var layer = -1
        var slot = -1
        var sprite = -1
        var lines: [Int] = []
        /// placed centre − centre of the text, in frame pixels
        var errorX = 0.0
        var errorY = 0.0
        /// the part of the frame the translation is drawn into
        var drawn = CGRect.zero
        /// where the text is
        var expected = CGRect.zero
        /// one of its lines was only seen in part when it was read
        var hasPartialLine = false
        /// the translation of an earlier reading of the paragraph, over the rectangle of a newer
        /// one: on its paragraph, but not aligned to anything (`expected` is the whole paragraph)
        var isStaleReading = false
    }

    /// A paragraph while it stays completely visible
    private struct Episode {
        var start: Int
        var allowance: Int
        var latencyOfTranslator: Double
        var scrolledIn: Bool
        var firstCovered: Int?
        var wasCovered = false
        var lastSeen: Int
    }

    /// What a drawn text is remembered by (`BlockTextCache.Key`)
    private struct DrawKey: Hashable {
        var id: Int
        var text: String
        var width: Int
        var height: Int
        var lineCount: Int

        /// nil for a rectangle that is not drawn (`BlockPlacement.textSize`)
        init?(id: Int, text: String, rect: CGRect, lineCount: Int) {
            let width = rect.width.rounded(), height = rect.height.rounded()
            guard width >= 1, height >= 1, width <= 8192, height <= 8192 else { return nil }
            self.id = id
            self.text = text
            self.width = Int(width)
            self.height = Int(height)
            self.lineCount = lineCount
        }
    }

    private struct Tally {
        var frames = 0
        var redraws = 0
        var passes = 0
        var failedPasses = 0
        var areaRead = 0.0
        var failedArea = 0.0
        var translationRequests = 0
        var translationBatches = 0
        var slips = 0
        var events: [String] = []
        var eventsOfKind: [String: Int] = [:]
        var lastSize = CGSize.zero

        var placed = 0
        var offText = 0
        var hidden = 0
        var covering = 0
        var unknown = 0
        var mostAtOnce = 0
        var longestRun = 0
        var run = 0
        var firstMisplaced = -1

        var moving: [Double] = []
        var resting: [Double] = []
        var jitterMoving: [Double] = []
        var jitterResting: [Double] = []
        /// error of each correctly placed text in the previous display frame
        var lastErrors: [Int: CGPoint] = [:]
        var scrollErrors: [Double] = []

        var dueMoving = 0
        var coveredMoving = 0
        var dueResting = 0
        var coveredResting = 0
        var flickers = 0
        var coveredParagraphs = 0
        var latencies: [Double] = []
        var episodes: [Int: Episode] = [:]
        var halfRead = 0
        var halfReadStarts = 0
        var staleReadings = 0
        /// the half-read translations of the previous display frame
        var halfReadBefore: Set<Int> = []

        /// the texts that were drawn, and those that were drawn ahead of time
        var drawn: Set<DrawKey> = []
        var prepared: Set<DrawKey> = []
        var drawnLate = 0

        /// the layers of the frame shown before the current one, by slot
        var layersBefore: [Int: SimLayer] = [:]
        var layersNow: [Int: SimLayer] = [:]
        /// the layers that moved in the current frame, and when each layer moved last
        var movedSlots: Set<Int> = []
        var lastMoved: [Int: Int] = [:]
        /// when the picture of each slot was exchanged last
        var lastExchanged: [Int: Int] = [:]
        /// frame areas that scrolled into view or changed
        var fresh = 0.0
        var seenTexts: Set<String> = []
        /// texts of paragraphs of which something could be seen, and those paragraphs by layer
        /// and picture: a text that is seen in several pictures of itself is drawn again
        var visibleTexts: Set<String> = []
        var visibleKeys: Set<Int> = []

        /// The text of a layer moved during the last tenth of a second
        func isMoving(slot: Int, clock: Int) -> Bool {
            guard let moved = lastMoved[slot] else { return false }
            return clock - moved <= 6
        }

        /// Frames of another size follow: nothing of the picture is left, a whole frame is new
        mutating func beginSequel() {
            layersBefore = [:]
            layersNow = [:]
            movedSlots = []
            lastMoved = [:]
            lastExchanged = [:]
            lastErrors = [:]
            halfReadBefore = []
            episodes = [:]
            fresh += 1
        }

        /// A recognition pass failed: translations that are not there yet may come later
        mutating func excuse(ticks: Int) {
            for key in Array(episodes.keys) {
                guard var episode = episodes[key], episode.firstCovered == nil else { continue }
                episode.allowance += ticks
                episode.scrolledIn = false
                episodes[key] = episode
            }
        }

        /// Keeps the first few events of each kind for the report of a failing test
        mutating func note(_ kind: String, _ text: String, limit: Int = 4) {
            let count = eventsOfKind[kind] ?? 0
            eventsOfKind[kind] = count + 1
            if count < limit { events.append(text) }
        }

        mutating func slip(_ text: String, clock: Int, scenario: String, log: ((String) -> Void)?) {
            slips += 1
            let line = "tick \(clock): contract: \(text)"
            note("slip " + text, line, limit: 1)
            log?("[tracking] \(scenario) \(line)")
        }

        func result() -> TrackingResult {
            var result = TrackingResult()
            result.frames = frames
            result.redraws = redraws
            result.passes = passes
            result.failedPasses = failedPasses
            result.areaRead = areaRead
            result.areaBudget = TrackingBench.areaBase + TrackingBench.freshFactor * fresh + failedArea
            result.translationRequests = translationRequests
            result.translationBatches = translationBatches
            result.translationBudget = 3 + 1.5 * Double(seenTexts.count)
            result.textsDrawn = drawn.count
            result.textsDrawnLate = drawnLate
            // (a paragraph seen in another picture of itself – a step of a zoom or a fade – is
            // drawn at another size, or anew)
            let otherPictures = max(0, visibleKeys.count - visibleTexts.count)
            result.drawBudget = 4 + 3 * Double(seenTexts.count) + 1.5 * Double(otherPictures)
            result.contractSlips = slips
            result.placed = placed
            result.misplaced = offText + hidden + covering + unknown
            result.misplacedOffText = offText
            result.misplacedHidden = hidden
            result.misplacedCovering = covering
            result.misplacedUnknown = unknown
            result.misplacedMostAtOnce = mostAtOnce
            result.misplacedLongestRun = longestRun
            result.misplacedFirstTick = firstMisplaced
            result.movingSamples = moving.count
            result.restingSamples = resting.count
            result.movingMean = TrackingScore.mean(moving)
            result.moving95 = TrackingScore.percentile(moving, 0.95)
            result.movingMax = moving.max() ?? 0
            result.restingMean = TrackingScore.mean(resting)
            result.resting95 = TrackingScore.percentile(resting, 0.95)
            result.restingMax = resting.max() ?? 0
            result.jitterMovingMean = TrackingScore.mean(jitterMoving)
            result.jitterMoving95 = TrackingScore.percentile(jitterMoving, 0.95)
            result.jitterRestingMean = TrackingScore.mean(jitterResting)
            result.dueParagraphFrames = dueMoving + dueResting
            result.coveredParagraphFrames = coveredMoving + coveredResting
            result.dueMoving = dueMoving
            result.coveredMoving = coveredMoving
            result.flickers = flickers
            result.coveredParagraphs = coveredParagraphs
            result.halfRead = halfRead
            result.halfReadStarts = halfReadStarts
            result.staleReadings = staleReadings
            result.latencySamples = latencies.count
            result.latencyMedian = TrackingScore.percentile(latencies, 0.5)
            result.latency95 = TrackingScore.percentile(latencies, 0.95)
            result.scrollErrorMean = TrackingScore.mean(scrollErrors)
            result.scrollErrorMax = scrollErrors.max() ?? 0
            result.events = events
            return result
        }
    }

    /// Books what the display shows during one tick: the frame of `shownTick` with `placed`
    private func judge(_ placed: [PlacedBlock], shownTick: Int, clock: Int, isNewFrame: Bool, reportedScroll: CGPoint,
                       tally: inout Tally) {
        let scene = scenario.scenes[shownTick]
        let painted = scenario.paintedRects(at: shownTick)
        let frameArea = Double(scenario.frameRect.area)
        let name = scenario.name

        // what moved or changed since the frame shown before
        if isNewFrame {
            let isFirst = tally.layersNow.isEmpty
            tally.layersBefore = tally.layersNow
            tally.layersNow = [:]
            tally.movedSlots = []
            var largest = 0
            var movement = CGPoint.zero
            for (index, layer) in scene.layers.enumerated() {
                tally.layersNow[layer.slot] = layer
                let hasText = !scenario.sprites[layer.sprite].paragraphs.isEmpty
                if let before = tally.layersBefore[layer.slot], before.sprite == layer.sprite {
                    let dx = layer.x - before.x, dy = layer.y - before.y
                    if dx != 0 || dy != 0 {
                        tally.movedSlots.insert(layer.slot)
                        tally.lastMoved[layer.slot] = clock
                        let area = painted[index]
                        if hasText {
                            let uncovered = min(area.area, abs(dy) * area.width + abs(dx) * area.height)
                            tally.fresh += Double(uncovered) / frameArea
                        }
                        if area.area > largest {
                            largest = area.area
                            movement = CGPoint(x: dx, y: dy)
                        }
                    }
                } else if !isFirst {
                    // A picture that was exchanged has to be looked at again, text or not; one
                    // that is exchanged all the time (a video, a fade) not every time.
                    let since = clock - (tally.lastExchanged[layer.slot] ?? -TrackingBench.changeInterval)
                    let share = Double(min(TrackingBench.changeInterval, since)) / Double(TrackingBench.changeInterval)
                    tally.fresh += Double(painted[index].area) / frameArea * share
                    tally.lastExchanged[layer.slot] = clock
                }
            }
            if !isFirst {
                let dx = Double(reportedScroll.x - movement.x), dy = Double(reportedScroll.y - movement.y)
                tally.scrollErrors.append((dx * dx + dy * dy).squareRoot())
            }
        }
        let sights = scenario.paragraphSights(at: shownTick)
        // paragraphs that have been completely visible for so long that they are read as a whole by now
        var settledParagraphs: Set<Int> = []
        for sight in sights where sight.isFullyVisible {
            if let episode = tally.episodes[sight.key], episode.lastSeen == clock - 1,
               clock - episode.start >= episode.allowance {
                settledParagraphs.insert(sight.key)
            }
        }

        // the placed translations
        var judgements: [Judgement] = []
        var verdicts: [String] = []
        var misplacedNow = 0
        var errorsNow: [Int: CGPoint] = [:]
        var halfReadNow: Set<Int> = []
        for block in placed {
            let judgement = judgement(of: block, scene: scene, painted: painted)
            if observer != nil { verdicts.append(judgement.verdict.rawValue) }
            if judgement.verdict == .notDrawn { continue }
            judgements.append(judgement)
            tally.placed += 1
            // the code that draws keeps a text until something about its block changes
            if let key = DrawKey(id: block.id, text: block.text, rect: block.rect, lineCount: block.lineCount),
               tally.drawn.insert(key).inserted, !tally.prepared.contains(key) {
                tally.drawnLate += 1
            }
            switch judgement.verdict {
            case .notDrawn: break
            case .offText: tally.offText += 1
            case .hidden: tally.hidden += 1
            case .covering: tally.covering += 1
            case .unknown: tally.unknown += 1
            case .onText:
                let error = (judgement.errorX * judgement.errorX + judgement.errorY * judgement.errorY).squareRoot()
                let isMoving = tally.isMoving(slot: judgement.slot, clock: clock)
                let key = (judgement.slot << 52) | (judgement.sprite << 40) | ((judgement.lines.first ?? 0) << 12)
                    | judgement.lines.count
                if judgement.isStaleReading {
                    tally.staleReadings += 1
                } else if isMoving {
                    tally.moving.append(error)
                } else {
                    tally.resting.append(error)
                }
                if judgement.isStaleReading {
                    // (no alignment to speak of)
                } else if let before = tally.lastErrors[key] {
                    let dx = judgement.errorX - Double(before.x), dy = judgement.errorY - Double(before.y)
                    let change = (dx * dx + dy * dy).squareRoot()
                    if isMoving {
                        tally.jitterMoving.append(change)
                    } else {
                        tally.jitterResting.append(change)
                    }
                }
                if !judgement.isStaleReading { errorsNow[key] = CGPoint(x: judgement.errorX, y: judgement.errorY) }
                if isHalfRead(judgement, settledParagraphs: settledParagraphs) {
                    tally.halfRead += 1
                    halfReadNow.insert(key)
                    if !tally.halfReadBefore.contains(key) {
                        tally.halfReadStarts += 1
                        tally.note("half", "tick \(clock): half-read text translated: \"\(block.text.prefix(40))\" at "
                                   + TrackingBench.describe(block.rect))
                    }
                }
            }
            if judgement.verdict != .onText {
                misplacedNow += 1
                let line = "tick \(clock) (frame of tick \(shownTick)): misplaced, \(judgement.verdict.rawValue): "
                    + "\"\(block.text.prefix(40))\" placed at \(TrackingBench.describe(block.rect))"
                    + (block.visibleRect.map { ", visible " + TrackingBench.describe($0) } ?? "")
                    + (judgement.layer >= 0 ? ", text at " + TrackingBench.describe(judgement.expected) : "")
                tally.note("misplaced", line, limit: 6)
                log?("[tracking] \(name) \(line)")
            }
        }
        tally.lastErrors = errorsNow
        tally.halfReadBefore = halfReadNow
        tally.mostAtOnce = max(tally.mostAtOnce, misplacedNow)
        tally.run = misplacedNow > 0 ? tally.run + 1 : 0
        tally.longestRun = max(tally.longestRun, tally.run)
        if misplacedNow > 0, tally.firstMisplaced < 0 { tally.firstMisplaced = clock }
        if let observer {
            observer(TrackingFrameView(clock: clock, scenario: scenario, shownTick: shownTick, placed: placed,
                                       verdicts: verdicts))
        }

        // the paragraphs that should carry a translation
        let ticksPerSecond = Double(SimScenario.ticksPerSecond)
        for sight in sights {
            let paragraph = scenario.sprites[sight.sprite].paragraphs[sight.paragraph]
            guard paragraph.isTranslatable else { continue }
            tally.visibleTexts.insert(paragraph.text)
            tally.visibleKeys.insert(sight.key)
        }
        for sight in sights where sight.isFullyVisible {
            let sprite = scenario.sprites[sight.sprite]
            let paragraph = sprite.paragraphs[sight.paragraph]
            guard paragraph.isTranslatable else { continue }
            tally.seenTexts.insert(paragraph.text)

            // covered: one translation that is on this text is drawn over all of it, give or
            // take a quarter of a line (the rectangles of a recognizer are not exact)
            var isCovered = false
            let rect = sight.rect.cgRect
            let slack = min(rect.width, rect.height / CGFloat(paragraph.lines.count)) / 4
            let core = rect.insetBy(dx: slack, dy: slack)
            for judgement in judgements where judgement.verdict == .onText && judgement.layer == sight.layer {
                guard paragraph.lines.allSatisfy({ judgement.lines.contains($0) }) else { continue }
                if TrackingBench.contains(judgement.drawn, core) {
                    isCovered = true
                    break
                }
            }

            var episode: Episode
            if let running = tally.episodes[sight.key], running.lastSeen == clock - 1 {
                episode = running
            } else {
                // newly complete: how long may its translation take?
                let isKnown = delivered.contains(paragraph.text)
                var allowance = TrackingBench.readingAllowance + TrackingBench.grace
                var isExcused = false
                if !isKnown {
                    allowance += 2 * root.translatorLatency
                    if root.translatorWaitsForRest { allowance += TrackingBench.longestWaitForRest }
                    if isPutOff(paragraph.text), (attempts[paragraph.text] ?? 0) < 2 {
                        allowance += TrackingBench.retryDelay + TrackingBench.retrySlack + 0.5
                        isExcused = true
                    }
                }
                var ticks = Int((allowance * ticksPerSecond).rounded(.up))
                if clock < readerPausedUntil {
                    ticks += readerPausedUntil - clock + 6
                    isExcused = true
                }
                episode = Episode(start: clock, allowance: ticks, latencyOfTranslator: isKnown ? 0 : root.translatorLatency,
                                  scrolledIn: clock > 0 && tally.movedSlots.contains(sight.slot) && !isExcused,
                                  lastSeen: clock)
            }
            episode.lastSeen = clock
            if isCovered {
                if episode.firstCovered == nil {
                    episode.firstCovered = clock
                    tally.coveredParagraphs += 1
                    if episode.scrolledIn {
                        let seconds = Double(clock - episode.start) / ticksPerSecond - episode.latencyOfTranslator
                        tally.latencies.append(max(0, seconds))
                    }
                } else if !episode.wasCovered {
                    tally.flickers += 1
                    tally.note("flicker", "tick \(clock): the translation of \"\(paragraph.text.prefix(40))\" at "
                               + TrackingBench.describe(rect) + " is back after it was gone")
                }
            }
            episode.wasCovered = isCovered
            if clock - episode.start >= episode.allowance {
                if tally.isMoving(slot: sight.slot, clock: clock) {
                    tally.dueMoving += 1
                    if isCovered { tally.coveredMoving += 1 }
                } else {
                    tally.dueResting += 1
                    if isCovered { tally.coveredResting += 1 }
                }
                // had its time and never got a translation
                if clock - episode.start == episode.allowance, episode.firstCovered == nil {
                    if episode.scrolledIn { tally.latencies.append(TrackingBench.neverCovered) }
                    let line = "tick \(clock): no translation on \"\(paragraph.text.prefix(40))\" at "
                        + TrackingBench.describe(rect) + ", completely visible since tick \(episode.start)"
                    tally.note("uncovered", line)
                    log?("[tracking] \(name) \(line)")
                }
            }
            tally.episodes[sight.key] = episode
        }
    }

    /// A translation of text that was not read as what it is: it contains a line of which the
    /// recognition saw only a part, or it has only some of the lines of a paragraph that has
    /// been completely visible for long enough to be read as a whole
    private func isHalfRead(_ judgement: Judgement, settledParagraphs: Set<Int>) -> Bool {
        if judgement.hasPartialLine { return true }
        let sprite = scenario.sprites[judgement.sprite]
        var checked: Set<Int> = []
        for line in judgement.lines {
            let paragraph = sprite.lines[line].paragraph
            guard paragraph >= 0, checked.insert(paragraph).inserted else { continue }
            let key = SimScenario.paragraphKey(slot: judgement.slot, sprite: judgement.sprite, paragraph: paragraph)
            guard settledParagraphs.contains(key) else { continue }
            for member in sprite.paragraphs[paragraph].lines where !judgement.lines.contains(member) {
                return true
            }
        }
        return false
    }

    /// Where is the text a placed translation belongs to, and is the translation on it?
    private func judgement(of block: PlacedBlock, scene: SimScene, painted: [SimRect]) -> Judgement {
        var judgement = Judgement()
        let prefix = TrackingBench.translationPrefix
        let rect = block.rect
        guard block.text.hasPrefix(prefix), rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite,
              rect.height.isFinite, rect.width > 0, rect.height > 0 else { return judgement }
        // the part of the frame it is drawn into
        var drawn = rect.intersection(scenario.frameRect.cgRect)
        if let visible = block.visibleRect, !drawn.isNull { drawn = drawn.intersection(visible) }
        // (a sliver no thicker than a thumbnail pixel shows nothing: what is left of a box whose
        // text has just slid under a bar, by the inexactness of the recognizer's rectangles)
        let sliver = CGFloat(scenario.scale)
        guard !drawn.isNull, drawn.width > sliver, drawn.height > sliver else {
            judgement.verdict = .notDrawn
            return judgement
        }
        judgement.drawn = drawn
        let text = String(block.text.dropFirst(prefix.count))

        // The occurrence of the text in this frame that fits the placed rectangle and can be
        // seen, the nearest of them; without one, the nearest occurrence of all. (The same text
        // may lie hidden at the same place: a header that sticks to the top covers itself in
        // the page.)
        var fitting = Double.infinity, nearest = Double.infinity
        var fittingLines: [Reading] = [], nearestLines: [Reading] = []
        var fittingLayer = -1, nearestLayer = -1
        var fittingRect = CGRect.zero, nearestRect = CGRect.zero
        var isNearestOnText = false
        // A translation of an earlier reading of the same paragraph, shown while the new one is
        // on its way (`TrackedBlock.isStale`): the rectangle is that of the new reading (more or
        // fewer lines of the paragraph), the text that of the old one. It is drawn over its own
        // paragraph and over nothing else, so it is not misplaced; but it is not the translation
        // of the paragraph either (no coverage, no alignment samples).
        var stale = Double.infinity
        var staleLines: [Reading] = []
        var staleLayer = -1
        var staleRect = CGRect.zero
        for (index, layer) in scene.layers.enumerated() where !readings[layer.sprite].isEmpty {
            let candidates = chains(for: text, sprite: layer.sprite)
            if candidates.isEmpty { continue }
            let sprite = scenario.sprites[layer.sprite]
            let lines = sprite.lines
            for candidate in candidates {
                var union = SimRect()
                var heights = 0
                for reading in candidate {
                    union = union.union((reading.part ?? lines[reading.line].rect).offsetBy(dx: layer.x, dy: layer.y))
                    heights += lines[reading.line].rect.height
                }
                let place = union.cgRect
                let height = Double(heights) / Double(candidate.count)
                let distance = Double(max(max(abs(rect.minX - place.minX), abs(rect.maxX - place.maxX)),
                                          max(abs(rect.minY - place.minY), abs(rect.maxY - place.maxY))))
                let isOnText = distance <= height / 2
                if distance < nearest {
                    nearest = distance
                    nearestLines = candidate
                    nearestLayer = index
                    nearestRect = place
                    isNearestOnText = isOnText
                }
                let above = Array(painted[(index + 1)...])
                if isOnText, distance < fitting {
                    if SimRect.uncovered(union.intersection(painted[index]), by: above).area > 0 {
                        fitting = distance
                        fittingLines = candidate
                        fittingLayer = index
                        fittingRect = place
                    }
                } else if !isOnText, distance < stale,
                          let whole = TrackingBench.paragraphRect(of: candidate, in: sprite) {
                    let box = whole.offsetBy(dx: layer.x, dy: layer.y)
                    let reach = CGFloat(height / 2)
                    let overlap = rect.intersection(place)
                    let seen = SimRect.uncovered(SimRect(covering: rect).intersection(box).intersection(painted[index]),
                                                 by: above)
                    if TrackingBench.contains(box.cgRect.insetBy(dx: -reach, dy: -reach), rect), !overlap.isNull,
                       overlap.height >= reach, overlap.width >= reach, seen.area > 0 {
                        stale = distance
                        staleLines = candidate
                        staleLayer = index
                        staleRect = box.cgRect
                    }
                }
            }
        }
        if fittingLayer < 0, staleLayer >= 0 {
            fittingLines = staleLines
            fittingLayer = staleLayer
            fittingRect = staleRect
            judgement.isStaleReading = true
        }
        let layerIndex = fittingLayer >= 0 ? fittingLayer : nearestLayer
        // the text is not on the screen: something that is gone, or nothing the recognition ever returned
        guard layerIndex >= 0 else {
            judgement.verdict = isKnownSomewhere(text) ? .hidden : .unknown
            return judgement
        }
        let traced = fittingLayer >= 0 ? fittingLines : nearestLines
        judgement.layer = layerIndex
        judgement.slot = scene.layers[layerIndex].slot
        judgement.sprite = scene.layers[layerIndex].sprite
        judgement.lines = traced.map(\.line)
        judgement.hasPartialLine = traced.contains { $0.part != nil }
        judgement.expected = fittingLayer >= 0 ? fittingRect : nearestRect
        guard fittingLayer >= 0 else {
            // beside its text, or on text of which nothing can be seen
            judgement.verdict = isNearestOnText ? .hidden : .offText
            return judgement
        }
        let own = painted[layerIndex]
        let covers = Array(painted[(layerIndex + 1)...])

        // is it drawn only where its text can be?
        let tolerance = CGFloat(scenario.scale)
        let bounds = own.cgRect
        var isCovering = drawn.minX < bounds.minX - tolerance || drawn.maxX > bounds.maxX + tolerance
            || drawn.minY < bounds.minY - tolerance || drawn.maxY > bounds.maxY + tolerance
        for cover in covers where !cover.isEmpty {
            let overlap = drawn.intersection(cover.cgRect)
            if !overlap.isNull, overlap.width > tolerance, overlap.height > tolerance { isCovering = true }
        }
        if isCovering {
            judgement.verdict = .covering
            return judgement
        }
        judgement.verdict = .onText
        judgement.errorX = Double(rect.midX - fittingRect.midX)
        judgement.errorY = Double(rect.midY - fittingRect.midY)
        return judgement
    }

    /// The rectangle of the paragraph all lines of a chain belong to, in pixels of the sprite;
    /// nil when they belong to several or one of them was only seen in part
    private static func paragraphRect(of chain: [Reading], in sprite: SimSprite) -> SimRect? {
        guard let first = chain.first else { return nil }
        let paragraph = sprite.lines[first.line].paragraph
        guard paragraph >= 0 else { return nil }
        for reading in chain where reading.part != nil || sprite.lines[reading.line].paragraph != paragraph {
            return nil
        }
        return sprite.paragraphs[paragraph].rect
    }

    /// The number of layers of the frame of `tick` that have `text` as the text of lines that
    /// follow each other (for the tests of the bench)
    func layersShowing(_ text: String, tick: Int) -> Int {
        var count = 0
        for layer in scenario.scenes[tick].layers where !chains(for: text, sprite: layer.sprite).isEmpty {
            count += 1
        }
        return count
    }

    /// Some sprite of the scenario, on the screen or not, has this text
    private func isKnownSomewhere(_ text: String) -> Bool {
        for sprite in scenario.sprites.indices where !chains(for: text, sprite: sprite).isEmpty {
            return true
        }
        return false
    }
}

extension TrackingBench {
    /// The tracker's delay until a failed translation is offered again
    static var retryDelay: TimeInterval { OverlayTracker.Configuration().retryDelay }
}

// MARK: - The score

enum TrackingScore {
    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var sum = 0.0
        for value in values {
            sum += value
        }
        return sum / Double(values.count)
    }

    /// The value below which `share` of the values lie; 0 without values
    static func percentile(_ values: [Double], _ share: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((share * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    /// 1 up to `full`, falling evenly to 0 at `none`
    static func falling(_ value: Double, from full: Double, to none: Double) -> Double {
        min(1, max(0, (none - value) / (none - full)))
    }

    /// Fills in the score of a result and its factors (see the top of TrackingBench.swift)
    static func rate(_ result: inout TrackingResult, scale: Int, scoresLatency: Bool = true) {
        let pixel = Double(scale)
        let seconds = Double(result.misplaced) / Double(SimScenario.ticksPerSecond)
        result.misplacementFactor = exp(-seconds / 0.5)
        result.wasteFactor = result.areaRead <= 3 * result.areaBudget ? 1
            : (3 * result.areaBudget / result.areaRead).squareRoot()

        let dueResting = result.dueParagraphFrames - result.dueMoving
        let coveredResting = result.coveredParagraphFrames - result.coveredMoving
        result.coverageResting = dueResting > 0 ? Double(coveredResting) / Double(dueResting) : 1
        result.coverageMoving = result.dueMoving > 0 ? Double(result.coveredMoving) / Double(result.dueMoving) : nil

        result.alignmentResting = result.restingSamples > 0 ? falling(result.restingMean / pixel, from: 0.5, to: 2.5) : 0
        result.alignmentMoving = result.movingSamples > 0
            ? 0.6 * falling(result.movingMean / pixel, from: 0.5, to: 2.5)
                + 0.4 * falling(result.jitterMovingMean / pixel, from: 0.25, to: 1.25)
            : 0
        result.tidinessScore = 1 / (1 + 5 * Double(result.flickers + result.halfReadStarts)
                                   / Double(max(1, result.coveredParagraphs)))
        if result.latencySamples > 0, scoresLatency {
            result.latencyScore = 0.6 * falling(result.latencyMedian, from: 0.15, to: 0.75)
                + 0.4 * falling(result.latency95, from: 0.3, to: 1.5)
        } else {
            result.latencyScore = nil
        }
        result.costScore = 0.5 * falling(result.areaRead / result.areaBudget, from: 1, to: 3)
            + 0.25 * falling(Double(result.translationRequests) / result.translationBudget, from: 1, to: 3)
            + 0.25 * falling(Double(result.textsDrawn) / result.drawBudget, from: 1, to: 3)

        // a term without input gives its weight to the coverage at rest
        var resting = 0.25, moving = 0.30, latency = 0.15
        // (tidiness before cost: priority 4 against priority 6)
        let tidiness = 0.20, cost = 0.10
        if result.coverageMoving == nil {
            resting += moving
            moving = 0
        }
        if result.latencyScore == nil {
            resting += latency
            latency = 0
        }
        let coverageMoving = result.coverageMoving ?? 0
        result.coverage = (resting * result.coverageResting + moving * coverageMoving) / (resting + moving)
        let sum = resting * result.coverageResting * (0.7 + 0.3 * result.alignmentResting)
            + moving * coverageMoving * (0.5 + 0.5 * result.alignmentMoving)
            + latency * (result.latencyScore ?? 0)
            + tidiness * result.coverage * result.tidinessScore
            + cost * result.coverage * result.costScore
        result.score = 100 * result.misplacementFactor * result.wasteFactor * sum
    }
}

// MARK: - Report

/// The results of all scenarios for a few seeds
struct TrackingReport: Codable {
    var subject: String
    var seeds: [UInt64]
    /// mean score over everything
    var overall = 0.0
    /// mean score per scenario over the seeds
    var scores: [String: Double] = [:]
    /// all runs as one: the counts added up, everything else averaged over the runs that have it
    var total = TrackingResult()
    var results: [TrackingResult] = []

    init(subject: String, seeds: [UInt64]) {
        self.subject = subject
        self.seeds = seeds
    }

    /// Call after the last result: works out the means
    mutating func finish() {
        var sums: [String: Double] = [:], counts: [String: Double] = [:]
        var sum = TrackingResult()
        sum.coverage = 0
        sum.coverageResting = 0
        sum.misplacementFactor = 0
        sum.wasteFactor = 0
        sum.tidinessScore = 0
        sum.costScore = 0
        var latencyScores = 0.0, movingCoverage = 0.0
        var withLatency = 0.0, withLatencyScore = 0.0, withMoving = 0.0, withResting = 0.0, withMovingCoverage = 0.0
        var changedTime = 0.0, sameTime = 0.0, changedRuns = 0.0, sameRuns = 0.0
        for result in results {
            sums[result.scenario, default: 0] += result.score
            counts[result.scenario, default: 0] += 1
            sum.score += result.score
            sum.coverage += result.coverage
            sum.coverageResting += result.coverageResting
            if let moving = result.coverageMoving {
                withMovingCoverage += 1
                movingCoverage += moving
            }
            sum.misplacementFactor += result.misplacementFactor
            sum.wasteFactor += result.wasteFactor
            sum.alignmentResting += result.alignmentResting
            sum.alignmentMoving += result.alignmentMoving
            sum.tidinessScore += result.tidinessScore
            sum.costScore += result.costScore
            if let latency = result.latencyScore {
                withLatencyScore += 1
                latencyScores += latency
            }
            sum.misplaced += result.misplaced
            sum.misplacedOffText += result.misplacedOffText
            sum.misplacedHidden += result.misplacedHidden
            sum.misplacedCovering += result.misplacedCovering
            sum.misplacedUnknown += result.misplacedUnknown
            sum.misplacedMostAtOnce = max(sum.misplacedMostAtOnce, result.misplacedMostAtOnce)
            sum.misplacedLongestRun = max(sum.misplacedLongestRun, result.misplacedLongestRun)
            sum.placed += result.placed
            sum.dueParagraphFrames += result.dueParagraphFrames
            sum.coveredParagraphFrames += result.coveredParagraphFrames
            sum.dueMoving += result.dueMoving
            sum.coveredMoving += result.coveredMoving
            if result.latencySamples > 0 {
                withLatency += 1
                sum.latencySamples += result.latencySamples
                sum.latencyMedian += result.latencyMedian
                sum.latency95 += result.latency95
            }
            if result.movingSamples > 0 {
                withMoving += 1
                sum.movingSamples += result.movingSamples
                sum.movingMean += result.movingMean
                sum.jitterMovingMean += result.jitterMovingMean
            }
            if result.restingSamples > 0 {
                withResting += 1
                sum.restingSamples += result.restingSamples
                sum.restingMean += result.restingMean
            }
            sum.flickers += result.flickers
            sum.coveredParagraphs += result.coveredParagraphs
            sum.halfReadStarts += result.halfReadStarts
            sum.halfRead += result.halfRead
            sum.staleReadings += result.staleReadings
            sum.contractSlips += result.contractSlips
            sum.passes += result.passes
            sum.failedPasses += result.failedPasses
            sum.areaRead += result.areaRead
            sum.areaBudget += result.areaBudget
            sum.translationRequests += result.translationRequests
            sum.translationBatches += result.translationBatches
            sum.translationBudget += result.translationBudget
            sum.textsDrawn += result.textsDrawn
            sum.textsDrawnLate += result.textsDrawnLate
            sum.drawBudget += result.drawBudget
            if result.advanceChangedMs > 0 {
                changedTime += result.advanceChangedMs
                changedRuns += 1
            }
            if result.advanceSameMs > 0 {
                sameTime += result.advanceSameMs
                sameRuns += 1
            }
            sum.advanceMaxMs = max(sum.advanceMaxMs, result.advanceMaxMs)
            sum.frames += result.frames
            sum.redraws += result.redraws
        }
        for (name, score) in sums {
            scores[name] = score / (counts[name] ?? 1)
        }
        let runs = Double(max(1, results.count))
        sum.scenario = "all runs"
        sum.subject = subject
        sum.score /= runs
        sum.coverage /= runs
        sum.coverageResting /= runs
        sum.coverageMoving = withMovingCoverage > 0 ? movingCoverage / withMovingCoverage : nil
        sum.misplacementFactor /= runs
        sum.wasteFactor /= runs
        sum.alignmentResting /= runs
        sum.alignmentMoving /= runs
        sum.tidinessScore /= runs
        sum.costScore /= runs
        sum.latencyScore = withLatencyScore > 0 ? latencyScores / withLatencyScore : nil
        sum.latencyMedian /= max(1, withLatency)
        sum.latency95 /= max(1, withLatency)
        sum.movingMean /= max(1, withMoving)
        sum.jitterMovingMean /= max(1, withMoving)
        sum.restingMean /= max(1, withResting)
        sum.advanceChangedMs = changedTime / max(1, changedRuns)
        sum.advanceSameMs = sameTime / max(1, sameRuns)
        total = sum
        overall = sum.score
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static let header = "scenario         seed  score  mispl most run 1st   rest  move  lat50 lat95  e.mov e.rest  jitt"
        + " flick half  pass  area/budget  transl/budget  drawn/budget  slips frames  advance ms new/same/max"

    /// Columns: score; misplaced block × display frames, most at once, longest run, tick of the
    /// first; coverage of resting and of moving text; latency median and 95th percentile in
    /// seconds; alignment error moving and at rest and jitter in frame pixels; flickers;
    /// half-read translations that appeared; recognition passes; area read and its budget in
    /// frames; translation requests and their budget; texts drawn and their budget; contract
    /// slips; frames; milliseconds per `advance` for a new picture, for the same picture
    /// again, and the longest
    static func row(_ result: TrackingResult) -> String {
        let name = result.scenario.padding(toLength: 16, withPad: " ", startingAt: 0)
        let moving = result.coverageMoving.map { String(format: "%5.3f", $0) } ?? "    -"
        let latency = result.latencySamples > 0
            ? String(format: "%5.2f %5.2f", result.latencyMedian, result.latency95) : "    -     -"
        let first = result.misplacedFirstTick >= 0 ? String(format: "%3d", result.misplacedFirstTick) : "  -"
        return name
            + String(format: " %4d  %5.1f  %5d %4d %3d ", Int(result.seed), result.score, result.misplaced,
                     result.misplacedMostAtOnce, result.misplacedLongestRun)
            + first + String(format: "  %5.3f ", result.coverageResting) + moving + "  " + latency
            + String(format: "  %5.2f %5.2f %5.2f %5d %4d  %4d  %5.2f/%-5.2f  %6d/%-5d  %6d/%-5d  %4d %6d  %.3f/%.3f/%.3f",
                     result.movingMean, result.restingMean, result.jitterMovingMean, result.flickers,
                     result.halfReadStarts, result.passes, result.areaRead, result.areaBudget,
                     result.translationRequests, Int(result.translationBudget), result.textsDrawn,
                     Int(result.drawBudget), result.contractSlips, result.frames, result.advanceChangedMs,
                     result.advanceSameMs, result.advanceMaxMs)
    }

    /// The factors of the score of a result in one line
    static func factors(_ result: TrackingResult) -> String {
        let moving = result.coverageMoving.map { String(format: "%.2f", $0) } ?? "–"
        let latency = result.latencyScore.map { String(format: "%.2f", $0) } ?? "–"
        return String(format: "misplacement %.2f, waste %.2f, coverage at rest %.2f (alignment %.2f), moving ",
                      result.misplacementFactor, result.wasteFactor, result.coverageResting, result.alignmentResting)
            + moving + String(format: " (alignment %.2f), latency ", result.alignmentMoving) + latency
            + String(format: ", tidiness %.2f, cost %.2f", result.tidinessScore, result.costScore)
    }

    /// One line per run, the mean score per scenario and overall, and all runs in one line
    func table() -> String {
        var lines = ["[tracking] subject: \(subject), seeds: \(seeds.map(String.init).joined(separator: ","))",
                     TrackingReport.header]
        for result in results {
            lines.append(TrackingReport.row(result))
        }
        lines.append("")
        lines.append("scenario          mean score")
        var seen: Set<String> = []
        for result in results where seen.insert(result.scenario).inserted {
            lines.append(result.scenario.padding(toLength: 16, withPad: " ", startingAt: 0)
                         + String(format: "  %5.1f", scores[result.scenario] ?? 0))
        }
        lines.append(String(format: "overall           %5.1f", overall))
        lines.append("")
        lines.append(TrackingReport.header)
        lines.append(TrackingReport.row(total))
        lines.append("[tracking] " + TrackingReport.factors(total))
        return lines.joined(separator: "\n")
    }
}
