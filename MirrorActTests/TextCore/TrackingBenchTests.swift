// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// The bench for `OverlayTracker` (TrackingBench.swift): tests of the bench itself, one
/// regression test per scenario and a report over several seeds.
///
/// A debug build is fifty to a hundred times slower at this than a release build, the tracker
/// included. `scripts/test.sh` tests a debug build, so by default the tests play only the
/// scenarios of `quickScenarios` and leave out the self-tests of the bench that take long and
/// the report, unless the environment asks for more. Everything in a debug build, which takes
/// close to an hour: `TRACKING_ALL=1 TRACKING_SEEDS=1 scripts/test.sh TrackingBenchTests`. A
/// release build plays it in a few minutes (CONTRIBUTING.md, Tests, has the command).
///
/// Environment (`scripts/test.sh` passes every `TRACKING_*` variable on to the tests; give paths
/// as absolute paths):
/// - `TRACKING_ALL=1`      all scenarios and self-tests also in a debug build
/// - `TRACKING_SEEDS`      seeds of `testReport`, default "1,2,3" (in a debug build the report
///                         only runs when this is set)
/// - `TRACKING_SUBJECT`    what `testReport` and `testDumpPictures` look at: "tracker"
///                         (default) or a stand-in of `TrackingSubjects.names`
/// - `TRACKING_SCENARIOS`  names, separated by commas: only these (report and dump)
/// - `TRACKING_REPORT`     path `testReport` writes its results to as JSON
/// - `TRACKING_DUMP`       folder `testDumpPictures` writes pictures to (PPM, with the truth
///                         and what the subject placed drawn in) and a list of what they show;
///                         `TRACKING_TICKS` (default seven of them) chooses the ticks,
///                         `TRACKING_FULL=1` frames instead of thumbnails
/// - `TRACKING_VERBOSE=1`  a line for every misplaced translation, every paragraph left
///                         without one and every slip against the contract
final class TrackingBenchTests: XCTestCase {
    // MARK: Thresholds

    private struct Threshold {
        /// lowest score that passes
        let score: Double
        /// most block × display frames that may be misplaced
        let misplaced: Int
    }

    /// For the regression seed (1): what `OverlayTracker` reached when the table was made, less a
    /// margin – its score on seed 1, at most its mean over seeds 1…3 plus 5 (a lucky seed does not
    /// raise the bar), less 8, rounded down to a multiple of 5, at least 30; misplaced block ×
    /// display frames: none where nothing moves, else what it had on seed 1 plus 2. The bench is
    /// deterministic, so a test that fails means the tracker got worse (or the bench changed):
    /// look at the events the failure lists before raising a limit. (The first table was set from
    /// `TrackingGuided`, a stand-in that knows how the picture moves; the tracker beats it in a
    /// few scenarios and stays below it in most.) A test also fails on any slip against the
    /// contract.
    private static let regressionSeed: UInt64 = 1
    private static let thresholds: [String: Threshold] = [
        // nothing moves
        "stillScreen": Threshold(score: 85, misplaced: 0),  // seed 1: 95.7, 0; seeds 1-3: 98.6
        "stillCable": Threshold(score: 90, misplaced: 0),  // seed 1: 100.0, 0; seeds 1-3: 100.0
        "noisyCable": Threshold(score: 90, misplaced: 0),  // seed 1: 100.0, 0; seeds 1-3: 100.0
        // scrolling
        "slowDrag": Threshold(score: 50, misplaced: 2),  // seed 1: 61.8, 0; seeds 1-3: 66.7
        "steadyScroll": Threshold(score: 75, misplaced: 2),  // seed 1: 84.4, 0; seeds 1-3: 81.2
        "flick": Threshold(score: 60, misplaced: 2),  // seed 1: 73.6, 0; seeds 1-3: 65.1
        "fastFlick": Threshold(score: 40, misplaced: 2),  // seed 1: 51.1, 0; seeds 1-3: 69.7
        "reverse": Threshold(score: 70, misplaced: 2),  // seed 1: 82.5, 0; seeds 1-3: 87.8
        "tremble": Threshold(score: 65, misplaced: 2),  // seed 1: 75.6, 0; seeds 1-3: 74.2
        "rubberBand": Threshold(score: 60, misplaced: 2),  // seed 1: 74.7, 0; seeds 1-3: 66.9
        "stopAndGo": Threshold(score: 65, misplaced: 2),  // seed 1: 75.9, 0; seeds 1-3: 85.5
        "alikeRows": Threshold(score: 75, misplaced: 2),  // seed 1: 85.0, 0; seeds 1-3: 83.4
        "identicalRows": Threshold(score: 70, misplaced: 2),  // seed 1: 79.8, 0; seeds 1-3: 81.0
        "sparsePage": Threshold(score: 55, misplaced: 2),  // seed 1: 69.7, 0; seeds 1-3: 62.6
        "darkTheme": Threshold(score: 65, misplaced: 2),  // seed 1: 74.9, 0; seeds 1-3: 71.6
        // what does not scroll
        "frostedBars": Threshold(score: 40, misplaced: 2),  // seed 1: 53.0, 0; seeds 1-3: 57.6
        "floatingButton": Threshold(score: 60, misplaced: 2),  // seed 1: 88.1, 0; seeds 1-3: 67.6
        "stickyHeader": Threshold(score: 70, misplaced: 2),  // seed 1: 82.3, 0; seeds 1-3: 82.8
        "pager": Threshold(score: 80, misplaced: 2),  // seed 1: 91.7, 0; seeds 1-3: 84.8
        "carousel": Threshold(score: 70, misplaced: 2),  // seed 1: 80.7, 0; seeds 1-3: 79.3
        "ticker": Threshold(score: 65, misplaced: 2),  // seed 1: 73.9, 0; seeds 1-3: 70.3
        "tickerStill": Threshold(score: 70, misplaced: 2),  // seed 1: 81.0, 0; seeds 1-3: 88.3
        "tickerLow": Threshold(score: 50, misplaced: 2),  // seed 1: 62.6, 0; seeds 1-3: 70.7
        "diagonalPan": Threshold(score: 60, misplaced: 2),  // seed 1: 71.5, 0; seeds 1-3: 80.0
        // changes that are not scrolling
        "alert": Threshold(score: 85, misplaced: 2),  // seed 1: 94.2, 0; seeds 1-3: 97.9
        "banner": Threshold(score: 65, misplaced: 4),  // seed 1: 76.8, 2; seeds 1-3: 70.1
        "newScreen": Threshold(score: 90, misplaced: 2),  // seed 1: 100.0, 0; seeds 1-3: 98.9
        "slideOver": Threshold(score: 85, misplaced: 2),  // seed 1: 94.1, 0; seeds 1-3: 95.6
        "textReplaced": Threshold(score: 70, misplaced: 2),  // seed 1: 82.3, 0; seeds 1-3: 86.4
        "video": Threshold(score: 60, misplaced: 2),  // seed 1: 83.2, 0; seeds 1-3: 65.4
        // sources and sizes
        "slowTranslator": Threshold(score: 85, misplaced: 2),  // seed 1: 97.0, 0; seeds 1-3: 96.8
        "halfRate": Threshold(score: 60, misplaced: 2),  // seed 1: 68.8, 0; seeds 1-3: 72.3
        "droppedFrames": Threshold(score: 80, misplaced: 2),  // seed 1: 95.3, 0; seeds 1-3: 84.7
        "cableScroll": Threshold(score: 70, misplaced: 2),  // seed 1: 81.9, 0; seeds 1-3: 81.1
        "iPhone": Threshold(score: 55, misplaced: 2),  // seed 1: 64.7, 0; seeds 1-3: 65.8
        "android": Threshold(score: 65, misplaced: 2),  // seed 1: 75.3, 0; seeds 1-3: 72.9
        "iPadLandscape": Threshold(score: 50, misplaced: 2),  // seed 1: 59.8, 0; seeds 1-3: 55.6
        // what a phone does besides scrolling
        "crossFade": Threshold(score: 90, misplaced: 2),  // seed 1: 100.0, 0; seeds 1-3: 100.0
        "swipeBack": Threshold(score: 70, misplaced: 2),  // seed 1: 79.5, 0; seeds 1-3: 82.8
        "keyboard": Threshold(score: 35, misplaced: 2),  // seed 1: 46.0, 0; seeds 1-3: 57.6
        "lateContent": Threshold(score: 65, misplaced: 2),  // seed 1: 73.8, 0; seeds 1-3: 78.9
        "zoom": Threshold(score: 85, misplaced: 2),  // seed 1: 96.3, 0; seeds 1-3: 98.7
        "largeTitle": Threshold(score: 60, misplaced: 2),  // seed 1: 73.6, 0; seeds 1-3: 64.9
        "typography": Threshold(score: 60, misplaced: 2),  // seed 1: 71.3, 0; seeds 1-3: 67.6
        "pullToRefresh": Threshold(score: 85, misplaced: 2),  // seed 1: 95.3, 0; seeds 1-3: 93.8
        "rotation": Threshold(score: 75, misplaced: 2),  // seed 1: 86.9, 0; seeds 1-3: 88.2
        "services": Threshold(score: 90, misplaced: 2),  // seed 1: 99.3, 0; seeds 1-3: 99.8
        "roughLink": Threshold(score: 65, misplaced: 2),  // seed 1: 75.4, 0; seeds 1-3: 69.6
    ]

