// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreImage

/// Rahmt vorhandene Videos (z. B. Bildschirmaufnahmen vom iPhone) über eine AVVideoComposition
enum VideoFramer {
    struct Source {
        let asset: AVURLAsset
        let size: CGSize              // angezeigte Grösse (Drehung berücksichtigt)
        let transform: CGAffineTransform
        let duration: CMTime
    }

    enum FramerError: LocalizedError {
        case noVideo, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "Die Datei enthält keine Videospur."
            case let .exportFailed(reason): return "Export fehlgeschlagen: \(reason)"
            }
        }
    }

    static func load(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FramerError.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        return Source(asset: asset, size: CGSize(width: abs(shown.width), height: abs(shown.height)),
                      transform: transform, duration: duration)
    }

    /// Ist Transparenz nötig (→ HEVC mit Alpha)?
    static func needsAlpha(style: FrameStyle, showFrame: Bool) -> Bool {
        !SceneRenderer.isPassthrough(style: style, showFrame: showFrame) && style.background == .transparent
    }

    /// previewScale < 1 rendert kleiner (flüssige Vorschau)
    static func composition(for source: Source, style: FrameStyle, profile: DeviceProfile, showFrame: Bool,
                            previewScale: CGFloat = 1) async throws -> AVVideoComposition? {
        if SceneRenderer.isPassthrough(style: style, showFrame: showFrame), previewScale == 1 { return nil }
        let natural = SceneRenderer.naturalCanvas(style: style, profile: profile, showFrame: showFrame,
                                                  screenSize: source.size)
        let limit = min(1, 3840 / max(natural.width, natural.height),
                        (3840 * 2160 / (natural.width * natural.height)).squareRoot()) * previewScale
        let canvas = CGSize(width: SceneRenderer.even(natural.width * limit - 1),
                            height: SceneRenderer.even(natural.height * limit - 1))
        let renderer = SceneRenderer(style: style, profile: profile, showFrame: showFrame, fixedCanvas: canvas)
        let orientation = ciTransform(for: source.transform)

        let composition = try await AVMutableVideoComposition.videoComposition(with: source.asset) { request in
            var image = request.sourceImage
            if let orientation {
                image = image.transformed(by: orientation)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
            request.finish(with: renderer.image(screen: image), context: nil)
        }
        composition.renderSize = canvas
        return composition
    }

    /// preferredTransform gilt für y nach unten; Core Image rechnet mit y nach oben
    private static func ciTransform(for transform: CGAffineTransform) -> CGAffineTransform? {
        guard !transform.isIdentity else { return nil }
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        return flip.concatenating(CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                                                    tx: 0, ty: 0)).concatenating(flip)
    }

    static func export(_ source: Source, composition: AVVideoComposition?, needsAlpha: Bool, range: CMTimeRange,
                       to url: URL, progress: @escaping (Double) -> Void) async throws {
        let preset = needsAlpha ? AVAssetExportPresetHEVCHighestQualityWithAlpha : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: source.asset, presetName: preset) else {
            throw FramerError.exportFailed("Exportprofil nicht verfügbar")
        }
        try? FileManager.default.removeItem(at: url)
        session.videoComposition = composition
        session.timeRange = range

        let monitor = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case let .exporting(exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: url, as: .mov)
        } catch {
            throw FramerError.exportFailed(error.localizedDescription)
        }
        progress(1)
    }
}
