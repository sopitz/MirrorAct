// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation

/// Reads what the text tracking needs straight from the pixels of a frame.
enum FramePixels {
    /// Grayscale thumbnail of a frame and the factor it was reduced by. nil for pixel formats
    /// other than bi-planar 4:2:0 (what the decoders and the cable capture deliver) and BGRA.
    static func thumbnail(of pixelBuffer: CVPixelBuffer) -> (image: LumaImage, scale: Int)? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let scale = LumaImage.scale(forFrameWidth: width, height: height)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            // the first plane is the brightness
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let image = LumaImage.downsampled(from: base, width: width, height: height,
                                              bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                                              format: .luma8, scale: scale)
            return (image, scale)
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let image = LumaImage.downsampled(from: base, width: width, height: height,
                                              bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                              format: .bgra8, scale: scale)
            return (image, scale)
        default:
            return nil
        }
    }

    /// The colors of the text block in `rect` (see `BlockColors.estimate`). For 4:2:0 frames
    /// they are also kept as the frame stores them, so that its box gets exactly those values.
    static func blockColors(in rect: CGRect, of pixelBuffer: CVPixelBuffer) -> BlockColors {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return BlockColors.estimate(pixels: colors(in: rect, of: pixelBuffer))
        }
        return BlockColors.estimate(samples: samples(in: rect, of: pixelBuffer), fullRange: fullRange)
    }

    /// Colors inside `rect` (frame pixels, origin at the top left) on a grid of at most about
    /// `limit` points; empty for other pixel formats or a rectangle outside the frame. For
    /// 4:2:0 frames the values are converted with `YCbCrColor`.
    static func colors(in rect: CGRect, of pixelBuffer: CVPixelBuffer, limit: Int = 600) -> [RGBColor] {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return samples(in: rect, of: pixelBuffer, limit: limit).map { $0.rgb(fullRange: fullRange) }
        }
        guard format == kCVPixelFormatType_32BGRA else { return [] }
        var colors: [RGBColor] = []
        withGrid(in: rect, of: pixelBuffer, limit: limit) { grid in
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            colors.reserveCapacity(grid.count)
            grid.forEach { x, y in
                let pixel = (base + y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
                colors.append(RGBColor(red: pixel[2], green: pixel[1], blue: pixel[0]))
            }
        }
        return colors
    }

    /// The values of a 4:2:0 frame inside `rect` as it stores them, on the same grid as
    /// `colors`; empty for other pixel formats or a rectangle outside the frame
    static func samples(in rect: CGRect, of pixelBuffer: CVPixelBuffer, limit: Int = 600) -> [YCbCrColor] {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return [] }
        var samples: [YCbCrColor] = []
        withGrid(in: rect, of: pixelBuffer, limit: limit) { grid in
            guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
            let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            samples.reserveCapacity(grid.count)
            grid.forEach { x, y in
                let luma = (lumaBase + y * lumaRowBytes).assumingMemoryBound(to: UInt8.self)
                // one pair of color values for every 2 × 2 pixels
                let chroma = (chromaBase + min(y / 2, chromaHeight - 1) * chromaRowBytes)
                    .assumingMemoryBound(to: UInt8.self)
                let pair = min(x / 2, chromaWidth - 1) * 2
                samples.append(YCbCrColor(y: luma[x], cb: chroma[pair], cr: chroma[pair + 1]))
            }
        }
        return samples
    }

    /// Points spread evenly over `rect` within the frame, row by row
    private struct Grid {
        let left: Int, top: Int, columns: Int, rows: Int, step: Int

        var count: Int { (columns / step + 1) * (rows / step + 1) }

        func forEach(_ body: (_ x: Int, _ y: Int) -> Void) {
            var y = top + min(step / 2, rows - 1)
            while y < top + rows {
                var x = left + min(step / 2, columns - 1)
                while x < left + columns {
                    body(x, y)
                    x += step
                }
                y += step
            }
        }
    }

    /// Calls `body` with the grid of about `limit` points in `rect` while the frame is locked
    /// for reading; not at all for a rectangle outside the frame or a frame that cannot be read
    private static func withGrid(in rect: CGRect, of pixelBuffer: CVPixelBuffer, limit: Int,
                                 _ body: (Grid) -> Void) {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let columns = Int(area.width), rows = Int(area.height)
        // about `limit` points, spread evenly
        let step = max(1, Int((Double(columns * rows) / Double(max(1, limit))).squareRoot()))
        body(Grid(left: Int(area.minX), top: Int(area.minY), columns: columns, rows: rows, step: step))
    }
}
