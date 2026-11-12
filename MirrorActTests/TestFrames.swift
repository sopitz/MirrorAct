// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import CoreVideo
import XCTest

/// Synthetic frames in the two pixel formats the app meets: BGRA and bi-planar 4:2:0 (what the
/// decoders and the cable deliver). A width like 1170 does not fill whole rows of memory, so
/// such frames have padded rows, as the real ones do.
enum TestFrames {
    /// A line of dark text: `top` is the top of its line box in pixels from the top of the frame
    struct Line {
        var text: String
        var x: CGFloat
        var top: CGFloat
        var fontSize: CGFloat = 48
    }

    static func blank(width: Int, height: Int, format: OSType, gray: UInt8 = 255) throws -> CVPixelBuffer {
        try frame(from: [UInt8](repeating: gray, count: width * height), width: width, height: height, format: format)
    }

    /// Dark gray (20) text on light gray (245), drawn with Core Text. The second value holds
    /// where the ink of each line lies, in frame pixels with the origin at the top left.
    static func text(_ lines: [Line], width: Int, height: Int,
                     format: OSType) throws -> (frame: CVPixelBuffer, inked: [CGRect]) {
        var gray = [UInt8](repeating: 245, count: width * height)
        var inked: [CGRect] = []
        try gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw XCTSkip("no grayscale context")
            }
            for line in lines {
                let font = CTFontCreateWithName("Helvetica" as CFString, line.fontSize, nil)
                let string = NSAttributedString(string: line.text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 20 / 255, alpha: 1),
                ])
                let ctLine = CTLineCreateWithAttributedString(string)
                let ascent = CTFontGetAscent(font)
                // Core Graphics counts from the bottom
                let baseline = CGFloat(height) - line.top - ascent
                context.textPosition = CGPoint(x: line.x, y: baseline)
                // measured before drawing: drawing moves the text position to the end of the line
                let ink = CTLineGetImageBounds(ctLine, context)
                CTLineDraw(ctLine, context)
                inked.append(CGRect(x: ink.minX, y: CGFloat(height) - ink.maxY, width: ink.width, height: ink.height))
            }
        }
        return (try frame(from: gray, width: width, height: height, format: format), inked)
    }

    /// The same picture moved down by `rows` (up for negative values), as when the content scrolls
    static func shifted(_ lines: [Line], by rows: CGFloat) -> [Line] {
        lines.map { line in
            var line = line
            line.top += rows
            return line
        }
    }

    /// A frame of `format` showing the gray values (one byte per pixel, rows without padding)
    static func frame(from gray: [UInt8], width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let frame = try XCTUnwrap(buffer, "no pixel buffer")
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        switch format {
        case kCVPixelFormatType_32BGRA:
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<height {
                for x in 0..<width {
                    let value = gray[y * width + x]
                    let pixel = base + y * rowBytes + 4 * x
                    pixel[0] = value
                    pixel[1] = value
                    pixel[2] = value
                    pixel[3] = 255
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 0)).assumingMemoryBound(to: UInt8.self)
            let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            for y in 0..<height {
                for x in 0..<width {
                    let value = Int(gray[y * width + x])
                    luma[y * lumaRowBytes + x] = UInt8(fullRange ? value : 16 + (value * 219 + 127) / 255)
                }
            }
            let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 1)).assumingMemoryBound(to: UInt8.self)
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
            for y in 0..<CVPixelBufferGetHeightOfPlane(frame, 1) {
                for x in 0..<CVPixelBufferGetWidthOfPlane(frame, 1) * 2 { chroma[y * chromaRowBytes + x] = 128 }
            }
        default:
            XCTFail("unsupported pixel format")
        }
        return frame
    }

    /// The brightness of every pixel, rows without padding (BGRA: the green channel)
    static func luma(of frame: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        var result = [UInt8](repeating: 0, count: width * height)
        if CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return result }
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<height {
                for x in 0..<width { result[y * width + x] = base[y * rowBytes + 4 * x + 1] }
            }
        } else {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)?.assumingMemoryBound(to: UInt8.self) else {
                return result
            }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            for y in 0..<height {
                for x in 0..<width { result[y * width + x] = base[y * rowBytes + x] }
            }
        }
        return result
    }

    /// Rows and columns in which two frames of the same size differ; nil if they are equal
    static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> CGRect? {
        let width = CVPixelBufferGetWidth(a)
        let first = luma(of: a), second = luma(of: b)
        guard first.count == second.count else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for index in first.indices where abs(Int(first[index]) - Int(second[index])) > 8 {
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
