// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorAct

// Stand-ins for the tracker that show what the numbers of the bench mean:
// - `TrackingOracle` draws the truth. It must get the full score; with an offset, a delay or
//   without clipping it shows that the bench measures exactly that.
// - `TrackingInformed` knows where every paragraph is and which ones are complete, but has to
//   read and translate like a tracker. Its score is what the recognizer and the translator of
//   the bench leave room for at best.
// - `TrackingGuided` knows how every part of the picture moves and what covers what, and
//   nothing else: it works with the blocks the recognition returns (cut lines, parts of
//   paragraphs, misreadings) the way a tracker has to. It is the measure for the thresholds of
//   the regression tests. With a `TrackingVices` it cheats or blunders in one particular way,
//   to show what that costs.
// - `TrackingFrozen` reads the picture and never moves what it found. It must fail as soon as
//   anything scrolls.

// MARK: - The truth

/// Places the translation of every paragraph that can be seen exactly where the paragraph is
final class TrackingOracle: TrackingSubject {
    private var scenario: SimScenario
    private let offsetX: Double
    private let offsetY: Double
    private let delay: Int
    private let clips: Bool
    private let firstLinesOnly: Bool
    /// the ticks of the pictures given to `advance`, the newest last
    private var ticks: [Int] = []

    /// - Parameters:
    ///   - offsetX: every rectangle is off by so many frame pixels
    ///   - delay: places what was true so many frames ago
    ///   - clips: gives the visible part of a paragraph that is partly hidden; false = draws all of it
    ///   - firstLinesOnly: translates only the first line of every paragraph, as if it had been
    ///     read before the rest came into view
    init(scenario: SimScenario, offsetX: Double = 0, offsetY: Double = 0, delay: Int = 0, clips: Bool = true,
         firstLinesOnly: Bool = false) {
        self.scenario = scenario
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.delay = delay
        self.clips = clips
        self.firstLinesOnly = firstLinesOnly
    }

    func prepare(_ next: SimScenario, tick: Int) {
        if next !== scenario {
            scenario = next
            ticks = []
        }
        if ticks.last != tick { ticks.append(tick) }
    }

    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
        var placed: [PlacedBlock] = []
        if !ticks.isEmpty {
            let tick = ticks[max(0, ticks.count - 1 - delay)]
            for sight in scenario.paragraphSights(at: tick) {
                let paragraph = scenario.sprites[sight.sprite].paragraphs[sight.paragraph]
                guard paragraph.isTranslatable else { continue }
                var visible: CGRect?
                if !sight.isFullyVisible, clips {
                    // one rectangle cannot leave out a corner
                    guard sight.isVisiblePartWhole else { continue }
                    visible = sight.visible.cgRect
                }
                var text = paragraph.text
                var rect = sight.rect
                var lineCount = paragraph.lines.count
                if firstLinesOnly, let first = paragraph.lines.first {
                    guard sight.isFullyVisible else { continue }
                    let line = scenario.sprites[sight.sprite].lines[first]
                    text = line.text
                    rect = line.rect.offsetBy(dx: sight.rect.x - paragraph.rect.x, dy: sight.rect.y - paragraph.rect.y)
                    lineCount = 1
                }
                placed.append(PlacedBlock(id: TrackingOracle.identifier(slot: sight.slot, paragraph: paragraph),
                                          text: TrackingBench.translationPrefix + text,
                                          rect: rect.cgRect.offsetBy(dx: CGFloat(offsetX), dy: CGFloat(offsetY)),
                                          visibleRect: visible, lineCount: lineCount,
                                          colors: TrackingOracle.colors(of: paragraph)))
            }
        }
        return FrameUpdate(change: .unchanged, scrollX: 0, scrollY: 0, placed: placed, recognitionDue: nil)
    }

    /// The same for the same paragraph in the same place of its picture, whichever copy of the
    /// picture is shown (dimmed, half faded): the drawn text can be kept
    static func identifier(slot: Int, paragraph: SimParagraph) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(slot)
        for byte in paragraph.text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        hash = (hash ^ UInt64(truncatingIfNeeded: paragraph.rect.x)) &* 0x0000_0100_0000_01B3
        hash = (hash ^ UInt64(truncatingIfNeeded: paragraph.rect.y)) &* 0x0000_0100_0000_01B3
        return Int(hash >> 16)
    }

    static func colors(of paragraph: SimParagraph) -> BlockColors {
        let back = paragraph.background, front = paragraph.foreground
        return BlockColors(background: RGBColor(red: back, green: back, blue: back),
                           foreground: RGBColor(red: front, green: front, blue: front))
    }

    var recognitionDue: TimeInterval? { nil }

    func beginRecognition(time: TimeInterval) -> RecognitionRequest? { nil }

    func finishRecognition(_ request: RecognitionRequest, blocks: [RecognizedBlock], time: TimeInterval) {}

    func abandonRecognition(_ request: RecognitionRequest) {}

    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] { [] }

    func setTranslation(_ translation: String, for text: String) {}

    func translationFailed(for text: String, time: TimeInterval) {}

    func isSettled(at time: TimeInterval) -> Bool { true }

    var blocks: [TrackedBlock] { [] }

    var followsContract: Bool { false }
}

