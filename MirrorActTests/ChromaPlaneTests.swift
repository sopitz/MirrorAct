// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Where a block is drawn (`BlockPlacement`) and how it gets into the color plane of 4:2:0
/// video (`ChromaPlane`, `ChromaMask`): one color for every 2 × 2 pixels, which a box or a
/// text shares with its surroundings when it begins or ends at an odd pixel.
/// Needs Foundation only.
final class ChromaPlaneTests: XCTestCase {
    // MARK: Placement

    func testBlockIsPlacedOnWholePixelsWithAMargin() throws {
        let placement = try XCTUnwrap(BlockPlacement(rect: CGRect(x: 201.3, y: 120.6, width: 500.2, height: 59.8),
                                                     visibleRect: nil, lineCount: 1, frameWidth: 1170, frameHeight: 400))
        XCTAssertEqual(placement.text, PixelRect(minX: 201, minY: 121, maxX: 701, maxY: 181))
        // 12 % of the line height of 60
        XCTAssertEqual(placement.backdrop, PixelRect(minX: 194, minY: 114, maxX: 708, maxY: 188))
        XCTAssertEqual(placement.cornerRadius, 8)
        XCTAssertNil(placement.visible)
        XCTAssertEqual(placement.area, placement.backdrop)
    }

    func testMarginAndCornersFollowTheLineHeight() throws {
        // three lines of 20 pixels: 12 % would be 2.4, 20 % is 4
        let paragraph = try XCTUnwrap(BlockPlacement(rect: CGRect(x: 40, y: 40, width: 300, height: 60), visibleRect: nil,
                                                     lineCount: 3, frameWidth: 640, frameHeight: 360))
        XCTAssertEqual(paragraph.backdrop, PixelRect(minX: 38, minY: 38, maxX: 342, maxY: 102))
        XCTAssertEqual(paragraph.cornerRadius, 4, accuracy: 0.001)
        // small print: never less than two pixels around it
        let small = try XCTUnwrap(BlockPlacement(rect: CGRect(x: 40, y: 40, width: 80, height: 10), visibleRect: nil,
                                                 lineCount: 1, frameWidth: 640, frameHeight: 360))
        XCTAssertEqual(small.backdrop, PixelRect(minX: 38, minY: 38, maxX: 122, maxY: 52))
        XCTAssertEqual(small.cornerRadius, 2, accuracy: 0.001)
        // a line count of zero is taken as one line
        XCTAssertEqual(BlockPlacement(rect: CGRect(x: 40, y: 40, width: 300, height: 60), visibleRect: nil, lineCount: 0,
                                      frameWidth: 640, frameHeight: 360)?.backdrop,
                       PixelRect(minX: 33, minY: 33, maxX: 347, maxY: 107))
    }

    func testBlockKeepsItsSizeWhileItMoves() throws {
        // scrolled by fractions of a pixel: the drawn text is found again by the size
        for step in 0..<40 {
            let offset = CGFloat(step) * 0.173
            let size = try XCTUnwrap(BlockPlacement.textSize(of: CGRect(x: 10.4 + offset, y: 300.5 - offset, width: 333.4, height: 47.6)))
            XCTAssertEqual(size.width, 333)
            XCTAssertEqual(size.height, 48)
            let placement = try XCTUnwrap(BlockPlacement(rect: CGRect(x: 10.4 + offset, y: 300.5 - offset, width: 333.4, height: 47.6),
                                                         visibleRect: nil, lineCount: 1, frameWidth: 640, frameHeight: 720))
            XCTAssertEqual(placement.text.width, 333)
            XCTAssertEqual(placement.text.height, 48)
        }
    }

    func testAreaIsLimitedToTheFrameAndTheVisiblePart() throws {
        let rect = CGRect(x: 500, y: 300, width: 300, height: 100)
        // hangs over the right and the lower edge of the frame
        let clipped = try XCTUnwrap(BlockPlacement(rect: rect, visibleRect: nil, lineCount: 2, frameWidth: 640, frameHeight: 360))
        XCTAssertEqual(clipped.text, PixelRect(minX: 500, minY: 300, maxX: 800, maxY: 400))
        XCTAssertEqual(clipped.area, PixelRect(minX: 494, minY: 294, maxX: 640, maxY: 360))
        // a bar hides everything above row 320: also the margin is gone there
        let hidden = try XCTUnwrap(BlockPlacement(rect: rect, visibleRect: CGRect(x: 500, y: 320, width: 300, height: 80),
                                                  lineCount: 2, frameWidth: 640, frameHeight: 360))
        XCTAssertEqual(hidden.visible, PixelRect(minX: 500, minY: 320, maxX: 800, maxY: 400))
        XCTAssertEqual(hidden.area, PixelRect(minX: 500, minY: 320, maxX: 640, maxY: 360))
    }

