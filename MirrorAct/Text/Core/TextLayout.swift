// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A line of text found on the screen. `rect` is in image coordinates 0…1, origin at the top left.
struct RecognizedLine: Equatable {
    var text: String
    var rect: CGRect
    /// 0…1 where the recognizer says how sure it is, nil otherwise
    var confidence: Double?

    init(text: String, rect: CGRect, confidence: Double? = nil) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

/// Lines that belong together (a paragraph); `rect` like `RecognizedLine.rect`
struct TextBlock: Equatable {
    var text: String
    var rect: CGRect
    var lineCount: Int
    /// that of the least certain line, nil when the recognizer reports none
    var confidence: Double?

    init(text: String, rect: CGRect, lineCount: Int, confidence: Double? = nil) {
        self.text = text
        self.rect = rect
        self.lineCount = lineCount
        self.confidence = confidence
    }
}

/// Puts recognized lines in order: as plain text and as paragraphs for translating.
enum TextLayout {
    /// Top to bottom; lines at the same height from left to right
    static func readingOrder(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        var rows: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let first = rows.last?.first,
               abs(line.rect.midY - first.rect.midY) < min(first.rect.height, line.rect.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// All text, one row of the screen per line
    static func plainText(_ lines: [RecognizedLine]) -> String {
        readingOrder(lines)
            .map { $0.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// Joins the lines of a paragraph: same text size, directly below each other, aligned left or
    /// centered. `imageSize` in pixels, because x and y of the rects have different scales.
    static func blocks(_ lines: [RecognizedLine], imageSize: CGSize) -> [TextBlock] {
        struct Open {
            var block: TextBlock
            var last: CGRect   // last line, in pixels
        }
        var open: [Open] = []
        for line in readingOrder(lines).flatMap({ $0 }) {
            let rect = CGRect(x: line.rect.minX * imageSize.width, y: line.rect.minY * imageSize.height,
                              width: line.rect.width * imageSize.width, height: line.rect.height * imageSize.height)
            let match = open.lastIndex { candidate in
                let last = candidate.last
                let height = max(last.height, rect.height)
                let gap = rect.minY - last.maxY
                return abs(last.height - rect.height) < height * 0.25
                    && gap > -height * 0.3 && gap < height * 0.7
                    && (abs(last.minX - rect.minX) < height * 0.6 || abs(last.midX - rect.midX) < height * 0.6)
            }
            if let match {
                open[match].block.text += separator(after: open[match].block.text) + line.text
                open[match].block.rect = open[match].block.rect.union(line.rect)
                open[match].block.lineCount += 1
                if let confidence = line.confidence {
                    open[match].block.confidence = min(open[match].block.confidence ?? confidence, confidence)
                }
                open[match].last = rect
            } else {
                open.append(Open(block: TextBlock(text: line.text, rect: line.rect, lineCount: 1,
                                                  confidence: line.confidence), last: rect))
            }
        }
        return open.map(\.block)
    }

    /// Space between two lines of a paragraph; none in scripts written without spaces
    private static func separator(after text: String) -> String {
        guard let scalar = text.unicodeScalars.last else { return "" }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x9FFF, 0xFF00...0xFFEF, 0x3000...0x303F: return ""
        default: return " "
        }
    }

    /// Worth translating: contains at least two letters (not a time, a price or a symbol)
    static func isTranslatable(_ text: String) -> Bool {
        var letters = 0
        for character in text where character.isLetter {
            letters += 1
            if letters >= 2 { return true }
        }
        return false
    }
}