// MARK: - Perfect tracking, real reading

/// Follows every paragraph without error because it looks up where it is, but learns the text
/// from the recognizer and the translation from the translator like a tracker: it reads what
/// has come completely into view, at once while scrolling and a moment after other changes.
final class TrackingInformed: TrackingSubject {
    /// seconds without another change before a new screen or pop-up is read
    static let settleTime = 0.12

    private struct Known {
        var text: String
        /// how far each edge of the recognized rectangle was from the true one
        var left: CGFloat
        var top: CGFloat
        var right: CGFloat
        var bottom: CGFloat
        var colors: BlockColors
    }

    private struct Running {
        var request: RecognitionRequest
        var tick: Int
    }

    private var scenario: SimScenario
    private var tick = -1
    private var lastChange: TimeInterval = 0
    /// when text appeared, vanished or was replaced (not: moved)
    private var lastCut: TimeInterval = 0
    private var isChangePending = true
    private var isCutPending = true
    /// by sprite and paragraph
    private var known: [Int: Known] = [:]
    private var translations: [String: String] = [:]
    private var requested: Set<String> = []
    private var failedAt: [String: TimeInterval] = [:]
    private var running: Running?
    private var nextRequest = 1

    init(scenario: SimScenario) {
        self.scenario = scenario
    }

    private func key(_ sight: SimParagraphSight) -> Int {
        sight.sprite << 24 | sight.paragraph
    }

    func prepare(_ part: SimScenario, tick next: Int) {
        if part !== scenario {
            // frames of another size: nothing of the picture is left
            scenario = part
            tick = -1
            known = [:]
            running = nil
            isChangePending = true
            isCutPending = true
        }
        guard next != tick else { return }
        if tick >= 0 {
            let before = scenario.scenes[tick].layers, now = scenario.scenes[next].layers
            if before != now { isChangePending = true }
            if textSprites(of: before) != textSprites(of: now) { isCutPending = true }
        }
        tick = next
    }

    /// The sprites with text that a frame shows, by layer
    private func textSprites(of layers: [SimLayer]) -> [Int] {
        var sprites: [Int] = []
        for layer in layers where !scenario.sprites[layer.sprite].paragraphs.isEmpty {
            sprites.append(layer.slot << 20 | layer.sprite)
        }
        return sprites
    }

    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
        if isChangePending { lastChange = time }
        if isCutPending { lastCut = time }
        isChangePending = false
        isCutPending = false

        // What was read but left the screen before it was asked for is read again when it is
        // back: the caller asks for texts only after a pass or a batch of translations, so
        // nobody would ask for it.
        let sights = scenario.paragraphSights(at: tick)
        var onScreen: Set<Int> = []
        for sight in sights {
            onScreen.insert(key(sight))
        }
        for (paragraph, entry) in known where !onScreen.contains(paragraph) && translations[entry.text] == nil
            && !requested.contains(entry.text) {
            known[paragraph] = nil
        }