    func testNothingToDrawGivesNoPlacement() {
        func placement(_ rect: CGRect, visible: CGRect? = nil) -> BlockPlacement? {
            BlockPlacement(rect: rect, visibleRect: visible, lineCount: 1, frameWidth: 640, frameHeight: 360)
        }
        XCTAssertNotNil(placement(CGRect(x: 10, y: 10, width: 100, height: 20)))
        XCTAssertNil(placement(CGRect(x: 700, y: 10, width: 100, height: 20)), "outside the frame")
        XCTAssertNil(placement(CGRect(x: 10, y: -80, width: 100, height: 20)), "outside the frame")
        XCTAssertNil(placement(CGRect(x: 10, y: 10, width: 100, height: 20), visible: CGRect(x: 10, y: 200, width: 100, height: 20)),
                     "hidden completely")
        XCTAssertNil(placement(CGRect(x: 10, y: 10, width: 100, height: 20), visible: .null))
        XCTAssertNil(placement(CGRect(x: 10, y: 10, width: 0.2, height: 20)), "no width")
        XCTAssertNil(placement(.null))
        XCTAssertNil(placement(.infinite))
        XCTAssertNil(placement(CGRect(x: CGFloat.nan, y: 10, width: 100, height: 20)))
        XCTAssertNil(placement(CGRect(x: 10, y: CGFloat.infinity, width: 100, height: 20)))
        XCTAssertNil(placement(CGRect(x: 1e12, y: 10, width: 100, height: 20)))
        XCTAssertNil(placement(CGRect(x: 10, y: 10, width: 100_000, height: 20)), "larger than any screen")
        XCTAssertNil(placement(CGRect(x: 10, y: 10, width: 8000, height: 8000)), "more pixels than any screen")
    }

    // MARK: The mask at the resolution of the color

    func testMaskIsReducedToTheCellsOfTheFrame() {
        // four columns and two rows of text
        let mask = [UInt8](repeating: 255, count: 8)
        let even = ChromaMask(mask: mask, width: 4, height: 2, oddX: false, oddY: false)
        XCTAssertEqual(even.width, 2)
        XCTAssertEqual(even.height, 1)
        XCTAssertEqual(even.pixels, [255, 255])
        XCTAssertEqual(even.runs, [ChromaMask.Run(row: 0, start: 0, end: 2)])
        // at an odd column the first and the last cell have one column of the block each
        let oddColumn = ChromaMask(mask: mask, width: 4, height: 2, oddX: true, oddY: false)
        XCTAssertEqual(oddColumn.width, 3)
        XCTAssertEqual(oddColumn.pixels, [128, 255, 128])
        // at an odd row the two rows of the block lie in two rows of cells
        let oddRow = ChromaMask(mask: mask, width: 4, height: 2, oddX: false, oddY: true)
        XCTAssertEqual(oddRow.height, 2)
        XCTAssertEqual(oddRow.pixels, [128, 128, 128, 128])
        let oddBoth = ChromaMask(mask: mask, width: 4, height: 2, oddX: true, oddY: true)
        XCTAssertEqual(oddBoth.pixels, [64, 128, 64, 64, 128, 64])
    }

    func testRunsSkipCellsWithoutText() {
        // 12 × 2: text in the columns 2…3 and 8…11
        var mask = [UInt8](repeating: 0, count: 24)
        for row in 0..<2 {
            for column in [2, 3, 8, 9, 10, 11] { mask[row * 12 + column] = 255 }
        }
        let reduced = ChromaMask(mask: mask, width: 12, height: 2, oddX: false, oddY: false)
        XCTAssertEqual(reduced.pixels, [0, 255, 0, 0, 255, 255])
        XCTAssertEqual(reduced.runs, [ChromaMask.Run(row: 0, start: 1, end: 2), ChromaMask.Run(row: 0, start: 4, end: 6)])
        XCTAssertTrue(ChromaMask(mask: [UInt8](repeating: 0, count: 24), width: 12, height: 2, oddX: true, oddY: true).runs.isEmpty)
        XCTAssertEqual(ChromaMask(mask: [], width: 0, height: 0, oddX: true, oddY: false).pixels, [])
    }

