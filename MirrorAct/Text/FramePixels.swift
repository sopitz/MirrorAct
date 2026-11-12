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

    /// Colors inside `rect` (frame pixels, origin at the top left) on a grid of at most about
    /// `limit` points; empty for other pixel formats or a rectangle outside the frame. For
    /// 4:2:0 frames the values are converted with `YCbCrColor`, which also converts them back.
    static func colors(in rect: CGRect, of pixelBuffer: CVPixelBuffer, limit: Int = 600) -> [RGBColor] {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let biPlanar = fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard biPlanar || format == kCVPixelFormatType_32BGRA else { return [] }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return [] }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let left = Int(area.minX), top = Int(area.minY), columns = Int(area.width), rows = Int(area.height)
        // about `limit` points, spread evenly
        let step = max(1, Int((Double(columns * rows) / Double(max(1, limit))).squareRoot()))
        var colors: [RGBColor] = []
        colors.reserveCapacity((columns / step + 1) * (rows / step + 1))

        if biPlanar {
            guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return [] }
            let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            var y = top + min(step / 2, rows - 1)
            while y < top + rows {
                let lumaRow = (lumaBase + y * lumaRowBytes).assumingMemoryBound(to: UInt8.self)
                // one pair of color values for every 2 × 2 pixels
                let chromaRow = (chromaBase + min(y / 2, chromaHeight - 1) * chromaRowBytes)
                    .assumingMemoryBound(to: UInt8.self)
                var x = left + min(step / 2, columns - 1)
                while x < left + columns {
                    let pair = min(x / 2, chromaWidth - 1) * 2
                    colors.append(YCbCrColor(y: lumaRow[x], cb: chromaRow[pair], cr: chromaRow[pair + 1])
                        .rgb(fullRange: fullRange))
                    x += step
                }
                y += step
            }
        } else {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            var y = top + min(step / 2, rows - 1)
            while y < top + rows {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                var x = left + min(step / 2, columns - 1)
                while x < left + columns {
                    colors.append(RGBColor(red: row[x * 4 + 2], green: row[x * 4 + 1], blue: row[x * 4]))
                    x += step
                }
                y += step
            }
        }
        return colors
    }
}