        var placed: [PlacedBlock] = []
        for sight in sights {
            guard let entry = known[key(sight)], let translation = translations[entry.text] else { continue }
            var visible: CGRect?
            if !sight.isFullyVisible {
                guard sight.isVisiblePartWhole else { continue }
                visible = sight.visible.cgRect
            }
            let truth = sight.rect.cgRect
            let rect = CGRect(x: truth.minX + entry.left, y: truth.minY + entry.top,
                              width: truth.width - entry.left + entry.right,
                              height: truth.height - entry.top + entry.bottom)
            let paragraph = scenario.sprites[sight.sprite].paragraphs[sight.paragraph]
            placed.append(PlacedBlock(id: key(sight), text: translation, rect: rect, visibleRect: visible,
                                      lineCount: paragraph.lines.count, colors: entry.colors))
        }
        return FrameUpdate(change: .unchanged, scrollX: 0, scrollY: 0, placed: placed, recognitionDue: recognitionDue)
    }

    /// paragraphs that are completely visible and have not been read
    private var unread: [SimParagraphSight] {
        guard tick >= 0 else { return [] }
        return scenario.paragraphSights(at: tick).filter { sight in
            sight.isFullyVisible && known[key(sight)] == nil
                && scenario.sprites[sight.sprite].paragraphs[sight.paragraph].isTranslatable
        }
    }

    var recognitionDue: TimeInterval? {
        guard running == nil, !unread.isEmpty else { return nil }
        return lastCut + TrackingInformed.settleTime
    }

    func beginRecognition(time: TimeInterval) -> RecognitionRequest? {
        guard let due = recognitionDue, time >= due - 1e-9 else { return nil }
        var region = SimRect()
        for sight in unread {
            region = region.union(sight.rect)
        }
        // a little air around the text, as a tracker would leave
        let air = 4 * scenario.scale
        region = SimRect(x: region.x - air, y: region.y - air, width: region.width + 2 * air,
                         height: region.height + 2 * air).intersection(scenario.frameRect)
        let isFullFrame = region.area * 10 >= scenario.frameRect.area * 7
        if isFullFrame { region = scenario.frameRect }
        let request = RecognitionRequest(id: nextRequest, region: region.cgRect, isFullFrame: isFullFrame)
        nextRequest += 1
        running = Running(request: request, tick: tick)
        return request
    }

    func finishRecognition(_ request: RecognitionRequest, blocks: [RecognizedBlock], time: TimeInterval) {
        guard let pass = running, pass.request == request else { return }
        running = nil
        let sights = scenario.paragraphSights(at: pass.tick)
        for block in blocks {
            // only what was read as the whole paragraph it is
            for sight in sights where sight.isFullyVisible && known[key(sight)] == nil {
                let truth = sight.rect.cgRect
                let paragraph = scenario.sprites[sight.sprite].paragraphs[sight.paragraph]
                let lineHeight = paragraph.rect.height / max(1, paragraph.lines.count)
                let slack = CGFloat(2 * scenario.rectNoise(lineHeight: lineHeight) + 1)
                let left = block.rect.minX - truth.minX, right = block.rect.maxX - truth.maxX
                let top = block.rect.minY - truth.minY, bottom = block.rect.maxY - truth.maxY
                guard block.lineCount == paragraph.lines.count, abs(left) <= slack, abs(right) <= slack,
                      abs(top) <= slack, abs(bottom) <= slack else { continue }
                known[key(sight)] = Known(text: block.text, left: left, top: top, right: right, bottom: bottom,
                                          colors: block.colors)
                break
            }
        }
    }

    func abandonRecognition(_ request: RecognitionRequest) {
        guard let pass = running, pass.request == request else { return }
        running = nil
    }

    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
        guard tick >= 0 else { return [] }
        var texts: [String] = []
        let sights = scenario.paragraphSights(at: tick).sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
        for sight in sights where texts.count < limit {
            guard let entry = known[key(sight)], translations[entry.text] == nil,
                  !requested.contains(entry.text) else { continue }
            if let failed = failedAt[entry.text], time - failed < TrackingBench.retryDelay { continue }
            requested.insert(entry.text)
            texts.append(entry.text)
        }
        return texts
    }

    func setTranslation(_ translation: String, for text: String) {
        requested.remove(text)
        failedAt[text] = nil
        translations[text] = translation
    }

    func translationFailed(for text: String, time: TimeInterval) {
        requested.remove(text)
        failedAt[text] = time
    }

    func isSettled(at time: TimeInterval) -> Bool {
        time - lastChange >= TrackingInformed.settleTime
    }

    var blocks: [TrackedBlock] { [] }

    var followsContract: Bool { false }
}

// MARK: - Perfect motion, everything else as a tracker has it

/// What `TrackingGuided` does wrong on purpose
struct TrackingVices {
    /// places nothing at all
    var neverDraws = false
    /// hides every translation while its text moves, and for a tenth of a second after
    var hidesMovingText = false
    /// places translations where their text was so many frames ago
    var lagsByFrames = 0
    /// asks for the whole frame whenever no pass is running
    var readsWholeFrameAlways = false
    /// reads a third of the largest part of the picture with text again and again
    var rereadsConstantly = false
    /// keeps a translation in its place for so many frames after its text has left the picture
    var keepsStaleFrames = 0
    /// never gives a `visibleRect`: draws over whatever covers a part of the text
    var ignoresChrome = false
    /// also translates lines that end at the edge of what was read
    var takesCutLines = false
    /// hides every translation for one frame in so many
    var blinksEvery = 0
    /// sizes that change by a pixel or so from frame to frame
    var wobbles = false
    /// reads only once the picture has not changed for an eighth of a second
    var readsAtRestOnly = false
    /// never reads again what it read while it moved, and reads strips without overlap
    var readsOnce = false
    /// forgets the translation it shows when a text is read differently
    var dropsOnRereading = false
}

/// Knows how every part of the picture moves and what covers what – and only that. Texts and
/// rectangles are what the recognition returned; it decides what to read when, which blocks to
/// keep and which to drop, with the means a tracker has.
///
/// How it reads: a part of the picture that is new is read once it has been there for a moment;
/// of content that scrolls, the strip that came into view, a line's height into what was read
/// before. A block that ends at the edge of what was read may be cut off: it is not kept, and
/// its place is read again once all of it can be seen. A block next to one that is known may be
/// the rest of the same paragraph: both are read again together. And when content comes to
/// rest, what was read while it moved is read once more.
final class TrackingGuided: TrackingSubject {
    static let settleTime = 0.12

    private struct Block {
        var id: Int
        var text: String
        var slot: Int
        var sprite: Int
        /// in pixels of the sprite of its layer
        var rect: CGRect
        var lineCount: Int
        var colors: BlockColors
        /// the translation of an earlier reading of this place, shown until the new one is there
        var earlier: String?
    }

    /// A layer as one frame shows it
    private struct Shot {
        var slot: Int
        var sprite: Int
        var x: Int
        var y: Int
        var painted: SimRect
        /// the smallest rectangle around what can be seen of the layer
        var visible: SimRect
        var covers: [SimRect]
        var hasText: Bool

        var key: Int { slot << 24 | sprite }
    }

    private struct Running {
        var request: RecognitionRequest
        var region: SimRect
        var shots: [Shot]
        var whileMoving: Set<Int>
    }