    /// Every position of a block in a frame: the reduced mask is the mean of the mask over the
    /// cells of the frame, whatever the size of the mask and wherever it begins
    func testReducedMaskMatchesTheMeanOverTheCellsOfTheFrame() {
        var random = Generator(seed: 7)
        for _ in 0..<60 {
            let width = 1 + random.next(9), height = 1 + random.next(7)
            let x = random.next(6), y = random.next(6)
            var mask = [UInt8](repeating: 0, count: width * height)
            for index in mask.indices where random.next(3) > 0 { mask[index] = UInt8(random.next(256)) }
            let reduced = ChromaMask(mask: mask, width: width, height: height, oddX: x % 2 == 1, oddY: y % 2 == 1)

            // the mask on a frame of 16 × 16 pixels, reduced the plain way
            var frame = [Int](repeating: 0, count: 256)
            for row in 0..<height {
                for column in 0..<width { frame[(y + row) * 16 + x + column] = Int(mask[row * width + column]) }
            }
            for cellY in 0..<8 {
                for cellX in 0..<8 {
                    // the four pixels of the cell
                    let upper = 2 * cellY * 16 + 2 * cellX, lower = upper + 16
                    let sum = frame[upper] + frame[upper + 1] + frame[lower] + frame[lower + 1]
                    let column = cellX - x / 2, row = cellY - y / 2
                    let inside = column >= 0 && column < reduced.width && row >= 0 && row < reduced.height
                    let value = inside ? Int(reduced.pixels[row * reduced.width + column]) : 0
                    XCTAssertEqual(value, (sum + 2) / 4, "mask \(width) × \(height) at \(x), \(y): cell \(cellX), \(cellY)")
                }
            }
            // the runs cover exactly the cells with text
            var covered = [Bool](repeating: false, count: reduced.pixels.count)
            for run in reduced.runs {
                XCTAssertLessThan(run.start, run.end)
                for column in run.start..<run.end { covered[run.row * reduced.width + column] = true }
            }
            XCTAssertEqual(covered, reduced.pixels.map { $0 > 0 })
        }
    }

    // MARK: Drawing into the color plane

    /// A plane of 8 × 6 cells (a frame of 16 × 12 pixels) with rows longer than their cells
    private final class Plane {
        let width = 8, height = 6, bytesPerRow = 24
        let memory: UnsafeMutablePointer<UInt8>
        var chroma: ChromaPlane { ChromaPlane(base: UnsafeMutableRawPointer(memory), bytesPerRow: bytesPerRow, width: width, height: height) }

        init() {
            memory = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
            for row in 0..<height {
                for column in 0..<bytesPerRow {
                    // cells: Cb 100, Cr 200; behind them padding that nobody may touch
                    memory[row * bytesPerRow + column] = column >= 2 * width ? 7 : (column % 2 == 0 ? 100 : 200)
                }
            }
        }

        deinit { memory.deallocate() }

        func cell(_ x: Int, _ y: Int) -> [UInt8] {
            [memory[y * bytesPerRow + 2 * x], memory[y * bytesPerRow + 2 * x + 1]]
        }

        var paddingIsUntouched: Bool {
            for row in 0..<height {
                for column in (2 * width)..<bytesPerRow where memory[row * bytesPerRow + column] != 7 { return false }
            }
            return true
        }
    }

