// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// A page that comes over another one the way Android brings it, and then stands still: every
/// line in full view is drawn, nothing is left that waits for a movement that does not come,
/// and the lines of the page before are not kept. Phone screens 1080 × 2400 (thumbnails at
/// scale 3), drawn with Core Text; the recognizer reads exactly what a region shows.
final class OverlayTrackerPageTransitionTests: XCTestCase {
    private typealias Line = OverlayTrackerStillPictureTests.Line
    private static let scale = 3, width = 1080, height = 2400

    private static func inkWidth(_ text: String, _ size: Double) -> Double {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font]))
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// A settings page: a title and rows below it (frame pixels)
    private static func page(_ title: String, _ rows: [String], pitch: Double) -> [Line] {
        var lines = [Line(text: title, box: CGRect(x: 60, y: 330, width: inkWidth(title, 84), height: 90), fontSize: 84)]
        for (index, text) in rows.enumerated() {
            lines.append(Line(text: text, box: CGRect(x: 160, y: 600 + pitch * Double(index), width: inkWidth(text, 50),
                                                      height: 60), fontSize: 50))
        }
        return lines
    }

    private static let network = page("Netzwerk & Internet", [
        "Internet", "SIM-Karten", "Flugmodus", "Hotspot und Tethering", "Datensparmodus", "VPN", "Privates DNS", "An",
        "Adaptive Konnektivitaet",
    ], pitch: 190)
    private static let connected = page("Verbundene Geraete", [
        "Neues Geraet koppeln", "Gespeicherte Geraete", "Alle anzeigen", "Verbindungseinstellungen",
        "Bluetooth, Android Auto", "Fuer andere Geraete sichtbar",
    ], pitch: 230)

    /// The thumbnail moved by (dx, dy) thumbnail pixels, the page's ground where nothing comes in
    private static func shifted(_ image: LumaImage, dx: Int, dy: Int) -> LumaImage {
        var copy = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                let sx = x - dx, sy = y - dy
                copy.pixels[y * image.width + x] = sx >= 0 && sx < image.width && sy >= 0 && sy < image.height
                    ? image.pixels[sy * image.width + sx] : 245
            }
        }
        return copy
    }

    /// `b` over `a` at `strength` (0 … 1)
    private static func blend(_ a: LumaImage, _ b: LumaImage, _ strength: Double) -> LumaImage {
        var copy = a
        for index in copy.pixels.indices {
            copy.pixels[index] = UInt8((Double(a.pixels[index]) * (1 - strength) + Double(b.pixels[index]) * strength)
                .rounded())
        }
        return copy
    }

    private struct Outcome {
        /// the lines of `last` drawn over at least half of their box at the end
        var drawn: [String] = []
        /// … and when each was drawn first, seconds after the last frame of the transition
        var drawnAfter: [String: Double] = [:]
        var blocks: [TrackedBlock] = []
        var places: [OverlayTracker.ReadingState.Place] = []
        var mostPassesOnPicture = 0
        var passesAtRest = 0
    }

    /// Page A still for 3 s, then the frames of the transition one after another at 30 frames per
    /// second, then the last of them still for `rest` seconds: the outcome for the lines of `last`.
    /// As on the phone's stream, no frame comes while the picture stands still: the app only shows
    /// the last one again after each pass (`ScreenTranslator`).
    private func play(_ steps: [LumaImage], last: [Line], rest: Double = 12) -> Outcome {
        let tracker = OverlayTracker()
        let first = OverlayTrackerStillPictureTests.picture([Self.network])
        var outcome = Outcome()
        var time = 0.0, seed: UInt64 = 11
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        var showing: [Line] = Self.network
        var stillFrom: Double?
        var shown = first, placed: [PlacedBlock] = []
        // (`picture` nil: no frame comes)
        func frame(_ picture: LumaImage?, fps: Double) {
            time += 1.0 / fps
            if let picture {
                seed += 1
                shown = SyntheticPage.noisy(picture, amount: 2, seed: seed)
                placed = tracker.advance(shown, scale: Self.scale, time: time).placed
            }
            var step = time
            while step < time + 1.0 / fps {
                if let job = pending, step >= job.at {
                    tracker.finishRecognition(job.request, blocks: job.answer, time: step)
                    pending = nil
                    // (the app shows the picture again after a pass)
                    placed = tracker.advance(shown, scale: Self.scale, time: step).placed
                }
                if pending == nil, let due = tracker.recognitionDue, due <= step,
                   let request = tracker.beginRecognition(time: step) {
                    if stillFrom != nil { outcome.passesAtRest += 1 }
                    pending = (request, OverlayTrackerStillPictureTests.recognize(showing.map { [$0] }, in: request.region),
                               step + 0.08)
                }
                outcome.mostPassesOnPicture = max(outcome.mostPassesOnPicture, tracker.readingState.passesOnPicture)
                step += 0.01
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                tracker.setTranslation("T " + text, for: text)
            }
            guard let stillFrom else { return }
            for line in last where outcome.drawnAfter[line.text] == nil && placed.contains(where: { block in
                let shown = (block.visibleRect ?? block.rect).intersection(line.box)
                return !shown.isNull && shown.width * shown.height * 2 >= line.box.width * line.box.height
            }) {
                outcome.drawnAfter[line.text] = time - stillFrom
            }
            outcome.drawn = last.filter { line in placed.contains { block in
                let shown = (block.visibleRect ?? block.rect).intersection(line.box)
                return !shown.isNull && shown.width * shown.height * 2 >= line.box.width * line.box.height
            } }.map(\.text)
        }
        while time < 3 { frame(first, fps: 30) }
        // (what the transition shows is not read: the recognizer sees nothing in it)
        showing = []
        for step in steps.dropLast() { frame(step, fps: 30) }
        showing = last
        frame(steps.last!, fps: 30)
        stillFrom = time
        while time < stillFrom! + rest - 1e-6 { frame(nil, fps: 30) }
        let state = tracker.readingState
        outcome.places = state.places
        outcome.blocks = tracker.blocks
        return outcome
    }

    /// Android brings Connected devices in sideways: the page before slides left and fades out
    /// while the new one slides in at half strength, over three frames, and stands in its place
    /// in the fourth. No movement carries the old page's blocks into the new one's place, so its
    /// lines are read in the pieces that changed, and the pieces cut the title.
    private static var slideSteps: [LumaImage] {
        let a = OverlayTrackerStillPictureTests.picture([network]), b = OverlayTrackerStillPictureTests.picture([connected])
        return [blend(shifted(a, dx: -12, dy: 0), shifted(b, dx: 60, dy: 0), 0.2),
                blend(shifted(a, dx: -48, dy: 0), shifted(b, dx: 32, dy: 0), 0.5),
                blend(shifted(a, dx: -60, dy: 0), shifted(b, dx: 8, dy: 0), 0.85), b]
    }

    /// The new page slides up over the old one, which stays where it is, in six frames
    private static var fromBelowSteps: [LumaImage] {
        let a = OverlayTrackerStillPictureTests.picture([network]), b = OverlayTrackerStillPictureTests.picture([connected])
        var steps: [LumaImage] = []
        for step in 1...6 {
            let offset = 800 - 800 * step / 6
            var image = a
            let coming = shifted(b, dx: 0, dy: offset)
            for y in offset..<image.height {
                for x in 0..<image.width { image.pixels[y * image.width + x] = coming.pixels[y * image.width + x] }
            }
            steps.append(image)
        }
        return steps
    }

    /// The blocks of the page before do not outlive it because no frame comes: they could not be
    /// found, and they are forgotten after `lostLifetime` also on a picture that stands still.
    func testTheLinesOfThePageBeforeAreForgottenOnAStillPicture() {
        let outcome = play(Self.slideSteps, last: Self.connected, rest: 4)
        for line in Self.network {
            XCTAssertFalse(outcome.blocks.contains { $0.text == line.text }, "'\(line.text)' of the page before is still kept")
        }
    }

    /// A movement that replaced the picture (`OverlayTracker.moveBlocks`) took the old page's
    /// blocks with it where they could not be found: they are gone with that page at once, and
    /// are not kept, carried along, for `lostLifetime`. (The rows the new page covered where they
    /// stood are kept there until then.)
    func testTheLinesOfAReplacedPageAreForgottenAtOnce() {
        let outcome = play(Self.fromBelowSteps, last: Self.connected, rest: 0.4)
        for line in Self.network {
            for block in outcome.blocks where block.text == line.text {
                XCTAssertEqual(block.rect.minY, line.box.minY, accuracy: 6,
                               "'\(line.text)' of the page before is kept where a movement carried it")
            }
        }
    }
}