    /// A translation whose text has left the picture (kept by a vice only)
    private struct Ghost {
        var block: Block
        var rect: CGRect
        var until: Int
    }

    private var scenario: SimScenario
    private let vices: TrackingVices
    private var tick = -1
    /// the ticks given to `advance`, the newest last
    private var history: [Int] = []
    private var frames = 0
    private var now: TimeInterval = 0
    private var lastChange: TimeInterval = 0
    private var lastCut: TimeInterval = 0
    private var shots: [Shot] = []
    /// by slot: when its layer moved last
    private var movedTime: [Int: TimeInterval] = [:]

    private var known: [Block] = []
    private var ghosts: [Ghost] = []
    private var nextBlock = 1
    private var nextRequest = 1
    /// by layer (slot and sprite), in pixels of the sprite: what was read
    private var readAreas: [Int: [SimRect]] = [:]
    /// … places to read again once all of them can be seen
    private var rereads: [Int: [SimRect]] = [:]
    /// … what was read while it moved
    private var unconfirmed: [Int: SimRect] = [:]
    private var translations: [String: String] = [:]
    private var requested: Set<String> = []
    private var failedAt: [String: TimeInterval] = [:]
    private var running: Running?
    /// what should be read, worked out for the frame that arrived last
    private var needs: [Need] = []
    /// places found during the pass that is being taken in, to read again
    private var newRereads: [Int: [SimRect]] = [:]

    /// A part of the frame that should be read
    private struct Need {
        /// its layer
        var key: Int
        /// in frame pixels
        var rect: SimRect
        var due: TimeInterval
    }

    init(scenario: SimScenario, vices: TrackingVices = TrackingVices()) {
        self.scenario = scenario
        self.vices = vices
    }

    // MARK: Frames

    func prepare(_ part: SimScenario, tick next: Int) {
        if part !== scenario {
            // frames of another size: nothing of the picture is left
            scenario = part
            tick = -1
            history = []
            shots = []
            movedTime = [:]
            known = []
            ghosts = []
            readAreas = [:]
            rereads = [:]
            unconfirmed = [:]
            running = nil
            needs = []
        }
        tick = next
    }

    private func makeShots(at tick: Int) -> [Shot] {
        let painted = scenario.paintedRects(at: tick)
        var result: [Shot] = []
        for (index, layer) in scenario.scenes[tick].layers.enumerated() {
            let covers = Array(painted[(index + 1)...])
            result.append(Shot(slot: layer.slot, sprite: layer.sprite, x: layer.x, y: layer.y, painted: painted[index],
                               visible: SimRect.uncovered(painted[index], by: covers).box, covers: covers,
                               hasText: !scenario.sprites[layer.sprite].paragraphs.isEmpty))
        }
        return result
    }

    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
        now = time
        frames += 1
        let before = shots
        if history.last != tick { history.append(tick) }
        shots = makeShots(at: tick)

        // what moved, what is new, what is gone
        var keysBefore: Set<Int> = [], keysNow: Set<Int> = []
        for shot in before where shot.hasText {
            keysBefore.insert(shot.key)
        }
        var isChange = before.isEmpty
        for shot in shots {
            if shot.hasText { keysNow.insert(shot.key) }
            if let old = before.first(where: { $0.slot == shot.slot }) {
                if old.sprite == shot.sprite, old.x != shot.x || old.y != shot.y { movedTime[shot.slot] = time }
                if old.sprite != shot.sprite || old.x != shot.x || old.y != shot.y || old.painted != shot.painted {
                    isChange = true
                }
            } else {
                isChange = true
            }
        }
        if before.count != shots.count { isChange = true }
        if isChange { lastChange = time }
        if keysBefore != keysNow { lastCut = time }
        // what is no longer shown is forgotten
        for key in keysBefore.sorted() where !keysNow.contains(key) {
            if vices.keepsStaleFrames > 0, let old = before.first(where: { $0.key == key }) {
                for block in known where block.slot << 24 | block.sprite == key {
                    ghosts.append(Ghost(block: block, rect: block.rect.offsetBy(dx: CGFloat(old.x), dy: CGFloat(old.y)),
                                        until: frames + vices.keepsStaleFrames))
                }
            }
            known.removeAll { $0.slot << 24 | $0.sprite == key }
            readAreas[key] = nil
            rereads[key] = nil
            unconfirmed[key] = nil
        }
        ghosts.removeAll { $0.until <= frames }

