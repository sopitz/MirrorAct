// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// The thumbnail as it was first written, cell by cell: the definition `LumaImage.downsampled`
/// must match to the bit, however it gets there.
enum ReferenceThumbnail {
    static func downsampled(from base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                            format: LumaImage.PixelFormat, scale: Int) -> LumaImage {
        let outWidth = max(0, width) / scale, outHeight = max(0, height) / scale
        var result = LumaImage(width: outWidth, height: outHeight)
        guard outWidth > 0, outHeight > 0 else { return result }
        let divisor = (format == .luma8 ? 1 : 4) * scale * scale
        var sums = [Int](repeating: 0, count: outWidth)
        result.pixels.withUnsafeMutableBufferPointer { out in
            sums.withUnsafeMutableBufferPointer { sums in
                for outY in 0..<outHeight {
                    for outX in 0..<outWidth { sums[outX] = 0 }
                    for cellY in 0..<scale {
                        let row = (base + (outY * scale + cellY) * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        var index = 0
                        switch format {
                        case .luma8:
                            for outX in 0..<outWidth {
                                var sum = 0
                                for _ in 0..<scale {
                                    sum += Int(row[index])
                                    index += 1
                                }
                                sums[outX] += sum
                            }
                        case .bgra8:
                            for outX in 0..<outWidth {
                                var sum = 0
                                for _ in 0..<scale {
                                    sum += Int(row[index]) + 2 * Int(row[index + 1]) + Int(row[index + 2])
                                    index += 4
                                }
                                sums[outX] += sum
                            }
                        }
                    }
                    let offset = outY * outWidth
                    for outX in 0..<outWidth {
                        out[offset + outX] = UInt8((sums[outX] + divisor / 2) / divisor)
                    }
                }
            }
        }
        return result
    }
}

final class LumaImageTests: XCTestCase {
    /// Both ways over the same bytes give the same thumbnail
    static func assertMatchesReference(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                       format: LumaImage.PixelFormat, scale: Int, _ label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let fast = LumaImage.downsampled(from: base, width: width, height: height, bytesPerRow: bytesPerRow,
                                         format: format, scale: scale)
        let reference = ReferenceThumbnail.downsampled(from: base, width: width, height: height,
                                                       bytesPerRow: bytesPerRow, format: format, scale: scale)
        XCTAssertEqual(fast, reference, label, file: file, line: line)
    }

    private func assertMatchesReference(_ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                                        format: LumaImage.PixelFormat, scale: Int, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return XCTFail("no bytes", file: file, line: line) }
            LumaImageTests.assertMatchesReference(base, width: width, height: height, bytesPerRow: bytesPerRow,
                                                  format: format, scale: scale, label, file: file, line: line)
        }
    }

    /// Bytes of a plane: noise, the brightest values (the largest sums), values just below, or
    /// ramps; the padding at the end of the rows holds values too
    private func plane(_ random: inout SimRandom, count: Int) -> [UInt8] {
        let kind = random.below(4)
        return (0..<max(1, count)).map { index in
            switch kind {
            case 0: return UInt8(truncatingIfNeeded: random.next())
            case 1: return 255
            case 2: return UInt8(250 + random.below(6))
            default: return UInt8(truncatingIfNeeded: index &* 7 &+ index / 13)
            }
        }
    }

    func testThumbnailsMatchTheReferenceOnRandomPlanes() {
        var random = SimRandom(seed: 30)
        for round in 0..<800 {
            let format: LumaImage.PixelFormat = random.chance(50) ? .bgra8 : .luma8
            let bytesPerPixel = format == .bgra8 ? 4 : 1
            // every scale the tracker uses for phones and tablets, and larger ones
            let scale = random.chance(80) ? random.int(1, 8) : random.int(9, 24)
            // odd sizes, sizes below one cell, and rows with and without padding
            let width = random.int(0, 260), height = random.int(0, 40)
            let bytesPerRow = width * bytesPerPixel + (random.chance(30) ? 0 : random.int(1, 19))
            let bytes = plane(&random, count: bytesPerRow * height)
            assertMatchesReference(bytes, width: width, height: height, bytesPerRow: bytesPerRow, format: format,
                                   scale: scale,
                                   "round \(round): \(format) \(width)x\(height), \(bytesPerRow) bytes per row, scale \(scale)")
        }
    }

    /// The sums of a column are kept in 16 bits up to a scale of 257 (BGRA: 64); above that
    /// another way is taken, with the same result
    func testThumbnailsMatchTheReferenceAtTheLimitOfTheSums() {
        var random = SimRandom(seed: 31)
        for (format, scale) in [(LumaImage.PixelFormat.luma8, 257), (.luma8, 258), (.bgra8, 64), (.bgra8, 65)] {
            let bytesPerPixel = format == .bgra8 ? 4 : 1
            let width = 2 * scale + 5, height = scale + 3
            let bytesPerRow = width * bytesPerPixel + 3
            for brightest in [true, false] {
                let bytes = brightest ? [UInt8](repeating: 255, count: bytesPerRow * height)
                    : plane(&random, count: bytesPerRow * height)
                assertMatchesReference(bytes, width: width, height: height, bytesPerRow: bytesPerRow, format: format,
                                       scale: scale, "\(format) scale \(scale), brightest \(brightest)")
            }
        }
    }

    /// Frames of the tracking scenarios, reduced as the bench reduces them
    func testThumbnailsMatchTheReferenceOnScenarioFrames() {
        for name in ["steadyScroll", "flick", "rotation"] {
            guard let scenario = TrackingScenarios.make(name, seed: 1) else { return XCTFail("no scenario \(name)") }
            for part in scenario.parts {
                for tick in [0, part.scenes.count / 2, part.scenes.count - 1] {
                    let frame = part.frame(at: tick)
                    assertMatchesReference(frame.pixels, width: frame.width, height: frame.height,
                                           bytesPerRow: frame.width, format: .luma8, scale: part.scale,
                                           "\(name) tick \(tick)")
                }
            }
        }
    }
}