    /// What a debug build plays: a still screen, a screen replaced by another one and an alert
    /// over the page. `scripts/test.sh` runs these suites in a debug build of the app, so they are
    /// kept to a few seconds there: a scenario that scrolls takes 10 to 30 s in a debug build. The
    /// tracker's own tests (OverlayTracker*Tests) scroll in every build; all scenarios run with
    /// `TRACKING_ALL=1` or in a release build.
    private static let quickScenarios: Set<String> = ["stillScreen", "newScreen", "alert"]
    /// A scenario with layers over each other whose truth a debug build also checks against its
    /// pictures (a few of them only)
    private static let quickLayeredScenario = "swipeBack"

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static var isQuickRun: Bool { isDebugBuild && environment["TRACKING_ALL"] != "1" }

    /// The scenarios the tests of the bench itself go through
    private static var scenarios: [TrackingScenarioSpec] {
        isQuickRun ? TrackingScenarios.all.filter { quickScenarios.contains($0.name) } : TrackingScenarios.all
    }

    /// The scenarios named in `TRACKING_SCENARIOS`, or all
    private static var chosenScenarios: [TrackingScenarioSpec] {
        let names = (environment["TRACKING_SCENARIOS"] ?? "").split(separator: ",").map(String.init)
        return TrackingScenarios.all.filter { names.isEmpty || names.contains($0.name) }
    }

    private func scenario(_ name: String, seed: UInt64) throws -> SimScenario {
        try XCTUnwrap(TrackingScenarios.make(name, seed: seed), "no scenario named \(name)")
    }

    private static func bench(_ scenario: SimScenario) -> TrackingBench {
        let bench = TrackingBench(scenario: scenario)
        if environment["TRACKING_VERBOSE"] == "1" {
            bench.log = { print($0) }
        }
        return bench
    }

    // MARK: The bench itself

