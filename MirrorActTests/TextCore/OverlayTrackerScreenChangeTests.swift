// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MirrorAct

/// A screen that comes after another and then stands still is read whole, whatever the screens
/// did in between: every line in full view is translated, and then the reading stops.
final class OverlayTrackerScreenChangeTests: XCTestCase {
    private static let scale = 3

    /// A line as Vision read it on the thumbnail (thumbnail pixels)
    private struct Line {
        var text: String
        var box: CGRect
        init(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
            self.text = text
            box = CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Network & internet on the lab's phone, as Vision read the thumbnail at rest
    private static let network = [
        Line("Netzwerk & Internet", 22, 122, 278, 34), Line("Internet", 60, 198, 66, 16),
        Line("AndroidWifi", 62, 218, 66, 12), Line("SIM-Karten", 54, 266, 96, 18), Line("T-Mobile", 62, 288, 50, 11),
        Line("Flugmodus", 52, 332, 100, 22), Line("Hotspot und Tethering", 52, 386, 186, 20), Line("Aus", 62, 408, 24, 12),
        Line("Datensparmodus", 52, 454, 146, 20), Line("Aus", 64, 478, 24, 10), Line("VPN", 54, 524, 46, 16),
        Line("Kein VPN", 64, 544, 52, 12), Line("Privates DNS", 20, 592, 104, 16), Line("An", 20, 614, 18, 12),
        Line("Adaptive Konnektivität", 20, 660, 180, 20), Line("An", 20, 682, 18, 12),
        Line("Sicherheit des Mobilfunknetzes", 20, 728, 248, 18),
    ]

    /// … and Connected devices
    private static let connected = [
        Line("Verbundene Geräte", 20, 124, 270, 30), Line("Neues Gerät koppeln", 54, 194, 174, 24),
        Line("Gespeicherte Geräte", 20, 254, 116, 12), Line("Alle anzeigen", 62, 293, 106, 20),
        Line("Verbindungseinstellungen", 20, 344, 206, 22), Line("Bluetooth, Android Auto", 20, 366, 132, 14),
        Line("Für andere Geräte als sdk_gphone64_arm64 sichtbar", 20, 450, 300, 14),
    ]

    /// What Vision reads of `lines` in `region` (frame pixels): a line of which the region holds
    /// nine tenths of the height, as far as its letters reach into the region (by their share of
    /// its width), in frame pixels; nothing of the others
    private static func recognize(_ lines: [Line], in region: CGRect) -> [RecognizedBlock] {
        var blocks: [RecognizedBlock] = []
        let factor = Double(scale)
        for line in lines {
            let box = CGRect(x: line.box.minX * factor, y: line.box.minY * factor, width: line.box.width * factor,
                             height: line.box.height * factor)
            let part = box.intersection(region)
            guard !part.isNull, part.height >= 0.9 * box.height, part.width >= 0.1 * box.width else { continue }
            let letters = Array(line.text)
            let from = Int(((part.minX - box.minX) / box.width * Double(letters.count)).rounded(.up))
            let to = Int(((part.maxX - box.minX) / box.width * Double(letters.count)).rounded(.down))
            guard to > from else { continue }
            let text = String(letters[from..<to]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            blocks.append(RecognizedBlock(text: text, rect: CGRect(x: part.minX, y: box.minY, width: part.width,
                                                                   height: box.height)))
        }
        return blocks
    }

    /// A thumbnail of the lab's phone (`Frames/ConnectedDevices/<number>.png`, 360 × 800, grey)
    private func thumbnail(_ number: Int) throws -> LumaImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "\(number)", withExtension: "png"),
                                "frame \(number)")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return LumaImage(width: image.width, height: image.height, pixels: pixels)
    }

    /// Settings goes from Network & internet to Connected devices, with Translate on: the frames
    /// of the lab's phone (thumbnails, as the app made them, at the times they came). The page
    /// before slides to the left; in one frame it has slid on and faded to half while the new
    /// page shows at half strength a little to the right of its place, and in the next frame
    /// the new page stands in its place. Both steps were followed as movements of what was
    /// there (by 36 and 32 thumbnail pixels), so only the spots where the old page's letters had
    /// been counted as changed: they were read in pieces, the pieces cut rows of the new page
    /// at their edges, and rows stayed untranslated on the still page for as long as it stood
    /// (in the lab in about one run of five; these are the frames of such a run). A movement
    /// that carries the blocks of the screen before, none of which is found where it took them,
    /// has replaced the picture: it is read again once everything over it rests (as a confirm
    /// read; read at once while it moves, rows that look alike may be placed a row off).
    func testAPageThatComesOverTheOneBeforeIsReadWhole() throws {
        let times = [-4.304, -0.018, 0.159, 0.309, 0.395, 0.458, 0.475, 0.499, 0.508, 0.519, 0.531, 0.545, 0.555, 0.567,
                     0.580, 0.590, 0.600, 1.112, 1.641, 1.666, 1.718, 1.729, 1.796, 1.832, 1.843, 1.854, 1.866, 1.879,
                     1.889, 1.899, 1.912, 1.933]
        let frames = try (281...312).map { try thumbnail($0) }
        let tracker = OverlayTracker()
        var pending: (request: RecognitionRequest, blocks: [RecognizedBlock], at: TimeInterval)?
        var placed: [PlacedBlock] = []
        var passesAfter = 0
        // the confirm places in the plan right after the frame in which the new page stands in
        // its place (frame 289): the replaced picture is read where it is in that frame
        var confirmAfterReplace: [CGRect] = []
        /// shows frame `index` from `start` to `end`, 60 times a second (a pass takes 0.08 s)
        func show(_ index: Int, from start: TimeInterval, to end: TimeInterval) {
            // (passes over the frames between the two pages read nothing)
            let lines = index == 0 ? Self.network : index >= 8 ? Self.connected : []
            var time = start
            repeat {
                placed = tracker.advance(frames[index], scale: Self.scale, time: time).placed
                if index == 8, time == start {
                    confirmAfterReplace = tracker.readingState.places.filter { $0.kind == "confirm" }.map(\.rect)
                }
                if let job = pending, time >= job.at {
                    tracker.finishRecognition(job.request, blocks: job.blocks, time: time)
                    pending = nil
                }
                if pending == nil, let due = tracker.recognitionDue, due <= time,
                   let request = tracker.beginRecognition(time: time) {
                    if index >= 8 { passesAfter += 1 }
                    pending = (request, Self.recognize(lines, in: request.region), time + 0.08)
                }
                for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                    tracker.setTranslation("T " + text, for: text)
                }
                time += 1.0 / 60
            } while time < end
        }
        for index in frames.indices {
            show(index, from: times[index], to: index + 1 < times.count ? times[index + 1] : times[index] + 12)
            if index == 0 {
                XCTAssertTrue(Self.network.allSatisfy { line in placed.contains { $0.text == "T " + line.text } },
                              "Network & internet translated")
            }
        }
        let width = Double(frames[8].width * Self.scale)
        XCTAssertTrue(confirmAfterReplace.contains { $0.minX <= 0 && $0.maxX >= width },
                      "the replaced page is read across its whole width: \(confirmAfterReplace)")
        for line in Self.connected {
            XCTAssertTrue(placed.contains { $0.text == "T " + line.text }, "'\(line.text)' drawn")
        }
        XCTAssertNil(tracker.recognitionDue)
        XCTAssertLessThanOrEqual(passesAfter, 30, "passes over the new page")
    }
}
