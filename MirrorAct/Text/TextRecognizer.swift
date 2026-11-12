// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Vision

/// Reads the text in a frame with Vision, on this Mac.
enum TextRecognizer {
    /// Lines of text in `region` (frame pixels, origin at the top left; nil = the whole frame).
    /// The rectangles of the result are in coordinates 0…1 of the whole frame, origin at the top
    /// left. Blocks while Vision works; call it off the main thread (or use `recognize`).
    static func lines(in pixelBuffer: CVPixelBuffer, region: CGRect? = nil) throws -> [RecognizedLine] {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // as a fraction of the picture's height; set explicitly because the documented default
        // (1/32) would skip ordinary text on a phone screen
        request.minimumTextHeight = 0.004
        // Vision counts from the bottom left, in fractions of the picture
        var interest = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let region {
            let part = region.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !part.isNull, part.width >= 1, part.height >= 1 else { return [] }
            interest = CGRect(x: part.minX / width, y: 1 - part.maxY / height,
                              width: part.width / width, height: part.height / height)
            request.regionOfInterest = interest
        }
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return RecognizedLine(text: candidate.string,
                                  rect: frameRect(of: observation.boundingBox, in: interest),
                                  confidence: Double(candidate.confidence))
        }
    }

    /// A bounding box as Vision reports it (fractions of the region of interest, from its bottom
    /// left) in fractions of the whole frame, from the top left
    static func frameRect(of box: CGRect, in interest: CGRect) -> CGRect {
        let x = interest.minX + box.minX * interest.width
        let bottom = interest.minY + box.minY * interest.height
        let size = CGSize(width: box.width * interest.width, height: box.height * interest.height)
        return CGRect(x: x, y: 1 - bottom - size.height, width: size.width, height: size.height)
    }

    /// The same in the background; nil if Vision failed
    static func recognize(_ pixelBuffer: CVPixelBuffer, region: CGRect? = nil) async -> [RecognizedLine]? {
        await Task.detached(priority: .userInitiated) { () -> [RecognizedLine]? in
            do {
                return try lines(in: pixelBuffer, region: region)
            } catch {
                Log.error("Text recognition: \(error.localizedDescription)")
                return nil
            }
        }.value
    }
}