    func testSameSeedGivesIdenticalFramesAndMetrics() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: the bench's determinism is checked in release builds; the tracker's in "
                          + "OverlayTrackerStressTests")
        }
        for name in ["flick", "banner", "rotation"] {
            let first = try scenario(name, seed: 7), second = try scenario(name, seed: 7)
            XCTAssertEqual(first.totalTickCount, second.totalTickCount)
            XCTAssertEqual(TrackingBenchTests.hash(of: first), TrackingBenchTests.hash(of: second), name)
            // the stand-in that works with what the recognizer returns, to have all of that in it
            let a = TrackingBench(scenario: first).run(TrackingGuided(scenario: first))
            let b = TrackingBench(scenario: second).run(TrackingGuided(scenario: second))
            XCTAssertEqual(a.withoutTimes, b.withoutTimes, name)
            XCTAssertGreaterThan(a.passes, 3, name)

            let other = try scenario(name, seed: 8)
            XCTAssertNotEqual(TrackingBenchTests.hash(of: first), TrackingBenchTests.hash(of: other), name)
        }
        // the tracker itself, twice on the same scenario: nothing is left over from a run
        let short = try scenario("textReplaced", seed: 7)
        let bench = TrackingBench(scenario: short)
        XCTAssertEqual(bench.run(OverlayTrackerSubject()).withoutTimes, bench.run(OverlayTrackerSubject()).withoutTimes)
    }

    /// FNV-1a over the thumbnails of every sixteenth tick
    private static func hash(of scenario: SimScenario) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for part in scenario.parts {
            for tick in stride(from: 0, to: part.tickCount, by: 16) {
                part.thumbnail(at: tick).pixels.withUnsafeBufferPointer { pixels in
                    for pixel in pixels {
                        hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                    }
                }
            }
        }
        return hash
    }

    /// The quick way to a thumbnail gives the same bytes as reducing the composed frame
    func testThumbnailsAreReducedFrames() throws {
        for spec in TrackingBenchTests.scenarios {
            for scenario in spec.make(3).parts {
                // the first picture, the one that lost the most detail, one from the second half
                // and every fortieth that differs from the one before
                var ticks: Set<Int> = [0]
                var worst = 0, worstLoss = -1
                var changes: [Int] = []
                for tick in 1..<scenario.tickCount where scenario.scenes[tick] != scenario.scenes[tick - 1] {
                    changes.append(tick)
                    let loss = scenario.scenes[tick].layers.map(\.loss).max() ?? 0
                    if loss > worstLoss {
                        worstLoss = loss
                        worst = tick
                    }
                }
                if !changes.isEmpty {
                    ticks.insert(worst)
                    ticks.insert(changes[changes.count * 2 / 3])
                    if !TrackingBenchTests.isDebugBuild {
                        for index in stride(from: 0, to: changes.count, by: 40) {
                            ticks.insert(changes[index])
                        }
                    }
                }
                for tick in ticks.sorted() {
                    let quick = scenario.thumbnail(at: tick)
                    let reduced = scenario.frame(at: tick).downsampled(by: scenario.scale)
                    XCTAssertTrue(quick == reduced, "\(spec.name), tick \(tick): the thumbnail is not the reduced frame")
                }
            }
        }
    }

    /// The picture and the truth agree: there is ink inside the rectangle of every line and none
    /// right above and below it, and the picture moves by exactly what its layer moves
    func testThePictureShowsWhatTheTruthSays() {
        let stage = SimStage("truth", seed: 21)
        stage.addBars()
        let page = stage.page(tenths: 25, profile: .article)
        // three pixels per tick: every other picture lies half a thumbnail pixel off the grid
        for tick in 0..<6 {
            stage.scenario.scenes.append(stage.scene(page, offset: 301 + 3 * tick))
        }
        stage.scenario.noise = 0
        stage.scenario.compression = 0
        let scenario = stage.finish()
        let scale = scenario.scale
        XCTAssertEqual(scale, 2)

        var linesChecked = 0
        let view = stage.viewport
        // the lines of the page, but not those right next to a bar
        let inner = SimRect(x: view.x, y: view.y + 2 * scale, width: view.width, height: view.height - 4 * scale)
        for tick in 0..<scenario.tickCount {
            let image = scenario.thumbnail(at: tick)
            for sight in scenario.lineSights(at: tick, within: scenario.frameRect) where inner.contains(sight.rect) {
                let sprite = scenario.sprites[sight.sprite]
                let background = Int(sprite.paragraphs[sprite.lines[sight.line].paragraph].background)
                let left = SimMath.ceilDiv(sight.rect.x, scale), right = SimMath.floorDiv(sight.rect.maxX, scale)
                let top = SimMath.floorDiv(sight.rect.y, scale), bottom = SimMath.ceilDiv(sight.rect.maxY, scale)
                guard right > left else { continue }
                var ink = 0, stray = 0
                for x in left..<right {
                    for y in top..<bottom where abs(Int(image[x, y]) - background) > 40 {
                        ink += 1
                    }
                    if abs(Int(image[x, top - 1]) - background) > 2 || abs(Int(image[x, bottom]) - background) > 2 {
                        stray += 1
                    }
                }
                let text = sprite.lines[sight.line].text
                XCTAssertGreaterThan(ink, (right - left) / 2, "tick \(tick): no text where \"\(text)\" is")
                XCTAssertEqual(stray, 0, "tick \(tick): ink outside of the line \"\(text)\"")
                linesChecked += 1
            }
        }
        XCTAssertGreaterThan(linesChecked, 50)

        // two ticks on, the page lies 6 pixels = 3 thumbnail pixels higher: the same picture, shifted
        let first = scenario.thumbnail(at: 1), later = scenario.thumbnail(at: 3)
        var differing = 0
        for y in (view.y / scale)..<(view.maxY / scale - 3) {
            for x in 0..<first.width where first[x, y + 3] != later[x, y] {
                differing += 1
            }
        }
        XCTAssertEqual(differing, 0)
    }

    /// What can be seen of every line according to the truth is what the frame shows of it:
    /// the pixels of a visible part are those of its sprite, a hidden part shows something else
    func testVisibilityOfTheTruthMatchesTheFrames() throws {
        for name in ["floatingButton", "stickyHeader", "banner", "keyboard", "swipeBack", "lateContent"] {
            if TrackingBenchTests.isQuickRun, name != TrackingBenchTests.quickLayeredScenario { continue }
            let scenario = try scenario(name, seed: 4)
            scenario.noise = 0
            var partlyHidden = 0
            let samples = TrackingBenchTests.isDebugBuild ? 3 : 9
            for tick in stride(from: 0, to: scenario.tickCount, by: max(1, scenario.tickCount / samples)) {
                // (pictures without loss of detail only: there the frame is the sprites as they are)
                guard !scenario.scenes[tick].layers.contains(where: { $0.loss > 0 }) else { continue }
                let frame = scenario.frame(at: tick)
                let layers = scenario.scenes[tick].layers
                let painted = scenario.paintedRects(at: tick)
                for sight in scenario.lineSights(at: tick, within: scenario.frameRect) {
                    let layer = layers[sight.layer]
                    let sprite = scenario.sprites[sight.sprite]
                    let whole = sight.rect.intersection(scenario.frameRect)
                    var seen = 0, same = 0
                    for y in whole.y..<whole.maxY {
                        for x in whole.x..<whole.maxX {
                            // the topmost layer that paints this pixel
                            var top = -1
                            for (index, rect) in painted.enumerated() where x >= rect.x && x < rect.maxX && y >= rect.y
                                && y < rect.maxY {
                                top = index
                            }
                            guard top == sight.layer else { continue }
                            seen += 1
                            if frame[x, y] == sprite.pixels[(y - layer.y) * sprite.width + x - layer.x] { same += 1 }
                        }
                    }
                    XCTAssertEqual(seen, sight.visibleArea, "\(name), tick \(tick): \"\(sprite.lines[sight.line].text)\"")
                    XCTAssertEqual(same, seen, "\(name), tick \(tick): the frame does not show the line where the truth has it")
                    if seen < sight.rect.area { partlyHidden += 1 }
                }
            }
            XCTAssertGreaterThan(partlyHidden, 0, "\(name): no line was ever covered in part")
        }
    }

    /// `TextLayout.blocks` finds exactly the paragraphs the simulator has in mind
    func testSpritesAreMadeOfTheirParagraphs() {
        for spec in TrackingBenchTests.isQuickRun ? TrackingBenchTests.scenarios : TrackingScenarios.all {
            for scenario in spec.make(TrackingBenchTests.isQuickRun ? 2 : 13).parts {
                for sprite in scenario.sprites where !sprite.lines.isEmpty {
                    let size = CGSize(width: sprite.width, height: sprite.height)
                    let lines = sprite.lines.map { line in
                        RecognizedLine(text: line.text, rect: CGRect(x: CGFloat(line.rect.x) / size.width,
                                                                     y: CGFloat(line.rect.y) / size.height,
                                                                     width: CGFloat(line.rect.width) / size.width,
                                                                     height: CGFloat(line.rect.height) / size.height))
                    }
                    let found = TextLayout.blocks(lines, imageSize: size).map(\.text).sorted()
                    XCTAssertEqual(found, sprite.paragraphs.map(\.text).sorted(), "\(spec.name), sprite \(sprite.index)")
                }
            }
        }
    }

    func testRecognizerReturnsTheGroundTruth() throws {
        for name in ["stillScreen", "frostedBars", "floatingButton", "iPadLandscape", "darkTheme"] {
            let scenario = try scenario(name, seed: 4)
            let bench = TrackingBench(scenario: scenario)

            // the whole frame: every paragraph that is completely visible comes back as one block
            // with its text and its rectangle, give or take the noise
            var complete: [String: SimRect] = [:]
            var single: SimRect?
            var texts: [String] = []
            for sight in scenario.paragraphSights(at: 0) {
                let paragraph = scenario.sprites[sight.sprite].paragraphs[sight.paragraph]
                guard paragraph.isTranslatable else { continue }
                texts.append(paragraph.text)
                guard sight.isFullyVisible else { continue }
                complete[paragraph.text] = sight.rect
                if paragraph.lines.count == 1, sight.slot == SimSlot.page, single == nil { single = sight.rect }
            }
            XCTAssertGreaterThan(complete.count, 5, name)
            let blocks = bench.recognize(scenario.frameRect, tick: 0)
            var unsure = 0
            for (text, truth) in complete {
                guard let block = blocks.first(where: { $0.text == text }) else {
                    XCTFail("\(name): \"\(text)\" was not read")
                    continue
                }
                let noise = CGFloat(scenario.rectNoise(lineHeight: truth.height / max(1, block.lineCount))) + 0.5
                if scenario.reportsConfidence {
                    let confidence = try XCTUnwrap(block.confidence, name)
                    if confidence < 1 { unsure += 1 }
                } else {
                    XCTAssertNil(block.confidence, name)
                }
                XCTAssertEqual(block.rect.minX, CGFloat(truth.x), accuracy: noise, "\(name): \(text)")
                XCTAssertEqual(block.rect.maxX, CGFloat(truth.maxX), accuracy: noise, "\(name): \(text)")
                XCTAssertEqual(block.rect.minY, CGFloat(truth.y), accuracy: noise, "\(name): \(text)")
                XCTAssertEqual(block.rect.maxY, CGFloat(truth.maxY), accuracy: noise, "\(name): \(text)")
            }
            // some complete text is reported as uncertain, but not much of it
            XCTAssertLessThan(unsure, complete.count / 2, name)
            // the rest are the visible lines of paragraphs that are hidden in part, or lines
            // that are cut off and misread
            for block in blocks where complete[block.text] == nil {
                let isPart = texts.contains { $0.contains(block.text) }
                XCTAssertTrue(isPart || block.lineCount == 1 || block.text.contains(" "), "\(name): \"\(block.text)\"")
            }

            // A line of which the region shows the lower 70 %: misread half of the time, with the
            // visible part as rectangle and whatever confidence; never read as what it is.
            let line = try XCTUnwrap(single, name)
            let noise = CGFloat(scenario.rectNoise(lineHeight: line.height)) + 0.5
            let cut = line.y + line.height * 3 / 10
            let most = SimRect(x: 0, y: cut, width: scenario.frameWidth, height: line.height)
            var misread = 0, sure = 0
            for _ in 0..<60 {
                for block in bench.recognize(most, tick: 0) where block.rect.intersects(line.cgRect) {
                    XCTAssertNil(complete[block.text], name)
                    if (block.confidence ?? 1) >= 1 { sure += 1 }
                    XCTAssertEqual(block.rect.minY, CGFloat(cut), accuracy: noise, name)
                    XCTAssertEqual(block.rect.maxY, CGFloat(line.maxY), accuracy: noise, name)
                    misread += 1
                }
            }
            XCTAssertGreaterThan(misread, 15, name)
            XCTAssertLessThan(misread, 45, name)
            XCTAssertGreaterThan(sure, 0, "\(name): a cut line must not be recognizable by its confidence")
            // 40 % of it: not found at all
            let little = SimRect(x: 0, y: line.y + line.height * 6 / 10, width: scenario.frameWidth, height: line.height)
            for _ in 0..<10 {
                XCTAssertFalse(bench.recognize(little, tick: 0).contains { $0.rect.intersects(line.cgRect) }, name)
            }
        }
    }

    /// A pass never joins lines of different parts of the picture into one block: every block,
    /// also one with a line that was cut off and misread, can be traced back to lines of one layer
    func testRecognizedBlocksBelongToOneLayer() {
        for spec in TrackingBenchTests.scenarios {
            let scenario = spec.make(1)
            let bench = TrackingBench(scenario: scenario)
            var blocks = 0
            for tick in stride(from: 0, to: scenario.tickCount, by: 9) {
                for block in bench.recognize(scenario.frameRect, tick: tick) {
                    blocks += 1
                    XCTAssertGreaterThan(bench.layersShowing(block.text, tick: tick), 0,
                                         "\(spec.name), tick \(tick): \"\(block.text)\" is not the text of one layer")
                }
            }
            XCTAssertGreaterThan(blocks, 20, spec.name)
        }
    }

    func testOracleGetsTheFullScore() {
        for spec in TrackingBenchTests.scenarios {
            for seed: UInt64 in TrackingBenchTests.isQuickRun ? [5] : [5, 17] {
                let scenario = spec.make(seed)
                let result = TrackingBenchTests.bench(scenario).run(TrackingOracle(scenario: scenario))
                XCTAssertEqual(result.misplaced, 0, "\(spec.name), seed \(seed)")
                XCTAssertGreaterThanOrEqual(result.score, 99.9, "\(spec.name), seed \(seed)")
                XCTAssertGreaterThan(result.dueParagraphFrames, 100,
                                     "\(spec.name), seed \(seed): hardly anything to cover")
            }
        }
    }

    /// Perfect tracking with the real delays of reading and translating loses next to nothing:
    /// what the bench asks for can be done
    func testInformedStandInGetsNearlyTheFullScore() {
        for spec in TrackingBenchTests.scenarios {
            let scenario = spec.make(9)
            let result = TrackingBenchTests.bench(scenario).run(TrackingInformed(scenario: scenario))
            XCTAssertEqual(result.misplaced, 0, spec.name)
            XCTAssertGreaterThanOrEqual(result.score, 95, spec.name + ": " + TrackingReport.factors(result))
            XCTAssertLessThanOrEqual(result.areaRead, result.areaBudget, spec.name)
            XCTAssertLessThanOrEqual(Double(result.translationRequests), result.translationBudget, spec.name)
        }
    }

    /// Knowing only how the picture moves, and reading the way a tracker can, gets far everywhere:
    /// a reference for what tracking can reach (the first thresholds were set from it)
    func testGuidedStandInShowsWhatCanBeReached() {
        for spec in TrackingBenchTests.scenarios {
            let scenario = spec.make(TrackingBenchTests.regressionSeed)
            let result = TrackingBenchTests.bench(scenario).run(TrackingGuided(scenario: scenario))
            XCTAssertGreaterThanOrEqual(result.score, 60, spec.name + ": " + TrackingReport.factors(result))
            XCTAssertLessThanOrEqual(result.misplaced, 6, spec.name)
            // (it unites what is due into one box per pass: it may read up to the limit of waste)
            XCTAssertLessThanOrEqual(result.areaRead, 3 * result.areaBudget, spec.name)
        }
    }

    func testOffsetDelayAndMissingClipAreMeasured() throws {
        try skipBenchScoringInQuickRun()
        let scenario = try scenario("slowDrag", seed: 6)
        let bench = TrackingBench(scenario: scenario)

        // 3 and 4 pixels off: an error of exactly 5, nothing misplaced
        let off = bench.run(TrackingOracle(scenario: scenario, offsetX: 3, offsetY: -4))
        // (except next to a bar, where 4 pixels up are more than a thumbnail pixel into it)
        XCTAssertEqual(off.misplaced, off.misplacedCovering)
        XCTAssertLessThan(off.misplaced, off.placed / 50)
        XCTAssertEqual(off.movingMean, 5, accuracy: 1e-9)
        XCTAssertEqual(off.restingMax, 5, accuracy: 1e-9)
        XCTAssertEqual(off.jitterMovingMean, 0, accuracy: 1e-9)
        XCTAssertLessThan(off.score, 85)

        // a line too low: everything is misplaced
        let wrong = bench.run(TrackingOracle(scenario: scenario, offsetY: 44))
        XCTAssertEqual(wrong.misplaced, wrong.placed)
        XCTAssertEqual(wrong.misplacedOffText, wrong.placed)
        XCTAssertLessThan(wrong.score, 1)

        // one frame late: off by the speed while the page moves. (It stays off by the last step
        // at rest: a wireless source sends no further frame to catch up with.)
        let late = bench.run(TrackingOracle(scenario: scenario, delay: 1))
        XCTAssertGreaterThan(late.movingMean, 1)
        XCTAssertGreaterThan(late.jitterMovingMean, 0.1)
        XCTAssertLessThan(late.score, bench.run(TrackingOracle(scenario: scenario)).score - 5)

        // text that slides under the bars is drawn over them
        let unclipped = bench.run(TrackingOracle(scenario: scenario, clips: false))
        XCTAssertGreaterThan(unclipped.misplacedCovering, 20)
        XCTAssertEqual(unclipped.misplaced, unclipped.misplacedCovering)

        // only the first line of every paragraph: in the right place, but not what is wanted
        let partial = bench.run(TrackingOracle(scenario: scenario, firstLinesOnly: true))
        XCTAssertEqual(partial.misplaced, 0)
        XCTAssertGreaterThan(partial.halfRead, 1000)
        XCTAssertGreaterThan(partial.halfReadStarts, 5)
        XCTAssertLessThan(partial.coverageResting, 0.9)
        XCTAssertLessThan(partial.score, 60)
    }

    /// Tests of how the bench scores stand-ins play scrolling scenarios, which takes seconds each
    /// in a debug build; they say nothing about the tracker and run in release builds
    private func skipBenchScoringInQuickRun() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: a test of the bench's scoring; to run it: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
    }

    /// A stand-in that passes every call on to another one and can change what comes back
    private class Relay: TrackingSubject {
        let inner: TrackingSubject

        init(_ inner: TrackingSubject) {
            self.inner = inner
        }

        func prepare(_ scenario: SimScenario, tick: Int) { inner.prepare(scenario, tick: tick) }

        func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
            inner.advance(thumbnail, scale: scale, time: time)
        }

        var recognitionDue: TimeInterval? { inner.recognitionDue }

        func beginRecognition(time: TimeInterval) -> RecognitionRequest? { inner.beginRecognition(time: time) }

        func finishRecognition(_ request: RecognitionRequest, blocks: [RecognizedBlock], time: TimeInterval) {
            inner.finishRecognition(request, blocks: blocks, time: time)
        }

        func abandonRecognition(_ request: RecognitionRequest) { inner.abandonRecognition(request) }

        func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
            inner.textsAwaitingTranslation(limit: limit, time: time)
        }

        func setTranslation(_ translation: String, for text: String) { inner.setTranslation(translation, for: text) }

        func translationFailed(for text: String, time: TimeInterval) { inner.translationFailed(for: text, time: time) }

        func isSettled(at time: TimeInterval) -> Bool { inner.isSettled(at: time) }

        var blocks: [TrackedBlock] { inner.blocks }

        var followsContract: Bool { inner.followsContract }
    }

    /// Translations of which nothing is drawn are not held against the tracker
    func testWhatIsNotDrawnDoesNotCount() throws {
        try skipBenchScoringInQuickRun()
        final class Ghosts: Relay {
            var frame = CGRect.zero

            override func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
                var update = inner.advance(thumbnail, scale: scale, time: time)
                for block in update.placed {
                    // the same text somewhere else, but cut down to nothing or outside of the picture
                    var hidden = block
                    hidden.rect = block.rect.offsetBy(dx: 0, dy: 300)
                    hidden.visibleRect = CGRect(x: 10, y: 10, width: 0, height: 0)
                    update.placed.append(hidden)
                    var outside = block
                    outside.rect = block.rect.offsetBy(dx: 2 * frame.width, dy: 0)
                    outside.visibleRect = nil
                    update.placed.append(outside)
                }
                return update
            }
        }
        let scenario = try scenario("stopAndGo", seed: 6)
        let bench = TrackingBench(scenario: scenario)
        let plain = bench.run(TrackingOracle(scenario: scenario))
        let ghosts = Ghosts(TrackingOracle(scenario: scenario))
        ghosts.frame = scenario.frameRect.cgRect
        XCTAssertEqual(bench.run(ghosts).withoutTimes, plain.withoutTimes)
        XCTAssertEqual(plain.misplaced, 0)
    }

    func testFrozenBlocksFailOnScrolling() throws {
        try skipBenchScoringInQuickRun()
        let still = try scenario("stillScreen", seed: 1)
        XCTAssertGreaterThan(TrackingBench(scenario: still).run(TrackingFrozen()).score, 80)
        for name in ["slowDrag", "flick", "stopAndGo"] {
            let scenario = try scenario(name, seed: 1)
            let result = TrackingBench(scenario: scenario).run(TrackingFrozen())
            XCTAssertGreaterThan(result.misplaced, 300, name)
            XCTAssertLessThan(result.score, 5, name)
        }
    }

    /// Every way of cheating or blundering costs what it should: the stand-in with one vice
    /// lands clearly below the one without, and where the priorities say so, below the limit
    /// of the regression test
    func testCheatsCostWhatTheyShould() throws {
        try skipBenchScoringInQuickRun()
        func run(_ name: String, _ scenarioName: String, seed: UInt64 = 1) throws -> TrackingResult {
            let scenario = try scenario(scenarioName, seed: seed)
            let subject = try XCTUnwrap(TrackingSubjects.make(name, scenario: scenario))
            return TrackingBenchTests.bench(scenario).run(subject, name: name)
        }
        func limit(_ scenarioName: String) -> Double {
            TrackingBenchTests.thresholds[scenarioName]?.score ?? 100
        }
        let quick = TrackingBenchTests.isQuickRun
        func plays(_ name: String) -> Bool { !quick || TrackingBenchTests.quickScenarios.contains(name) }
        let honestFlick = try run("guided", "flick"), honestStill = try run("guided", "stillScreen")
        let honestStopAndGo = try run("guided", "stopAndGo")
        XCTAssertGreaterThan(honestFlick.score, limit("flick") + 10)
        XCTAssertGreaterThan(honestStill.score, limit("stillScreen") + 10)

        // never drawing: nothing
        XCTAssertEqual(try run("never", "flick").score, 0, accuracy: 0.01)
        XCTAssertEqual(try run("never", "stillScreen").score, 0, accuracy: 0.01)

        // dropping every block while it moves: no better than the tracker without tracking
        let hides = try run("hides", "flick")
        XCTAssertEqual(hides.coverageMoving ?? 1, 0, accuracy: 0.05)
        XCTAssertLessThan(hides.score, 50)
        XCTAssertLessThan(hides.score, limit("flick") - 15)

        // drawing one frame late: beside the text as soon as it moves at speed (fail safe, the
        // first priority: lower than not following at all) …
        let lags = try run("lags", "flick")
        XCTAssertGreaterThan(lags.misplaced, 100)
        XCTAssertLessThan(lags.score, hides.score)
        // … and at a crawl, a visible wobble
        if plays("slowDrag") {
            XCTAssertLessThan(try run("lags", "slowDrag").score, try run("guided", "slowDrag").score - 8)
        }

        // the whole frame on every tick: a still screen read over and over
        let whole = try run("whole", "stillScreen")
        XCTAssertGreaterThan(whole.areaRead, 4 * whole.areaBudget)
        XCTAssertLessThan(whole.wasteFactor, 0.9)
        XCTAssertLessThan(whole.score, limit("stillScreen") - 10)
        XCTAssertLessThan(try run("whole", "flick").score, honestFlick.score - 5)
        if plays("stillCable") { XCTAssertLessThan(try run("whole", "stillCable").score, limit("stillCable") - 10) }

        // a third of the screen read again and again
        let rereads = try run("rereads", "stillScreen")
        XCTAssertGreaterThan(rereads.areaRead, 3 * rereads.areaBudget)
        XCTAssertLessThan(rereads.score, limit("stillScreen"))

        // keeping translations whose text is gone
        for name in ["newScreen", "crossFade", "textReplaced"] where plays(name) {
            let stale = try run("stale", name)
            XCTAssertGreaterThan(stale.misplaced, 20, name)
            XCTAssertLessThan(stale.score, limit(name) - 15, name)
        }

        // drawing over what covers the text
        for name in ["flick", "floatingButton", "keyboard"] where plays(name) {
            let chrome = try run("chrome", name)
            XCTAssertGreaterThan(chrome.misplacedCovering + chrome.misplacedHidden, 20, name)
            XCTAssertLessThan(chrome.score, limit(name) - 15, name)
        }

        // translating lines that were cut off when they were read: misplaced once the rest of
        // the line comes into view sideways
        for name in ["pager", "swipeBack"] where plays(name) {
            let cut = try run("cut", name), honest = try run("guided", name)
            XCTAssertGreaterThan(cut.misplaced, honest.misplaced, name)
            XCTAssertLessThan(cut.score, limit(name), name)
        }

        // flicker: every translation gone for one frame every three quarters of a second
        let blinks = try run("blinks", "flick")
        XCTAssertGreaterThan(blinks.flickers, 20)
        XCTAssertLessThan(blinks.score, honestFlick.score - 5)
        if plays("stillCable") { XCTAssertLessThan(try run("blinks", "stillCable").score, limit("stillCable")) }

        // sizes that change from frame to frame: every text is drawn again and again (cost only)
        let wobbles = try run("wobbles", "flick")
        XCTAssertGreaterThan(Double(wobbles.textsDrawn), 2 * wobbles.drawBudget)
        XCTAssertLessThan(wobbles.score, honestFlick.score)

        // reading only when the picture rests: new text shows late
        if plays("steadyScroll") {
            XCTAssertLessThan(try run("atRest", "steadyScroll").score, try run("guided", "steadyScroll").score - 10)
        }

        // reading every strip once, without overlap, and never again: what was read in motion
        // stays half-read
        let once = try run("once", "stopAndGo")
        XCTAssertLessThan(once.score, honestStopAndGo.score - 10)

        // forgetting a translation when its text is read slightly differently
        let drops = try run("drops", "stopAndGo")
        XCTAssertLessThanOrEqual(drops.score, honestStopAndGo.score)
    }

    /// The stand-in for the code around the tracker makes its calls the way the contract and
    /// `ScreenTranslator` have them
    func testTheTrackerIsDrivenAsTheContractSays() throws {
        final class Recorder: Relay {
            struct Call {
                var kind: String
                var time: TimeInterval
                var tick: Int
            }
            var calls: [Call] = []
            var scenario: SimScenario?
            var tick = -1
            var lastImage: LumaImage?
            var imageBeforeResult: LumaImage?
            var hadResult = false
            var redrawsWithSamePicture = 0, redrawsWithOtherPicture = 0
            var running: RecognitionRequest?
            var startTime: TimeInterval = 0
            var startTick = -1
            var problems: [String] = []
            var blocksOnStartFrame = 0, blocksElsewhere = 0
            var abandonedAt: TimeInterval?
            var failedTexts: [String: TimeInterval] = [:]
            var translated: Set<String> = []
            var wasAnnounced = false

            override func prepare(_ scenario: SimScenario, tick: Int) {
                self.scenario = scenario
                self.tick = tick
                inner.prepare(scenario, tick: tick)
            }

            private func note(_ kind: String, _ time: TimeInterval) {
                if let last = calls.last, time < last.time {
                    problems.append("\(kind) at \(time) after \(last.kind) at \(last.time)")
                }
                calls.append(Call(kind: kind, time: time, tick: tick))
            }

            override func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
                if let last = calls.last(where: { $0.kind == "advance" }), time <= last.time {
                    problems.append("two frames at the same time \(time)")
                }
                note("advance", time)
                if hadResult {
                    // a result is followed by a redraw of the frame that was shown
                    if let before = imageBeforeResult, before == thumbnail {
                        redrawsWithSamePicture += 1
                    } else {
                        redrawsWithOtherPicture += 1
                    }
                    hadResult = false
                }
                lastImage = thumbnail
                let update = inner.advance(thumbnail, scale: scale, time: time)
                if update.recognitionDue != nil { wasAnnounced = true }
                return update
            }

            override func beginRecognition(time: TimeInterval) -> RecognitionRequest? {
                note("begin", time)
                if running != nil { problems.append("a pass was begun while another one was running") }
                if !wasAnnounced { problems.append("a pass was begun although no update had announced one") }
                if let due = inner.recognitionDue {
                    if due > time { problems.append("a pass was begun \(due - time) s early") }
                } else {
                    problems.append("a pass was begun although none was due")
                }
                if let abandoned = abandonedAt, time - abandoned < 0.5 - 1.0 / 60 {
                    problems.append("a pass was begun \(time - abandoned) s after a failed one")
                }
                let request = inner.beginRecognition(time: time)
                running = request
                startTime = time
                startTick = tick
                return request
            }

            override func finishRecognition(_ request: RecognitionRequest, blocks: [RecognizedBlock], time: TimeInterval) {
                note("finish", time)
                if running != request { problems.append("a pass was finished that had not been begun") }
                running = nil
                hadResult = true
                imageBeforeResult = lastImage
                // it took as long as its area asks for
                if let scenario {
                    let share = Double(request.region.width * request.region.height) / Double(scenario.frameRect.area)
                    let expected = 0.05 + 0.20 * share
                    if time - startTime < expected * 0.85 - 0.03 || time - startTime > expected * 1.15 + 0.03 {
                        problems.append("a pass over \(share) of the frame took \(time - startTime) s")
                    }
                    // … and returns what the frame it started on showed: every block begins and
                    // ends with a line that could be seen there (give or take the noise of the
                    // recognizer), and of a pass during which the picture moved, not in the
                    // frame that is shown when it ends
                    let starting = scenario.lineSights(at: startTick, within: scenario.frameRect).map(\.visible)
                    let ending = scenario.lineSights(at: tick, within: scenario.frameRect).map(\.visible)
                    func fits(_ block: RecognizedBlock, _ lines: [SimRect]) -> Bool {
                        let top = lines.contains {
                            abs(block.rect.minY - CGFloat($0.y)) <= 4 && abs(block.rect.minX - CGFloat($0.x)) <= 6
                        }
                        let bottom = lines.contains { abs(block.rect.maxY - CGFloat($0.maxY)) <= 4 }
                        return top && bottom
                    }
                    for block in blocks {
                        if fits(block, starting) {
                            blocksOnStartFrame += 1
                        } else {
                            blocksElsewhere += 1
                        }
                        if scenario.scenes[startTick] != scenario.scenes[tick], fits(block, ending), !fits(block, starting) {
                            problems.append("a block in the pixels of the frame at the end of the pass")
                        }
                        let center = CGPoint(x: block.rect.midX, y: block.rect.midY)
                        if !request.isFullFrame, !request.region.insetBy(dx: -4, dy: -4).contains(center) {
                            problems.append("a block outside of the region that was asked for")
                        }
                    }
                }
                inner.finishRecognition(request, blocks: blocks, time: time)
            }

            override func abandonRecognition(_ request: RecognitionRequest) {
                if running != request { problems.append("a pass was abandoned that had not been begun") }
                running = nil
                abandonedAt = calls.last?.time
                calls.append(Call(kind: "abandon", time: calls.last?.time ?? 0, tick: tick))
                inner.abandonRecognition(request)
            }

            override func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
                note("texts", time)
                let texts = inner.textsAwaitingTranslation(limit: limit, time: time)
                if texts.count > limit { problems.append("more texts than asked for") }
                for text in texts {
                    if translated.contains(text) { problems.append("a text was translated twice") }
                    if let failed = failedTexts[text], time - failed < TrackingBench.retryDelay {
                        problems.append("a failed text was offered again after \(time - failed) s")
                    }
                }
                return texts
            }

            override func setTranslation(_ translation: String, for text: String) {
                if translation != TrackingBench.translationPrefix + text { problems.append("a wrong translation") }
                translated.insert(text)
                hadResult = true
                imageBeforeResult = lastImage
                inner.setTranslation(translation, for: text)
            }

            override func translationFailed(for text: String, time: TimeInterval) {
                note("failed", time)
                failedTexts[text] = time
                hadResult = true
                imageBeforeResult = lastImage
                inner.translationFailed(for: text, time: time)
            }
        }

        // a still screen from a wireless source: one frame, and a redraw after every result
        let still = try scenario("stillScreen", seed: 3)
        var recorder = Recorder(OverlayTrackerSubject())
        var result = TrackingBench(scenario: still).run(recorder)
        XCTAssertEqual(recorder.problems, [])
        XCTAssertEqual(result.frames, 1)
        XCTAssertEqual(result.passes, 1)
        XCTAssertEqual(recorder.calls.filter { $0.kind == "advance" }.count, 1 + result.redraws)
        XCTAssertGreaterThanOrEqual(result.redraws, 2)
        XCTAssertEqual(recorder.redrawsWithOtherPicture, 0)
        XCTAssertEqual(recorder.calls.first?.kind, "advance")

        // scrolling: passes return what the frame they started on showed, although the picture
        // has moved on, and results are redrawn on the frame that was shown when they came in
        let moving = try scenario("steadyScroll", seed: 3)
        recorder = Recorder(TrackingGuided(scenario: moving))
        result = TrackingBench(scenario: moving).run(recorder)
        XCTAssertEqual(recorder.problems, [])
        XCTAssertGreaterThan(result.passes, 10)
        XCTAssertGreaterThan(recorder.blocksOnStartFrame, 30)
        XCTAssertLessThan(recorder.blocksElsewhere, recorder.blocksOnStartFrame / 4)
        XCTAssertEqual(recorder.redrawsWithOtherPicture, 0)
        XCTAssertGreaterThan(recorder.redrawsWithSamePicture, 10)

        // a cable: sixty frames a second also when nothing moves
        let cable = try scenario("stillCable", seed: 3)
        recorder = Recorder(OverlayTrackerSubject())
        result = TrackingBench(scenario: cable).run(recorder)
        XCTAssertEqual(recorder.problems, [])
        XCTAssertEqual(result.frames, cable.tickCount)

        // failing services: abandoned passes, a pause after each, texts put off and asked for again
        if !TrackingBenchTests.isQuickRun {
            let flaky = try scenario("services", seed: 3)
            recorder = Recorder(OverlayTrackerSubject())
            result = TrackingBench(scenario: flaky).run(recorder)
            XCTAssertEqual(recorder.problems, [])
            XCTAssertEqual(result.failedPasses, 2)
            XCTAssertEqual(recorder.calls.filter { $0.kind == "abandon" }.count, 2)
            XCTAssertGreaterThan(recorder.failedTexts.count, 2)
            XCTAssertTrue(recorder.failedTexts.keys.allSatisfy { recorder.translated.contains($0) },
                          "every text that was put off is translated in the end")
        }
    }

    // MARK: Regression, one scenario each

    private func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        if TrackingBenchTests.isQuickRun, !TrackingBenchTests.quickScenarios.contains(name) {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let seed = TrackingBenchTests.regressionSeed
        let scenario = try scenario(name, seed: seed)
        let result = TrackingBenchTests.bench(scenario).run(OverlayTrackerSubject(), name: "tracker")
        print(TrackingReport.header)
        print(TrackingReport.row(result))
        guard let threshold = TrackingBenchTests.thresholds[name] else {
            XCTFail("no threshold for \(name)", file: file, line: line)
            return
        }
        var failures: [String] = []
        if result.score < threshold.score {
            failures.append(String(format: "score %.1f is below %.1f (", result.score, threshold.score)
                            + TrackingReport.factors(result) + ")")
        }
        if result.misplaced > threshold.misplaced {
            failures.append("\(result.misplaced) misplaced block × frames, more than \(threshold.misplaced); the first at "
                            + "tick \(result.misplacedFirstTick), at most \(result.misplacedMostAtOnce) at once, for up to "
                            + "\(result.misplacedLongestRun) frames in a row")
        }
        if !TrackingBenchTests.isDebugBuild, result.advanceSameMs > 1 || result.advanceChangedMs > 3 {
            print(String(format: "[tracking] \(name): advance is slow: %.2f ms for a new picture, %.2f ms for the same one",
                         result.advanceChangedMs, result.advanceSameMs))
        }
        // what the tracker does against the contract always fails
        if result.contractSlips > 0 {
            let slips = result.events.filter { $0.contains("contract:") }.joined(separator: "\n  ")
            XCTFail("\(name), seed \(seed): \(result.contractSlips) slips against the contract\n  \(slips)", file: file,
                    line: line)
        }
        guard !failures.isEmpty else { return }
        let message = "\(name), seed \(seed): " + failures.joined(separator: "; ") + "\n  "
            + result.events.joined(separator: "\n  ")
        XCTFail(message, file: file, line: line)
    }

    func testStillScreen() throws { try check("stillScreen") }
    func testStillCable() throws { try check("stillCable") }
    func testNoisyCable() throws { try check("noisyCable") }
    func testSlowDrag() throws { try check("slowDrag") }
    func testSteadyScroll() throws { try check("steadyScroll") }
    func testFlick() throws { try check("flick") }
    func testFastFlick() throws { try check("fastFlick") }
    func testReverse() throws { try check("reverse") }
    func testTremble() throws { try check("tremble") }
    func testRubberBand() throws { try check("rubberBand") }
    func testStopAndGo() throws { try check("stopAndGo") }
    func testAlikeRows() throws { try check("alikeRows") }
    func testIdenticalRows() throws { try check("identicalRows") }
    func testSparsePage() throws { try check("sparsePage") }
    func testDarkTheme() throws { try check("darkTheme") }
    func testFrostedBars() throws { try check("frostedBars") }
    func testFloatingButton() throws { try check("floatingButton") }
    func testStickyHeader() throws { try check("stickyHeader") }
    func testPager() throws { try check("pager") }
    func testCarousel() throws { try check("carousel") }
    func testTicker() throws { try check("ticker") }
    /// (The cards stay: this cannot tell rest for each area from rest for the whole picture. It
    /// guards what the page does without a ticker; `testTickerLowRestsWithItsPage` guards the
    /// rest of the page beside a ticker that moves.)
    func testTickerStill() throws { try check("tickerStill") }
    func testTickerLow() throws { try check("tickerLow") }

    /// Rest is decided for each scrolling area, and the cards that glide sideways are an area of
    /// their own, also where the page's drag covers them: once the page rests, its paragraphs
    /// are translated, as completely as on a page without the cards. (With the cards' area taking
    /// the page's drag, this fell to 0.56–0.66 on seeds 1, 3 and 4; with rest decided for the
    /// whole picture, to 0.92 on seed 4 of tickerLow and 0.94 on seed 1 of ticker.)
    func testTickerLowRestsWithItsPage() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        for seed: UInt64 in 1...4 {
            let result = TrackingBenchTests.bench(try scenario("tickerLow", seed: seed)).run(OverlayTrackerSubject(),
                                                                                             name: "tracker")
            XCTAssertGreaterThanOrEqual(result.coverageResting, 0.95, "tickerLow, seed \(seed)")
        }
        let ticker = TrackingBenchTests.bench(try scenario("ticker", seed: 1)).run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertGreaterThanOrEqual(ticker.coverageResting, 0.99, "ticker, seed 1")
    }
    func testDiagonalPan() throws { try check("diagonalPan") }
    func testAlert() throws { try check("alert") }
    func testBanner() throws { try check("banner") }
    func testNewScreen() throws { try check("newScreen") }
    func testSlideOver() throws { try check("slideOver") }
    func testTextReplaced() throws { try check("textReplaced") }
    func testVideo() throws { try check("video") }
    func testSlowTranslator() throws { try check("slowTranslator") }
    func testHalfRate() throws { try check("halfRate") }
    func testDroppedFrames() throws { try check("droppedFrames") }
    func testCableScroll() throws { try check("cableScroll") }
    func testIPhone() throws { try check("iPhone") }
    func testAndroid() throws { try check("android") }
    func testIPadLandscape() throws { try check("iPadLandscape") }
    func testCrossFade() throws { try check("crossFade") }
    func testSwipeBack() throws { try check("swipeBack") }

    /// Seed 5 of swipeBack: a page read while it moved fast is read again once all that moves over
    /// it or under it rests, not once the area its centre lies in rests (that one rested while the
    /// page beside it slid on, and a reading taken mid-slide stayed 10 pixels beside its text).
    func testSwipeBackSeed5() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let result = TrackingBenchTests.bench(try scenario("swipeBack", seed: 5)).run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertLessThanOrEqual(result.misplaced, 2, result.events.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(result.score, 75)
    }

    /// Seed 13 of largeTitle: the label to go back, misread once while the bar has no title, stays
    /// where it is when the titled bar takes over. Both bars show it with the same misreading;
    /// with one of their own each, its translation counted as drawn over text that is not on the
    /// screen for 278 frames.
    func testLargeTitleSeed13() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let result = TrackingBenchTests.bench(try scenario("largeTitle", seed: 13)).run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertLessThanOrEqual(result.misplaced, 2, result.events.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(result.score, 45)
    }

    /// The same without the tracker: a text that sprites of one size show at the same place (the
    /// label to go back in the bar with and in the bar without a title, and in every blend of the
    /// two) is misread the same way in all of them, whatever a tracker happens to read on a seed.
    func testLargeTitleMisreadsALabelTheSameWayInEveryBar() throws {
        for seed in UInt64(1)...10 {
            let scenario = try scenario("largeTitle", seed: seed)
            var misreadings: [String: Set<String>] = [:]
            for sprite in scenario.sprites {
                for line in sprite.lines {
                    let place = "\(sprite.width)x\(sprite.height) \(line.text) at \(line.rect.x),\(line.rect.y)"
                    misreadings[place, default: []].insert(line.alternate)
                }
            }
            for (place, found) in misreadings.sorted(by: { $0.key < $1.key }) {
                XCTAssertEqual(found.count, 1, "seed \(seed): \(place) is misread as \(found.sorted())")
            }
        }
    }

    /// Seed 4 of floatingButton: the button learned while the list was dragged is still known
    /// after the last pixel of the drag, so a paragraph read at rest beside it is not drawn over
    /// its edge (8 misplaced frames and 60.3 when a frame that moved by a pixel cleared it)
    func testFloatingButtonSeed4() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let result = TrackingBenchTests.bench(try scenario("floatingButton", seed: 4))
            .run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertLessThanOrEqual(result.misplaced, 2, result.events.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(result.score, 70)
    }

    /// A page that springs back after a flick past its end: what a pass after the movement finds
    /// cut off is read again at rest, not drawn half-read (seeds 2 and 5 fell to 58.7 and 67.6,
    /// with 241 and 288 half-read frames, when such a pass counted as a reread)
    func testRubberBandSeeds2And5() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        for (seed, score): (UInt64, Double) in [(2, 63), (5, 75)] {
            let result = TrackingBenchTests.bench(try scenario("rubberBand", seed: seed)).run(OverlayTrackerSubject(),
                                                                                              name: "tracker")
            XCTAssertGreaterThanOrEqual(result.score, score, "rubberBand, seed \(seed)")
            XCTAssertLessThanOrEqual(result.halfRead, 150, "rubberBand, seed \(seed)")
        }
    }
    /// Seed 8 of halfRate: a paragraph read cut off while the page moved, and carried by it under
    /// the bar before the pass ended, is not at rest there, though nothing moves near the bar: it
    /// is read again once the page rests (it was drawn half-read for 235 frames when the place
    /// it had moved to decided)
    func testHalfRateSeed8() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let result = TrackingBenchTests.bench(try scenario("halfRate", seed: 8)).run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertGreaterThanOrEqual(result.score, 75)
        XCTAssertLessThanOrEqual(result.halfRead, 50)
    }
    /// Seed 8 of slideOver: the title of the top bar changes when the other screen starts to
    /// slide in. The old title's patch fitted the new one a fraction of a pixel away, so its
    /// translation stayed over the new title until a pass read the bar (46 misplaced frames).
    func testSlideOverSeed8() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let result = TrackingBenchTests.bench(try scenario("slideOver", seed: 8)).run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertLessThanOrEqual(result.misplaced, 2, result.events.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(result.score, 85)
    }
    /// Seed 19 of frostedBars: the page shows through the top bar, so its unchanged title fits a
    /// little worse while the page scrolls under it. It must not be taken for a title replaced in
    /// place: when it was, its translation stayed hidden, also at rest, until a pass read the bar
    /// again (coverage at rest 0.955 instead of 0.998).
    func testFrostedBarsSeed19() throws {
        if TrackingBenchTests.isQuickRun {
            throw XCTSkip("debug build: only the quick scenarios run; for all: TRACKING_ALL=1 scripts/test.sh TrackingBenchTests")
        }
        let result = TrackingBenchTests.bench(try scenario("frostedBars", seed: 19)).run(OverlayTrackerSubject(), name: "tracker")
        XCTAssertGreaterThanOrEqual(result.coverageResting, 0.98, result.events.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(result.misplaced, 2, result.events.joined(separator: "\n"))
    }
    func testKeyboard() throws { try check("keyboard") }
    func testLateContent() throws { try check("lateContent") }
    func testZoom() throws { try check("zoom") }
    func testLargeTitle() throws { try check("largeTitle") }
    func testTypography() throws { try check("typography") }
    func testPullToRefresh() throws { try check("pullToRefresh") }
    func testRotation() throws { try check("rotation") }
    func testServices() throws { try check("services") }
    func testRoughLink() throws { try check("roughLink") }

    func testEveryScenarioHasATestAndAThreshold() {
        XCTAssertEqual(Set(TrackingScenarios.all.map(\.name)).count, TrackingScenarios.all.count, "names must be unique")
        for spec in TrackingScenarios.all {
            XCTAssertNotNil(TrackingBenchTests.thresholds[spec.name], "no threshold for \(spec.name)")
        }
        XCTAssertEqual(TrackingBenchTests.thresholds.count, TrackingScenarios.all.count)
        for name in TrackingBenchTests.quickScenarios {
            XCTAssertNotNil(TrackingBenchTests.thresholds[name], "no scenario named \(name)")
        }
    }

    // MARK: Report

    func testReport() throws {
        let environment = TrackingBenchTests.environment
        if TrackingBenchTests.isDebugBuild, environment["TRACKING_SEEDS"] == nil {
            throw XCTSkip("debug build: the report takes long; to run it: TRACKING_SEEDS=1,2,3 scripts/test.sh TrackingBenchTests/testReport")
        }
        let seeds = (environment["TRACKING_SEEDS"] ?? "1,2,3").split(separator: ",").compactMap { UInt64($0) }
        let subject = environment["TRACKING_SUBJECT"] ?? "tracker"
        XCTAssertFalse(seeds.isEmpty, "TRACKING_SEEDS has no numbers")
        XCTAssertTrue(TrackingSubjects.names.contains(subject), "TRACKING_SUBJECT must be one of \(TrackingSubjects.names)")
        let start = ProcessInfo.processInfo.systemUptime
        var report = TrackingReport(subject: subject, seeds: seeds)
        for spec in TrackingBenchTests.chosenScenarios {
            for seed in seeds {
                let scenario = spec.make(seed)
                guard let candidate = TrackingSubjects.make(subject, scenario: scenario) else { continue }
                report.results.append(TrackingBenchTests.bench(scenario).run(candidate, name: subject))
            }
        }
        report.finish()
        print(report.table())
        let seconds = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "[tracking] %d runs in %.1f s", report.results.count, seconds))
        if let path = environment["TRACKING_REPORT"], !path.isEmpty {
            try report.json().write(to: URL(fileURLWithPath: path))
            print("[tracking] report written to \(path)")
        }
    }

    // MARK: Looking at a scenario

    /// Pictures of chosen ticks of chosen scenarios with the truth drawn in – blue: a paragraph
    /// that can be seen completely; red: one that cannot, with the part that can in orange;
    /// green: every line – and what the subject placed: teal when it is on its text, magenta
    /// when it is misplaced. A text file lists the layers, paragraphs and placed blocks of the
    /// same ticks.
    func testDumpPictures() throws {
        let environment = TrackingBenchTests.environment
        guard let folder = environment["TRACKING_DUMP"], !folder.isEmpty else { return }
        let seed = UInt64(environment["TRACKING_SEEDS"]?.split(separator: ",").first ?? "1") ?? 1
        let subjectName = environment["TRACKING_SUBJECT"] ?? "tracker"
        let showsFrames = environment["TRACKING_FULL"] == "1"
        for spec in TrackingBenchTests.chosenScenarios {
            let root = spec.make(seed)
            let total = root.totalTickCount
            // the ticks asked for, or seven spread over the scenario
            var ticks = (environment["TRACKING_TICKS"] ?? "").split(separator: ",").compactMap { Int($0) }
                .filter { $0 >= 0 && $0 < total }
            if ticks.isEmpty {
                ticks = Array(stride(from: 0, to: total, by: max(1, total / 6)))
            }
            let wanted = Set(ticks)
            var views: [Int: TrackingFrameView] = [:]
            if let subject = TrackingSubjects.make(subjectName, scenario: root) {
                let bench = TrackingBench(scenario: root)
                bench.observer = { view in
                    if wanted.contains(view.clock) { views[view.clock] = view }
                }
                _ = bench.run(subject, name: subjectName)
            }
            var listing = "\(spec.name), seed \(seed), subject \(subjectName)\n"
            for tick in ticks {
                guard let view = views[tick] else { continue }
                let scenario = view.scenario
                let shown = view.shownTick
                let image = showsFrames ? scenario.frame(at: shown) : scenario.thumbnail(at: shown)
                let factor = showsFrames ? 1 : scenario.scale
                var canvas = TrackingCanvas(image: image, factor: factor)
                listing += "\ntick \(tick): frame of tick \(shown), \(scenario.frameWidth) × \(scenario.frameHeight)\n"
                for layer in scenario.scenes[shown].layers {
                    listing += "  layer in slot \(layer.slot): sprite \(layer.sprite) at (\(layer.x), \(layer.y)), paints "
                        + TrackingBench.describe(scenario.paintedRect(of: layer).cgRect)
                        + (layer.loss > 0 ? ", loss \(layer.loss)" : "") + "\n"
                }
                for sight in scenario.paragraphSights(at: shown) {
                    let paragraph = scenario.sprites[sight.sprite].paragraphs[sight.paragraph]
                    if sight.isFullyVisible {
                        canvas.outline(sight.rect, red: 0, green: 150, blue: 255)
                    } else {
                        canvas.outline(sight.rect, red: 255, green: 0, blue: 0)
                        canvas.outline(sight.visible, red: 255, green: 160, blue: 0)
                    }
                    listing += "  paragraph in slot \(sight.slot) at " + TrackingBench.describe(sight.rect.cgRect)
                        + (sight.isFullyVisible ? ", complete" : ", visible " + TrackingBench.describe(sight.visible.cgRect))
                        + (paragraph.isTranslatable ? "" : ", nothing to translate") + ": \"\(paragraph.text)\"\n"
                }
                for sight in scenario.lineSights(at: shown, within: scenario.frameRect) {
                    canvas.outline(sight.visible, red: 0, green: 200, blue: 0)
                }
                for (index, block) in view.placed.enumerated() {
                    let verdict = view.verdicts[index]
                    let rect = SimRect(covering: block.visibleRect.map { block.rect.intersection($0) } ?? block.rect)
                    if verdict == "onText" {
                        canvas.outline(rect, red: 0, green: 170, blue: 170)
                    } else if verdict != "notDrawn" {
                        canvas.outline(rect, red: 255, green: 0, blue: 255)
                    }
                    listing += "  placed \(verdict): id \(block.id) at " + TrackingBench.describe(block.rect)
                        + (block.visibleRect.map { ", visible " + TrackingBench.describe($0) } ?? "")
                        + ", \(block.lineCount) lines: \"\(block.text)\"\n"
                }
                let file = "\(spec.name)-\(seed)-\(tick).ppm"
                try canvas.ppm().write(to: URL(fileURLWithPath: folder).appendingPathComponent(file))
            }
            try Data(listing.utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(spec.name)-\(seed).txt"))
        }
    }
}