        plan()
        return FrameUpdate(change: .unchanged, scrollX: 0, scrollY: 0, placed: vices.neverDraws ? [] : placed(),
                           recognitionDue: recognitionDue)
    }

    private func shot(slot: Int, sprite: Int) -> Shot? {
        shots.first { $0.slot == slot && $0.sprite == sprite }
    }

    private func shownTranslation(of block: Block) -> String? {
        translations[block.text] ?? block.earlier
    }

    private func placed() -> [PlacedBlock] {
        var result: [PlacedBlock] = []
        // a tracker that lags places things where they were a few frames ago
        var late: [Shot] = []
        if vices.lagsByFrames > 0, history.count > vices.lagsByFrames {
            late = makeShots(at: history[history.count - 1 - vices.lagsByFrames])
        }
        for block in known {
            guard let shot = shot(slot: block.slot, sprite: block.sprite), let translation = shownTranslation(of: block)
            else { continue }
            if vices.hidesMovingText, now - (movedTime[block.slot] ?? -100) <= 0.1 { continue }
            if vices.blinksEvery > 0, (frames + block.id) % vices.blinksEvery == 0 { continue }
            var x = shot.x, y = shot.y
            if let old = late.first(where: { $0.slot == block.slot && $0.sprite == block.sprite }) {
                x = old.x
                y = old.y
            }
            var rect = block.rect.offsetBy(dx: CGFloat(x), dy: CGFloat(y))
            if vices.wobbles {
                rect.size.width += CGFloat((frames + block.id) % 3) * 0.8
                rect.size.height += CGFloat((frames + block.id) % 2) * 1.2
            }
            var visible: CGRect?
            if !vices.ignoresChrome {
                // what can be seen of the place where the text is now
                let whole = SimRect(covering: block.rect.offsetBy(dx: CGFloat(shot.x), dy: CGFloat(shot.y)))
                let seen = SimRect.uncovered(whole.intersection(shot.painted), by: shot.covers)
                if seen.area == 0 { continue }
                if seen.area < whole.area {
                    // one rectangle cannot leave out a corner
                    guard seen.area == seen.box.area else { continue }
                    visible = seen.box.cgRect
                }
            }
            result.append(PlacedBlock(id: block.id, text: translation, rect: rect, visibleRect: visible,
                                      lineCount: block.lineCount, colors: block.colors))
        }
        for ghost in ghosts {
            guard let translation = shownTranslation(of: ghost.block) else { continue }
            result.append(PlacedBlock(id: ghost.block.id, text: translation, rect: ghost.rect, visibleRect: nil,
                                      lineCount: ghost.block.lineCount, colors: ghost.block.colors))
        }
        return result
    }

    func isSettled(at time: TimeInterval) -> Bool {
        tick >= 0 && time - lastChange >= TrackingGuided.settleTime
    }

    var blocks: [TrackedBlock] {
        var result: [TrackedBlock] = []
        for block in known {
            guard let shot = shot(slot: block.slot, sprite: block.sprite) else { continue }
            result.append(TrackedBlock(id: block.id, text: block.text,
                                       rect: block.rect.offsetBy(dx: CGFloat(shot.x), dy: CGFloat(shot.y)),
                                       lineCount: block.lineCount, colors: block.colors,
                                       translation: shownTranslation(of: block),
                                       isStale: translations[block.text] == nil && block.earlier != nil))
        }
        return result
    }

    var followsContract: Bool { false }

    // MARK: What to read

    /// Works out what should be read of the frame that arrived last, and when
    private func plan() {
        needs = []
        guard tick >= 0 else { return }
        let scale = scenario.scale
        let frame = scenario.frameRect
        let thinnest = 12 * scale, overlap = vices.readsOnce ? 0 : 30 * scale
        let rest = lastChange + TrackingGuided.settleTime
        var largestText = SimRect()
        for shot in shots where shot.hasText && !shot.visible.isEmpty {
            let key = shot.key
            let view = shot.visible.offsetBy(dx: -shot.x, dy: -shot.y)
            if shot.visible.area > largestText.area { largestText = shot.visible }
            let moved = movedTime[shot.slot] ?? -1000
            // What has not been read. A part of the picture that is new: a moment after it
            // appeared. A strip that scrolled in: at once when it is thick enough to hold a
            // line, else when its layer has stopped.
            let done = readAreas[key] ?? []
            let unread = SimRect.uncovered(view, by: done)
            if unread.area > 0 {
                let strip = unread.box
                var due = lastCut + TrackingGuided.settleTime
                if !done.isEmpty { due = min(strip.width, strip.height) >= thinnest ? 0 : moved + 0.04 }
                let grown = SimRect(x: strip.x - overlap, y: strip.y - overlap, width: strip.width + 2 * overlap,
                                    height: strip.height + 2 * overlap).intersection(view)
                needs.append(Need(key: key, rect: grown.offsetBy(dx: shot.x, dy: shot.y).intersection(frame),
                                  due: vices.readsAtRestOnly ? max(due, rest) : due))
            }
            // lines that were cut off and paragraphs that grew, once all of them can be seen
            for place in rereads[key] ?? [] where view.contains(place) {
                needs.append(Need(key: key, rect: place.offsetBy(dx: shot.x, dy: shot.y).intersection(frame),
                                  due: vices.readsAtRestOnly ? rest : 0))
            }
            // once more what was read while it moved, a quarter of a second after it stopped
            if let pending = unconfirmed[key] {
                let part = pending.intersection(view)
                if !part.isEmpty {
                    needs.append(Need(key: key, rect: part.offsetBy(dx: shot.x, dy: shot.y).intersection(frame),
                                      due: max(moved + 0.25, rest)))
                }
            }
        }
        needs.removeAll { $0.rect.isEmpty }
        if vices.readsWholeFrameAlways {
            needs = [Need(key: -1, rect: frame, due: 0)]
        } else if vices.rereadsConstantly, !largestText.isEmpty {
            // the middle third of it: too little to be promoted to the whole frame
            let band = SimRect(x: largestText.x, y: largestText.y + largestText.height / 3, width: largestText.width,
                               height: largestText.height / 3)
            needs.append(Need(key: -2, rect: band, due: 0))
        }
    }

    var recognitionDue: TimeInterval? {
        guard running == nil, !needs.isEmpty else { return nil }
        var earliest = Double.infinity
        for need in needs {
            earliest = min(earliest, need.due)
        }
        return earliest
    }

    func beginRecognition(time: TimeInterval) -> RecognitionRequest? {
        guard running == nil else { return nil }
        // what is due, layer by layer; one of them per pass, unless it is much: then the whole frame
        var regions: [Int: SimRect] = [:]
        for need in needs where need.due <= time + 1e-9 {
            regions[need.key] = (regions[need.key] ?? SimRect()).union(need.rect)
        }
        var largest = SimRect()
        var total = 0
        for key in regions.keys.sorted() {
            guard let rect = regions[key] else { continue }
            total += rect.area
            if rect.area > largest.area { largest = rect }
        }
        guard !largest.isEmpty else { return nil }
        let frame = scenario.frameRect
        let region = total * 2 >= frame.area ? frame : largest
        let request = RecognitionRequest(id: nextRequest, region: region.cgRect, isFullFrame: region == frame)
        nextRequest += 1
        var moving: Set<Int> = []
        for shot in shots where time - (movedTime[shot.slot] ?? -1000) <= 0.1 {
            moving.insert(shot.key)
        }
        running = Running(request: request, region: region, shots: shots, whileMoving: moving)
        return request
    }

    func abandonRecognition(_ request: RecognitionRequest) {
        guard let pass = running, pass.request == request else { return }
        running = nil
        plan()
    }

    func finishRecognition(_ request: RecognitionRequest, blocks recognized: [RecognizedBlock], time: TimeInterval) {
        guard let pass = running, pass.request == request else { return }
        running = nil

        // the blocks of every layer of the frame that was read
        var found: [Int: [RecognizedBlock]] = [:]
        for block in recognized {
            let centerX = Int(block.rect.midX), centerY = Int(block.rect.midY)
            // the topmost layer with text at its centre
            var owner: Shot?
            for shot in pass.shots where shot.hasText && centerX >= shot.painted.x && centerX < shot.painted.maxX
                && centerY >= shot.painted.y && centerY < shot.painted.maxY {
                owner = shot
            }
            if let owner { found[owner.key, default: []].append(block) }
        }
        for shot in pass.shots where shot.hasText {
            let key = shot.key
            // only parts of the picture that are still there
            guard self.shot(slot: shot.slot, sprite: shot.sprite) != nil else { continue }
            let readable = shot.visible.intersection(pass.region)
            guard !readable.isEmpty else { continue }
            let area = readable.offsetBy(dx: -shot.x, dy: -shot.y)
            take(found[key] ?? [], of: shot, readable: readable)
            readAreas[key] = TrackingGuided.merged((readAreas[key] ?? []) + [area])
            rereads[key] = (rereads[key] ?? []).filter { !area.contains($0) } + (newRereads[key] ?? [])
            newRereads[key] = nil
            if vices.readsOnce {
                unconfirmed[key] = nil
            } else if pass.whileMoving.contains(key) {
                unconfirmed[key] = (unconfirmed[key] ?? SimRect()).union(area)
            } else if let pending = unconfirmed[key] {
                // confirmed, as far as it could be seen
                let view = shot.visible.offsetBy(dx: -shot.x, dy: -shot.y)
                if area.contains(pending.intersection(view)) { unconfirmed[key] = nil }
            }
        }
        plan()
    }

    /// Takes in what a pass found in the part `readable` of one layer
    private func take(_ recognized: [RecognizedBlock], of shot: Shot, readable: SimRect) {
        let key = shot.key
        let edge: CGFloat = 2
        let bounds = readable.cgRect
        var matched: Set<Int> = []
        for block in recognized {
            let lineHeight = block.rect.height / CGFloat(max(1, block.lineCount))
            let inSprite = block.rect.offsetBy(dx: CGFloat(-shot.x), dy: CGFloat(-shot.y))
            // a block that ends at the edge of what was read may be cut off there
            let touchesLeft = block.rect.minX <= bounds.minX + edge, touchesRight = block.rect.maxX >= bounds.maxX - edge
            let touchesTop = block.rect.minY <= bounds.minY + edge, touchesBottom = block.rect.maxY >= bounds.maxY - edge
            if !vices.takesCutLines, touchesLeft || touchesRight || touchesTop || touchesBottom {
                // (at the edge towards what was read before it is a line of a block that is known)
                let isKnown = known.contains { $0.slot == shot.slot && $0.sprite == shot.sprite && $0.rect.intersects(inSprite) }
                if !vices.readsOnce, !isKnown {
                    // all of it lies at most this far beyond the edge
                    let reach = lineHeight * 0.7 + 8, air: CGFloat = 8
                    let whole = CGRect(x: inSprite.minX - (touchesLeft ? reach : air), y: inSprite.minY - (touchesTop ? reach : air),
                                       width: inSprite.width + (touchesLeft ? reach : air) + (touchesRight ? reach : air),
                                       height: inSprite.height + (touchesTop ? reach : air) + (touchesBottom ? reach : air))
                    newRereads[key, default: []].append(SimRect(covering: whole))
                }
                continue
            }
            // the block that is known at this place
            var same: Int?
            for (index, old) in known.enumerated() where old.slot == shot.slot && old.sprite == shot.sprite
                && !matched.contains(index) {
                let common = old.rect.intersection(inSprite)
                guard !common.isNull else { continue }
                // (a block that shares a line with it is another one: the rest of its paragraph)
                if common.width * common.height * 10 >= 6 * max(old.rect.width * old.rect.height,
                                                                inSprite.width * inSprite.height) {
                    same = index
                    break
                }
            }
            if let same {
                matched.insert(same)
                var old = known[same]
                if old.text != block.text || old.lineCount != block.lineCount {
                    // read differently: the translation that is shown stays until the new one is there
                    if !vices.dropsOnRereading { old.earlier = shownTranslation(of: old) }
                    old.text = block.text
                    old.lineCount = block.lineCount
                    old.rect = inSprite
                    old.id = nextBlock
                    nextBlock += 1
                } else if abs(old.rect.minX - inSprite.minX) > 3 || abs(old.rect.maxX - inSprite.maxX) > 3
                            || abs(old.rect.minY - inSprite.minY) > 3 || abs(old.rect.maxY - inSprite.maxY) > 3 {
                    old.rect = inSprite
                }
                old.colors = block.colors
                known[same] = old
            } else {
                known.append(Block(id: nextBlock, text: block.text, slot: shot.slot, sprite: shot.sprite, rect: inSprite,
                                   lineCount: block.lineCount, colors: block.colors, earlier: nil))
                matched.insert(known.count - 1)
                nextBlock += 1
            }
        }
        // what was known inside of what was read and was not found again is gone
        let inner = readable.offsetBy(dx: -shot.x, dy: -shot.y).cgRect.insetBy(dx: edge, dy: edge)
        var kept: [Block] = []
        var keptWasMatched: [Bool] = []
        for (index, old) in known.enumerated() {
            let isHere = old.slot == shot.slot && old.sprite == shot.sprite
            let isInside = old.rect.minX >= inner.minX && old.rect.maxX <= inner.maxX && old.rect.minY >= inner.minY
                && old.rect.maxY <= inner.maxY
            if isHere, isInside, !matched.contains(index) { continue }
            kept.append(old)
            keptWasMatched.append(isHere && matched.contains(index))
        }
        known = kept
        guard !vices.readsOnce else { return }
        // A block right above or below another one may be the rest of the same paragraph that
        // came into view later: both are read again together.
        for (index, block) in known.enumerated() where keptWasMatched[index] {
            let lineHeight = block.rect.height / CGFloat(max(1, block.lineCount))
            for (otherIndex, other) in known.enumerated() where otherIndex != index && other.slot == block.slot
                && other.sprite == block.sprite {
                guard other.rect.minX < block.rect.maxX, block.rect.minX < other.rect.maxX else { continue }
                let gap = max(other.rect.minY - block.rect.maxY, block.rect.minY - other.rect.maxY)
                let otherHeight = other.rect.height / CGFloat(max(1, other.lineCount))
                guard gap < 0.7 * lineHeight, abs(otherHeight - lineHeight) < 0.25 * max(lineHeight, otherHeight) else { continue }
                // (not again and again: only when one of them was not read in this pass)
                guard !keptWasMatched[otherIndex] else { continue }
                newRereads[key, default: []].append(SimRect(covering: block.rect.union(other.rect).insetBy(dx: -6, dy: -6)))
            }
        }
    }

    /// Fewer rectangles for the same area: strips of the same width that touch become one
    private static func merged(_ areas: [SimRect]) -> [SimRect] {
        var result = areas
        var didMerge = true
        while didMerge {
            didMerge = false
            var index = 0
            while index < result.count, !didMerge {
                var other = index + 1
                while other < result.count {
                    let a = result[index], b = result[other]
                    let sameColumns = a.x == b.x && a.width == b.width && a.y <= b.maxY && b.y <= a.maxY
                    let sameRows = a.y == b.y && a.height == b.height && a.x <= b.maxX && b.x <= a.maxX
                    if sameColumns || sameRows || a.contains(b) || b.contains(a) {
                        result[index] = a.union(b)
                        result.remove(at: other)
                        didMerge = true
                        break
                    }
                    other += 1
                }
                index += 1
            }
        }
        return result
    }

    // MARK: Translations

    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
        var texts: [String] = []
        // top to bottom as the frame shows them
        var onScreen: [(y: CGFloat, x: CGFloat, text: String)] = []
        for block in known {
            guard let shot = shot(slot: block.slot, sprite: block.sprite) else { continue }
            onScreen.append((block.rect.minY + CGFloat(shot.y), block.rect.minX + CGFloat(shot.x), block.text))
        }
        onScreen.sort { ($0.y, $0.x) < ($1.y, $1.x) }
        for entry in onScreen where texts.count < limit {
            if translations[entry.text] != nil || requested.contains(entry.text) { continue }
            if let failed = failedAt[entry.text], time - failed < TrackingBench.retryDelay { continue }
            requested.insert(entry.text)
            texts.append(entry.text)
        }
        return texts
    }

    func setTranslation(_ translation: String, for text: String) {
        requested.remove(text)
        failedAt[text] = nil
        translations[text] = translation
        for index in known.indices where known[index].text == text {
            known[index].earlier = nil
        }
    }

    func translationFailed(for text: String, time: TimeInterval) {
        requested.remove(text)
        failedAt[text] = time
    }
}