    func testFillOnEvenPixelsSetsWholeCells() {
        let plane = Plane()
        // pixels 4…9 of the rows 2…7: the cells 2…4 of the rows 1…3
        plane.chroma.fill(PixelRect(minX: 4, minY: 2, maxX: 10, maxY: 8), cb: 30, cr: 60)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let inside = x >= 2 && x < 5 && y >= 1 && y < 4
                XCTAssertEqual(plane.cell(x, y), inside ? [30, 60] : [100, 200], "cell \(x), \(y)")
            }
        }
        XCTAssertTrue(plane.paddingIsUntouched)
    }

    func testFillOnOddPixelsSharesTheCellsAtItsEdges() {
        let plane = Plane()
        // pixels 3…8 of the rows 3…6: half of the cells 1 and 4, half of the rows 1 and 3
        plane.chroma.fill(PixelRect(minX: 3, minY: 3, maxX: 9, maxY: 7), cb: 20, cr: 40)
        XCTAssertEqual(plane.cell(2, 2), [20, 40], "all four pixels")
        XCTAssertEqual(plane.cell(3, 2), [20, 40])
        XCTAssertEqual(plane.cell(1, 2), [60, 120], "two of four pixels: half way from 100, 200 to 20, 40")
        XCTAssertEqual(plane.cell(4, 2), [60, 120])
        XCTAssertEqual(plane.cell(2, 1), [60, 120])
        XCTAssertEqual(plane.cell(3, 3), [60, 120])
        XCTAssertEqual(plane.cell(1, 1), [80, 160], "one of four pixels")
        XCTAssertEqual(plane.cell(4, 3), [80, 160])
        XCTAssertEqual(plane.cell(0, 2), [100, 200], "outside")
        XCTAssertEqual(plane.cell(5, 2), [100, 200])
        XCTAssertEqual(plane.cell(2, 0), [100, 200])
        XCTAssertEqual(plane.cell(2, 4), [100, 200])
        XCTAssertTrue(plane.paddingIsUntouched)
    }

    /// Any rectangle, also one that reaches beyond the plane: every cell gets the color in
    /// proportion to the number of its pixels that lie in the rectangle
    func testFillMatchesCountingThePixelsOfEveryCell() {
        var random = Generator(seed: 11)
        for _ in 0..<300 {
            let plane = Plane()
            let minX = random.next(24) - 4, minY = random.next(20) - 4
            let area = PixelRect(minX: minX, minY: minY, maxX: minX + random.next(14), maxY: minY + random.next(12))
            plane.chroma.fill(area, cb: 220, cr: 16)
            for y in 0..<plane.height {
                for x in 0..<plane.width {
                    var pixels = 0
                    for py in (2 * y)..<(2 * y + 2) {
                        for px in (2 * x)..<(2 * x + 2) where px >= area.minX && px < area.maxX && py >= area.minY && py < area.maxY {
                            pixels += 1
                        }
                    }
                    let rest = 4 - pixels
                    let cb: Int = (100 * rest + 220 * pixels + 2) / 4
                    let cr: Int = (200 * rest + 16 * pixels + 2) / 4
                    XCTAssertEqual(plane.cell(x, y), [UInt8(cb), UInt8(cr)], "area \(area): cell \(x), \(y)")
                }
            }
            XCTAssertTrue(plane.paddingIsUntouched, "area \(area)")
        }
    }

    func testBlendColorsTheCellsUnderTheText() {
        // a block of 6 × 4 pixels whose right half is text, at the pixel 5, 3 of the frame
        var mask = [UInt8](repeating: 0, count: 24)
        for row in 0..<4 {
            for column in 3..<6 { mask[row * 6 + column] = 255 }
        }
        let reduced = ChromaMask(mask: mask, width: 6, height: 4, oddX: true, oddY: true)
        let plane = Plane()
        let everything = PixelRect(minX: 0, minY: 0, maxX: 16, maxY: 12)
        plane.chroma.blend(reduced, x: 5, y: 3, within: everything, cb: 10, cr: 90)
        // the text covers the pixels 8…10 of the rows 3…6
        XCTAssertEqual(plane.cell(4, 2), [10, 90], "all four pixels are text")
        XCTAssertEqual(plane.cell(4, 1), [55, 145], "its lower two pixels are text: 128 of 255")
        XCTAssertEqual(plane.cell(5, 2), [55, 145], "its left two pixels are text")
        XCTAssertEqual(plane.cell(5, 3), [77, 172], "one pixel is text: 64 of 255")
        XCTAssertEqual(plane.cell(3, 2), [100, 200], "the left half of the block has no text")
        XCTAssertEqual(plane.cell(6, 2), [100, 200])
        XCTAssertEqual(plane.cell(4, 0), [100, 200])
        XCTAssertEqual(plane.cell(4, 4), [100, 200])
        XCTAssertTrue(plane.paddingIsUntouched)

        // only the cells that touch the area: here the rows of pixels from 6 on
        let limited = Plane()
        limited.chroma.blend(reduced, x: 5, y: 3, within: PixelRect(minX: 0, minY: 6, maxX: 16, maxY: 12), cb: 10, cr: 90)
        XCTAssertEqual(limited.cell(4, 2), [100, 200])
        XCTAssertEqual(limited.cell(4, 3), [55, 145])
        XCTAssertEqual(limited.cell(5, 3), [77, 172])
    }

    func testBlendLeavesOutWhatLiesOutsideThePlane() {
        // a block that begins left of and above the frame and one that hangs over its end
        let mask = [UInt8](repeating: 255, count: 6 * 6)
        let everything = PixelRect(minX: -100, minY: -100, maxX: 100, maxY: 100)
        let before = Plane()
        before.chroma.blend(ChromaMask(mask: mask, width: 6, height: 6, oddX: true, oddY: true), x: -3, y: -3, within: everything,
                            cb: 10, cr: 90)
        // its pixels 0…2 of the rows 0…2 are in the frame
        XCTAssertEqual(before.cell(0, 0), [10, 90])
        XCTAssertEqual(before.cell(1, 0), [55, 145])
        XCTAssertEqual(before.cell(1, 1), [77, 172])
        XCTAssertEqual(before.cell(2, 0), [100, 200])
        XCTAssertTrue(before.paddingIsUntouched)

        let behind = Plane()
        behind.chroma.blend(ChromaMask(mask: mask, width: 6, height: 6, oddX: false, oddY: false), x: 12, y: 8, within: everything,
                            cb: 10, cr: 90)
        XCTAssertEqual(behind.cell(5, 4), [100, 200])
        XCTAssertEqual(behind.cell(6, 3), [100, 200])
        XCTAssertEqual(behind.cell(6, 4), [10, 90])
        XCTAssertEqual(behind.cell(7, 5), [10, 90])
        XCTAssertTrue(behind.paddingIsUntouched)
    }

    /// Small numbers that are the same in every run
    private struct Generator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        /// 0 ..< limit
        mutating func next(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(limit))
        }
    }
}