/// A picture in color to draw outlines into
struct TrackingCanvas {
    let width: Int
    let height: Int
    /// frame pixels per pixel of the picture
    let factor: Int
    private var pixels: [UInt8]

    init(image: LumaImage, factor: Int) {
        width = image.width
        height = image.height
        self.factor = factor
        pixels = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for index in 0..<(image.width * image.height) {
            pixels[3 * index] = image.pixels[index]
            pixels[3 * index + 1] = image.pixels[index]
            pixels[3 * index + 2] = image.pixels[index]
        }
    }

    private mutating func put(_ x: Int, _ y: Int, red: UInt8, green: UInt8, blue: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[3 * (y * width + x)] = red
        pixels[3 * (y * width + x) + 1] = green
        pixels[3 * (y * width + x) + 2] = blue
    }

    /// The outline of a rectangle given in frame pixels
    mutating func outline(_ rect: SimRect, red: UInt8, green: UInt8, blue: UInt8) {
        guard !rect.isEmpty else { return }
        let left = SimMath.floorDiv(rect.x, factor), top = SimMath.floorDiv(rect.y, factor)
        let right = SimMath.ceilDiv(rect.maxX, factor) - 1, bottom = SimMath.ceilDiv(rect.maxY, factor) - 1
        guard right >= left, bottom >= top else { return }
        var x = max(0, left)
        while x <= min(width - 1, right) {
            put(x, top, red: red, green: green, blue: blue)
            put(x, bottom, red: red, green: green, blue: blue)
            x += 1
        }
        var y = max(0, top)
        while y <= min(height - 1, bottom) {
            put(left, y, red: red, green: green, blue: blue)
            put(right, y, red: red, green: green, blue: blue)
            y += 1
        }
    }

    /// As a binary PPM file
    func ppm() -> Data {
        var data = Data("P6\n\(width) \(height)\n255\n".utf8)
        data.append(contentsOf: pixels)
        return data
    }
}