// MARK: - No tracking at all

/// Reads the whole picture whenever it has changed and leaves the blocks where they were read
final class TrackingFrozen: TrackingSubject {
    private var found: [RecognizedBlock] = []
    private var translations: [String: String] = [:]
    private var requested: Set<String> = []
    private var failedAt: [String: TimeInterval] = [:]
    private var previous: LumaImage?
    private var frame = CGRect.zero
    private var isUnread = true
    private var running: RecognitionRequest?
    private var nextRequest = 1
    private var lastChange: TimeInterval = 0

    func prepare(_ scenario: SimScenario, tick: Int) {}

    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
        if let previous, previous.width != thumbnail.width || previous.height != thumbnail.height {
            found = []
        }
        if previous != thumbnail {
            isUnread = true
            lastChange = time
        }
        previous = thumbnail
        frame = CGRect(x: 0, y: 0, width: thumbnail.width * scale, height: thumbnail.height * scale)
        var placed: [PlacedBlock] = []
        for (index, block) in found.enumerated() {
            guard let translation = translations[block.text] else { continue }
            placed.append(PlacedBlock(id: index, text: translation, rect: block.rect, visibleRect: nil,
                                      lineCount: block.lineCount, colors: block.colors))
        }
        return FrameUpdate(change: .unchanged, scrollX: 0, scrollY: 0, placed: placed, recognitionDue: recognitionDue)
    }

    var recognitionDue: TimeInterval? {
        previous != nil && isUnread && running == nil ? lastChange : nil
    }

    func beginRecognition(time: TimeInterval) -> RecognitionRequest? {
        guard recognitionDue != nil else { return nil }
        let request = RecognitionRequest(id: nextRequest, region: frame, isFullFrame: true)
        nextRequest += 1
        running = request
        isUnread = false
        return request
    }

    func finishRecognition(_ request: RecognitionRequest, blocks recognized: [RecognizedBlock], time: TimeInterval) {
        guard running == request else { return }
        running = nil
        // (a pass that started on frames of another size has nothing to say about these)
        if request.region == frame { found = recognized }
    }

    func abandonRecognition(_ request: RecognitionRequest) {
        guard running == request else { return }
        running = nil
        isUnread = true
    }

    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
        var texts: [String] = []
        for block in found where texts.count < limit {
            if translations[block.text] != nil || requested.contains(block.text) { continue }
            if let failed = failedAt[block.text], time - failed < TrackingBench.retryDelay { continue }
            requested.insert(block.text)
            texts.append(block.text)
        }
        return texts
    }

    func setTranslation(_ translation: String, for text: String) {
        requested.remove(text)
        failedAt[text] = nil
        translations[text] = translation
    }

    func translationFailed(for text: String, time: TimeInterval) {
        requested.remove(text)
        failedAt[text] = time
    }

    func isSettled(at time: TimeInterval) -> Bool {
        time - lastChange >= 0.12
    }

    var blocks: [TrackedBlock] { [] }

    var followsContract: Bool { false }
}

