// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// When `OverlayTracker` offers a text again whose translation failed, and when one that was
/// not sent at all (Foundation only, like the core)
final class OverlayTrackerRetryTests: XCTestCase {
    private let scale = 2

    /// a tracker that knows the paragraphs `texts` on a still page, read at time 1
    private func tracker(knowing texts: [String]) throws -> OverlayTracker {
        var image = LumaImage(width: 200, height: 400, fill: 240)
        for row in texts.indices.map({ 40 + 80 * $0 }) {
            for y in row..<(row + 10) {
                for x in 20..<160 where (x / 6) % 2 == 0 { image[x, y] = 30 }
            }
        }
        let tracker = OverlayTracker()
        _ = tracker.advance(image, scale: scale, time: 0)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 1))
        let blocks = texts.enumerated().map { index, text in
            RecognizedBlock(text: text, rect: CGRect(x: 40, y: (40 + 80 * index) * scale, width: 280, height: 20))
        }
        tracker.finishRecognition(request, blocks: blocks, time: 1)
        return tracker
    }

    /// 5, 10, 20, 40 s, then every 60 s: the steps the engine takes for its service as well
    func testTheWaitOfATextThatKeepsFailingGrowsToAMinute() throws {
        let tracker = try tracker(knowing: ["Einstellungen"])
        var time: TimeInterval = 1
        var waits: [TimeInterval] = []
        for _ in 0..<7 {
            XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: time), ["Einstellungen"])
            tracker.translationFailed(for: "Einstellungen", time: time)
            let next = try XCTUnwrap(tracker.nextRetry(of: ["Einstellungen"]))
            XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: next - 0.1), [])
            waits.append(next - time)
            time = next
        }
        XCTAssertEqual(waits, [5, 10, 20, 40, 60, 60, 60])
    }

    /// A text the translator did not send because it waits for its service did not fail: it is
    /// offered again at once, and the wait of a text that did fail does not grow
    func testATextThatWasNotSentIsOfferedAgainWithoutAWaitOfItsOwn() throws {
        let tracker = try tracker(knowing: ["Einstellungen", "WLAN"])
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 1), ["Einstellungen", "WLAN"])
        tracker.translationFailed(for: "Einstellungen", time: 1)
        tracker.translationPostponed(for: "WLAN")
        XCTAssertEqual(tracker.nextRetry(of: ["Einstellungen", "WLAN"]), 1 + tracker.configuration.retryDelay)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 1.1), ["WLAN"])

        // not sent once more after its wait: still the first wait's length the next time it fails
        tracker.translationPostponed(for: "WLAN")
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 6.1), ["Einstellungen", "WLAN"])
        tracker.translationPostponed(for: "Einstellungen")
        tracker.translationPostponed(for: "WLAN")
        XCTAssertEqual(tracker.nextRetry(of: ["Einstellungen", "WLAN"]), 1 + tracker.configuration.retryDelay)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 6.2), ["Einstellungen", "WLAN"])
        tracker.translationFailed(for: "Einstellungen", time: 6.2)
        XCTAssertEqual(tracker.nextRetry(of: ["Einstellungen"]), 6.2 + 2 * tracker.configuration.retryDelay)
    }
}
