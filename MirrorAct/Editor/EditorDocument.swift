// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Ein offener Editor: ein oder zwei Bilder (Duo) oder ein Video
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    enum Content {
        case images([URL], [CGImage])
        case video(URL)
    }

    let id = UUID()
    let content: Content
    let title: String

    @Published var style: FrameStyle { didSet { scheduleRefresh() } }
    @Published var showFrame: Bool { didSet { scheduleRefresh() } }
    @Published var modelSelection = "auto" { didSet { scheduleRefresh() } }
    @Published var pose: DuoPose = .sideBySide { didSet { scheduleRefresh() } }
    @Published private(set) var preview: CGImage?
    @Published private(set) var exportProgress: Double?
    @Published var message: String?
    @Published private(set) var videoSource: VideoFramer.Source?
    let player = AVPlayer()

    private var previewScreens: [CGImage] = []
    private var refreshTask: Task<Void, Never>?

    init?(urls: [URL]) {
        let settings = AppSettings.shared
        style = settings.style
        showFrame = settings.showFrame
        guard let first = urls.first else { return nil }
        if UTType(filenameExtension: first.pathExtension)?.conforms(to: .movie) == true {
            content = .video(first)
            title = first.deletingPathExtension().lastPathComponent
            Task { await loadVideo(first) }
        } else {
            let pairs = urls.prefix(2).compactMap { url in FrameRenderer.loadImage(at: url).map { (url, $0) } }
            guard !pairs.isEmpty else { return nil }
            content = .images(pairs.map(\.0), pairs.map(\.1))
            title = pairs.count == 2 ? "Duo" : first.deletingPathExtension().lastPathComponent
            previewScreens = pairs.map { Self.downscaled($0.1, maxSide: 760) }
            refresh()
        }
    }

    var isVideo: Bool { if case .video = content { return true } else { return false } }
    var isDuo: Bool { if case let .images(_, images) = content { return images.count == 2 } else { return false } }

    func profile(for size: CGSize) -> DeviceProfile {
        if modelSelection != "auto", let selected = DeviceProfile.profile(forSelection: modelSelection) {
            return selected
        }
        return DeviceProfile.resolve(modelIdentifier: nil, screenPixels: size, frameSize: size)
    }

    // MARK: Vorschau

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        switch content {
        case .images:
            preview = render(previewScreens)
        case .video:
            guard let source = videoSource, let item = player.currentItem else { return }
            let style = style, showFrame = showFrame, profile = profile(for: source.size)
            Task {
                item.videoComposition = try? await VideoFramer.composition(for: source, style: style, profile: profile,
                                                                           showFrame: showFrame, previewScale: 0.5)
            }
        }
    }

    /// Profil nach der Originalgrösse (die Vorschau rendert verkleinerte Bilder)
    private var originalSizes: [CGSize] {
        guard case let .images(_, images) = content else { return [] }
        return images.map { CGSize(width: $0.width, height: $0.height) }
    }

    private func render(_ screens: [CGImage]) -> CGImage? {
        let profiles = zip(screens, originalSizes).map { profile(for: $1) }
        if screens.count == 2 {
            return DuoRenderer.render(screens: screens, profiles: profiles, style: style, showFrame: showFrame, pose: pose)
        }
        guard let screen = screens.first, let profile = profiles.first else { return nil }
        return FrameRenderer.render(screen: screen, profile: profile, showFrame: showFrame, style: style)
    }

    private func loadVideo(_ url: URL) async {
        do {
            let source = try await VideoFramer.load(url)
            videoSource = source
            player.replaceCurrentItem(with: AVPlayerItem(asset: source.asset))
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Bilder exportieren

    /// volle Auflösung
    func renderFull() -> CGImage? {
        guard case let .images(_, images) = content else { return nil }
        return render(images)
    }

    private var suggestedName: String {
        switch content {
        case let .images(urls, _):
            let base = urls[0].deletingPathExtension().lastPathComponent
            return urls.count == 2 ? String(localized: "\(base) (Duo).png") : String(localized: "\(base) (Framed).png")
        case let .video(url):
            return String(localized: "\(url.deletingPathExtension().lastPathComponent) (Framed).mov")
        }
    }

    private var sourceDirectory: URL? {
        switch content {
        case let .images(urls, _): return urls.first?.deletingLastPathComponent()
        case let .video(url): return url.deletingLastPathComponent()
        }
    }

    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = sourceDirectory
        panel.allowedContentTypes = isVideo ? [.quickTimeMovie] : [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isVideo {
            Task { await exportVideo(to: url) }
        } else if let image = renderFull(), FrameRenderer.writePNG(image, to: url) {
            message = String(localized: "Saved: \(url.lastPathComponent)")
        } else {
            message = String(localized: "Saving failed")
        }
    }

    func copy() {
        guard let image = renderFull() else { return }
        FrameRenderer.copyToPasteboard(image)
        message = String(localized: "Copied to the clipboard")
    }

    /// Datei für Teilen bzw. Herausziehen (temporär)
    func temporaryExport() async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorAct", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedName)
        if isVideo {
            await exportVideo(to: url)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let image = renderFull(), FrameRenderer.writePNG(image, to: url) else { return nil }
        return url
    }

    // MARK: Video exportieren

    func exportVideo(to url: URL) async {
        guard let source = videoSource else { return }
        let item = player.currentItem
        let start = item.map { $0.reversePlaybackEndTime.isValid ? $0.reversePlaybackEndTime : .zero } ?? .zero
        let end = item.map { $0.forwardPlaybackEndTime.isValid ? $0.forwardPlaybackEndTime : source.duration } ?? source.duration
        let profile = profile(for: source.size)
        exportProgress = 0
        message = nil
        do {
            let composition = try await VideoFramer.composition(for: source, style: style, profile: profile,
                                                                showFrame: showFrame)
            try await VideoFramer.export(source, composition: composition,
                                         needsAlpha: VideoFramer.needsAlpha(style: style, showFrame: showFrame),
                                         range: CMTimeRange(start: start, end: end), to: url) { value in
                Task { @MainActor [weak self] in self?.exportProgress = value }
            }
            message = String(localized: "Saved: \(url.lastPathComponent)")
        } catch {
            message = error.localizedDescription
        }
        exportProgress = nil
    }

    func adoptAsDefault() {
        AppSettings.shared.style = style
        AppSettings.shared.showFrame = showFrame
        message = String(localized: "Used as default")
    }

    static func downscaled(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