// MARK: - By name

/// The subjects a report or a dump can be made of
enum TrackingSubjects {
    /// "tracker" is the real one; the others are stand-ins, the last ones with one vice each
    static let names = ["tracker", "oracle", "informed", "guided", "frozen", "never", "hides", "lags", "whole", "rereads",
                        "stale", "chrome", "cut", "blinks", "wobbles", "atRest", "once", "drops"]

    /// The vices of the stand-ins that cheat or blunder, by name
    static func vices(_ name: String) -> TrackingVices? {
        var vices = TrackingVices()
        switch name {
        case "never": vices.neverDraws = true
        case "hides": vices.hidesMovingText = true
        case "lags": vices.lagsByFrames = 1
        case "whole": vices.readsWholeFrameAlways = true
        case "rereads": vices.rereadsConstantly = true
        case "stale": vices.keepsStaleFrames = 20
        case "chrome": vices.ignoresChrome = true
        case "cut": vices.takesCutLines = true
        case "blinks": vices.blinksEvery = 45
        case "wobbles": vices.wobbles = true
        case "atRest": vices.readsAtRestOnly = true
        case "once": vices.readsOnce = true
        case "drops": vices.dropsOnRereading = true
        default: return nil
        }
        return vices
    }

    static func make(_ name: String, scenario: SimScenario) -> TrackingSubject? {
        switch name {
        case "tracker": return OverlayTrackerSubject()
        case "oracle": return TrackingOracle(scenario: scenario)
        case "informed": return TrackingInformed(scenario: scenario)
        case "guided": return TrackingGuided(scenario: scenario)
        case "frozen": return TrackingFrozen()
        default:
            guard let vices = vices(name) else { return nil }
            return TrackingGuided(scenario: scenario, vices: vices)
        }
    }
}
