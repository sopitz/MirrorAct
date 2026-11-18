// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Writes what the tracker did in a few scenarios, for comparing it with other MirrorAct apps,
/// which write the same lines from the same core: when `TRACKING_PARITY` names a file,
/// for every display frame of the scenarios (`TRACKING_SCENARIOS`, default below) and seed 1 (or
/// the first of `TRACKING_SEEDS`) a checksum over the placed rectangles, and per scenario the
/// metrics of the run and a checksum over all its frames. Doubles are written as their bits.
final class TrackingParityTests: XCTestCase {
    static let defaultScenarios = ["steadyScroll", "flick", "slowDrag", "stopAndGo", "alikeRows", "stillScreen", "banner",
                                   "rotation"]

    private static let basis: UInt64 = 0xCBF2_9CE4_8422_2325

    private static func fnv(_ start: UInt64, _ text: String) -> UInt64 {
        var hash = start
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A double as the 16 hex digits of its bits
    static func bits(_ value: Double) -> String {
        let digits = String(value.bitPattern, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// The placed blocks of one display frame as text: id, rectangle, visible part, lines, text
    static func describe(_ placed: [PlacedBlock]) -> String {
        var text = ""
        for block in placed {
            text += "\(block.id) " + bits(Double(block.rect.minX)) + " " + bits(Double(block.rect.minY)) + " "
                + bits(Double(block.rect.width)) + " " + bits(Double(block.rect.height)) + " "
            if let visible = block.visibleRect {
                text += bits(Double(visible.minX)) + " " + bits(Double(visible.minY)) + " " + bits(Double(visible.width)) + " "
                    + bits(Double(visible.height))
            } else {
                text += "whole"
            }
            text += " \(block.lineCount) \(block.text)\n"
        }
        return text
    }

    /// Every measured value (not the times and events), in an order other implementations repeat
    static func metrics(_ result: TrackingResult) -> String {
        var parts: [String] = []
        func number(_ name: String, _ value: Int) { parts.append("\(name)=\(value)") }
        func real(_ name: String, _ value: Double) { parts.append("\(name)=" + bits(value)) }
        func optional(_ name: String, _ value: Double?) { parts.append("\(name)=" + (value.map(bits) ?? "nil")) }
        real("score", result.score)
        real("misplacementFactor", result.misplacementFactor)
        real("wasteFactor", result.wasteFactor)
        real("coverage", result.coverage)
        real("coverageResting", result.coverageResting)
        optional("coverageMoving", result.coverageMoving)
        real("alignmentResting", result.alignmentResting)
        real("alignmentMoving", result.alignmentMoving)
        real("tidinessScore", result.tidinessScore)
        optional("latencyScore", result.latencyScore)
        real("costScore", result.costScore)
        number("misplaced", result.misplaced)
        number("misplacedOffText", result.misplacedOffText)
        number("misplacedHidden", result.misplacedHidden)
        number("misplacedCovering", result.misplacedCovering)
        number("misplacedUnknown", result.misplacedUnknown)
        number("misplacedMostAtOnce", result.misplacedMostAtOnce)
        number("misplacedLongestRun", result.misplacedLongestRun)
        number("misplacedFirstTick", result.misplacedFirstTick)
        number("placed", result.placed)
        number("movingSamples", result.movingSamples)
        real("movingMean", result.movingMean)
        real("moving95", result.moving95)
        real("movingMax", result.movingMax)
        number("restingSamples", result.restingSamples)
        real("restingMean", result.restingMean)
        real("resting95", result.resting95)
        real("restingMax", result.restingMax)
        real("jitterMovingMean", result.jitterMovingMean)
        real("jitterMoving95", result.jitterMoving95)
        real("jitterRestingMean", result.jitterRestingMean)
        number("dueParagraphFrames", result.dueParagraphFrames)
        number("coveredParagraphFrames", result.coveredParagraphFrames)
        number("dueMoving", result.dueMoving)
        number("coveredMoving", result.coveredMoving)
        real("latencyMedian", result.latencyMedian)
        real("latency95", result.latency95)
        number("latencySamples", result.latencySamples)
        number("flickers", result.flickers)
        number("coveredParagraphs", result.coveredParagraphs)
        number("halfRead", result.halfRead)
        number("halfReadStarts", result.halfReadStarts)
        number("staleReadings", result.staleReadings)
        real("scrollErrorMean", result.scrollErrorMean)
        real("scrollErrorMax", result.scrollErrorMax)
        number("contractSlips", result.contractSlips)
        number("frames", result.frames)
        number("redraws", result.redraws)
        number("passes", result.passes)
        number("failedPasses", result.failedPasses)
        real("areaRead", result.areaRead)
        real("areaBudget", result.areaBudget)
        number("translationRequests", result.translationRequests)
        number("translationBatches", result.translationBatches)
        real("translationBudget", result.translationBudget)
        number("textsDrawn", result.textsDrawn)
        number("textsDrawnLate", result.textsDrawnLate)
        real("drawBudget", result.drawBudget)
        return parts.joined(separator: " ")
    }

    func testDumpForComparison() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRACKING_PARITY"], !path.isEmpty else { return }
        let chosen = (environment["TRACKING_SCENARIOS"] ?? "").split(separator: ",").map(String.init)
        let names = chosen.isEmpty ? TrackingParityTests.defaultScenarios : chosen
        let seed = UInt64(environment["TRACKING_SEEDS"]?.split(separator: ",").first ?? "1") ?? 1
        var lines = ""
        for name in names {
            let scenario = try XCTUnwrap(TrackingScenarios.make(name, seed: seed), "no scenario named \(name)")
            let bench = TrackingBench(scenario: scenario)
            var total = TrackingParityTests.basis
            var frames = ""
            bench.observer = { view in
                let hash = TrackingParityTests.fnv(TrackingParityTests.basis, TrackingParityTests.describe(view.placed))
                total = TrackingParityTests.fnv(total, TrackingParityTests.hex(hash))
                frames += "frame \(name) \(view.clock) \(view.shownTick) \(view.placed.count) " + TrackingParityTests.hex(hash) + "\n"
            }
            let result = bench.run(OverlayTrackerSubject(), name: "tracker")
            lines += "scenario \(name) seed \(seed) ticks \(scenario.totalTickCount)\n"
            lines += frames
            lines += "metrics \(name) " + TrackingParityTests.metrics(result) + "\n"
            lines += "checksum \(name) " + TrackingParityTests.hex(total) + String(format: " score %.3f", result.score)
                + " misplaced \(result.misplaced)\n"
        }
        try Data(lines.utf8).write(to: URL(fileURLWithPath: path))
    }
}
