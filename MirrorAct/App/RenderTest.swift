// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import SwiftUI

/// `MirrorAct --render-test <folder>`: renders the chassis of a few devices as PNG (for checking without a device)
enum RenderTest {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, DeviceProfile, CGSize)] = [
            ("iphone13pro", DeviceProfile.forModelIdentifier("iPhone14,2")!, CGSize(width: 1170, height: 2532)),
            ("iphone13pro-quer", DeviceProfile.forModelIdentifier("iPhone14,2")!, CGSize(width: 2532, height: 1170)),
            ("iphone15pro", DeviceProfile.forModelIdentifier("iPhone16,1")!, CGSize(width: 1179, height: 2556)),
            ("iphone12", DeviceProfile.forModelIdentifier("iPhone13,2")!, CGSize(width: 1170, height: 2532)),
            ("iphonese", DeviceProfile.forModelIdentifier("iPhone14,6")!, CGSize(width: 750, height: 1334)),
            ("ipad", DeviceProfile.forScreenPixels(CGSize(width: 1640, height: 2360))!, CGSize(width: 1640, height: 2360)),
            // iPhone Duo: the screen size picks the closed (outer) or open (inner) screen
            ("iphoneduo-zu", DeviceProfile.forModelIdentifier("iPhone19,4", screenSize: CGSize(width: 1398, height: 2034))!,
             CGSize(width: 1398, height: 2034)),
            ("iphoneduo-zu-quer", DeviceProfile.forModelIdentifier("iPhone19,4", screenSize: CGSize(width: 2034, height: 1398))!,
             CGSize(width: 2034, height: 1398)),
            ("iphoneduo-auf", DeviceProfile.forModelIdentifier("iPhone19,4", screenSize: CGSize(width: 2670, height: 1878))!,
             CGSize(width: 2670, height: 1878)),
            ("android", DeviceProfile.android(name: "Android", screenPixels: CGSize(width: 1080, height: 2340), densityDpi: 420,
                                              cutoutRect: CGRect(x: 498, y: 0, width: 84, height: 100), cornerRadius: 105),
             CGSize(width: 1080, height: 2340)),
            ("android-quer", DeviceProfile.android(name: "Android"), CGSize(width: 2340, height: 1080)),
        ]
        for (name, profile, size) in cases {
            guard let screen = testScreen(size: size),
                  let image = FrameRenderer.render(screen: screen, profile: profile, showFrame: true) else { continue }
            FrameRenderer.writePNG(image, to: directory.appendingPathComponent("\(name).png"))
        }
        // Style: backgrounds, colors, aspect ratios
        let screen = testScreen(size: CGSize(width: 1170, height: 2532))!
        let screenQuer = testScreen(size: CGSize(width: 2532, height: 1170))!
        let p13 = DeviceProfile.forModelIdentifier("iPhone14,2")!
        let styles: [(String, FrameStyle, Bool, CGImage)] = [
            ("stil-verlauf-16x9-silber", FrameStyle(bezelColor: .silver, background: .gradient, gradient: .ocean,
                                                    padding: 0.12, shadow: true, aspect: .landscape16x9), true, screen),
            ("stil-farbe-gold", FrameStyle(bezelColor: .gold, background: .color, color: RGBA(red: 0.95, green: 0.93, blue: 0.90),
                                           padding: 0.15, shadow: true), true, screen),
            ("stil-ohne-rahmen-abgerundet", FrameStyle(background: .gradient, gradient: .evening, padding: 0.1,
                                                       shadow: true, aspect: .square, roundedScreen: true), false, screen),
            ("stil-quer-1x1-blau", FrameStyle(bezelColor: .blue, background: .gradient, gradient: .lilac, padding: 0.1,
                                              shadow: true, aspect: .square), true, screenQuer),
        ]
        for (name, style, frame, image) in styles {
            if let out = FrameRenderer.render(screen: image, profile: p13, showFrame: frame, style: style) {
                FrameRenderer.writePNG(out, to: directory.appendingPathComponent("\(name).png"))
            }
        }
        // Duo in all poses
        let p15 = DeviceProfile.forModelIdentifier("iPhone16,1")!
        let screen2 = testScreen(size: CGSize(width: 1179, height: 2556), hue: 0.45)!
        for pose in DuoPose.allCases {
            let style = FrameStyle(bezelColor: .naturalTitanium, background: .gradient, gradient: .evening,
                                   padding: 0.15, shadow: true, aspect: .landscape16x9)
            if let out = DuoRenderer.render(screens: [screen, screen2], profiles: [p13, p15], style: style,
                                            showFrame: true, pose: pose) {
                FrameRenderer.writePNG(out, to: directory.appendingPathComponent("duo-\(pose.rawValue).png"))
            }
        }
        renderTranslations(into: directory)
        MainActor.assumeIsolated {
            renderView(LauncherView(), to: directory.appendingPathComponent("launcher.png"))
            let cards = HStack(alignment: .top, spacing: 16) {
                DeviceCard(model: .init(id: "a", name: "Test-iPhone", modelIdentifier: "iPhone14,2", status: "Ready via cable",
                                        state: .ready, transport: .cable, cableDevice: nil)) {}
                DeviceCard(model: .init(id: "b", name: "Test iPhone 15", modelIdentifier: "iPhone16,1", status: "Wireless",
                                        state: .offline, transport: .wireless, cableDevice: nil)) {}
                WirelessCard(receiverName: "MirrorAct", pin: "5321", usesPin: true, state: .ready) {}
                AddDeviceCard {}
            }
            .frame(width: 704)
            .padding(28)
            .background(Color(white: 0.12))
            renderView(cards, to: directory.appendingPathComponent("launcher-karten.png"))
            renderView(ConnectGuide().background(Color(white: 0.14)), to: directory.appendingPathComponent("anleitung.png"))
            let session = MirrorSession(id: "test", kind: .wireless, deviceName: "Test-iPhone",
                                        modelIdentifier: "iPhone14,2", muted: false)
            session.state = .live
            let actions = MirrorActions(close: {}, present: {}, zoomIn: {}, zoomOut: {}, actualSize: {}, lifeSize: {},
                                        pixelPerfect: {}, fitToScreen: {}, saveScreenshot: {}, copyScreenshot: {},
                                        screenshotFile: { nil }, toggleRecording: {}, disconnect: {})
            let chrome = MirrorChrome()
            chrome.hovering = true
            renderView(MirrorToolRail(session: session, chrome: chrome, actions: actions).padding(8).background(Color.black),
                       to: directory.appendingPathComponent("werkzeuge.png"))
            renderView(StylePanel(session: session, actions: actions).background(Color(white: 0.16)),
                       to: directory.appendingPathComponent("stil-panel.png"))
        }
        print("Render-Test: \(directory.path)")
    }

    /// Recording test: 2 s of synthetic images (with rotation) without and with a frame, then a check with AVAsset
    static func recordTest(into directory: URL, done: @escaping () -> Void) {
        let portrait = testScreen(size: CGSize(width: 1170, height: 2532))!
        let landscape = testScreen(size: CGSize(width: 2532, height: 1170))!
        let profile = DeviceProfile.forModelIdentifier("iPhone14,2")!
        let group = DispatchGroup()
        let audioPackets = eldTestPackets()
        let player = AACAudioPlayer(format: .airPlay)
        player.muted = true
        for withFrame in [false, true] {
            let url = directory.appendingPathComponent(withFrame ? "aufnahme-rahmen.mov" : "aufnahme.mov")
            let style = withFrame
                ? FrameStyle(bezelColor: .naturalTitanium, background: .gradient, gradient: .forest, padding: 0.1,
                             shadow: true, aspect: .landscape16x9)
                : FrameStyle()
            guard let recorder = try? MirrorRecorder(url: url, frameSize: CGSize(width: 1170, height: 2532),
                                                     profile: profile, withFrame: withFrame, style: style,
                                                     audioSampleRate: withFrame ? nil : player.sampleRate)
            else { print("recorder error"); continue }
            if !withFrame {
                // Audio as with AirPlay: AAC-ELD packets every ~11 ms
                player.recordTap = { recorder.appendAudio($0) }
                DispatchQueue.global().async {
                    usleep(50_000)
                    for i in 0..<180 {
                        player.handle(audioPackets[i % audioPackets.count], compressionType: 8)
                        usleep(10_884)
                    }
                }
            }
            let portraitBuffer = pixelBuffer(from: portrait)!, landscapeBuffer = pixelBuffer(from: landscape)!
            group.enter()
            DispatchQueue.global().async {
                // as in real use: one image every ~16 ms
                for i in 0..<120 {
                    recorder.appendVideo(i < 90 ? portraitBuffer : landscapeBuffer, at: MirrorRecorder.now)
                    usleep(16_000)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                recorder.finish { result in
                    switch result {
                    case let .success(url):
                        let asset = AVURLAsset(url: url)
                        Task {
                            let duration = (try? await asset.load(.duration))?.seconds ?? 0
                            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                            var size = CGSize.zero
                            if let track = tracks.first, let natural = try? await track.load(.naturalSize) {
                                size = natural
                            }
                            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                            var audioInfo = "no audio"
                            if let track = audioTracks.first, let range = try? await track.load(.timeRange) {
                                audioInfo = String(format: "audio %.2f s from %.2f s", range.duration.seconds, range.start.seconds)
                            }
                            print("\(url.lastPathComponent): \(String(format: "%.2f", duration)) s, \(Int(size.width))x\(Int(size.height)), \(audioInfo)")
                            let generator = AVAssetImageGenerator(asset: asset)
                            for (label, seconds) in [("anfang", 0.2), ("quer", 1.8)] {
                                if let (image, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                                    FrameRenderer.writePNG(image, to: url.deletingPathExtension()
                                        .appendingPathExtension("\(label).png"))
                                }
                            }
                            group.leave()
                        }
                    case let .failure(error):
                        print("recording failed: \(error)")
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            // frame an existing video (as in the editor)
            Task {
                let input = directory.appendingPathComponent("aufnahme.mov")
                let output = directory.appendingPathComponent("editor-video.mov")
                do {
                    let source = try await VideoFramer.load(input)
                    let style = FrameStyle(bezelColor: .gold, background: .color, color: RGBA(red: 0.1, green: 0.1, blue: 0.12),
                                           padding: 0.1, shadow: true, aspect: .square)
                    let composition = try await VideoFramer.composition(for: source, style: style, profile: profile,
                                                                        showFrame: true)
                    try await VideoFramer.export(source, composition: composition, needsAlpha: false,
                                                 range: CMTimeRange(start: .zero, duration: source.duration), to: output) { _ in }
                    let asset = AVURLAsset(url: output)
                    let track = try await asset.loadTracks(withMediaType: .video).first
                    let size = try await track?.load(.naturalSize) ?? .zero
                    print("editor-video.mov: \(Int(size.width))x\(Int(size.height))")
                    if let (image, _) = try? await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                        FrameRenderer.writePNG(image, to: directory.appendingPathComponent("editor-video.png"))
                    }
                } catch {
                    print("editor video failed: \(error.localizedDescription)")
                }
                done()
            }
        }
    }

    /// 440 Hz tone as AAC-ELD (44.1 kHz, stereo, 480 frames), as the iPhone sends it
    private static func eldTestPackets() -> [Data] {
        var description = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let eld = AVAudioFormat(streamDescription: &description)!
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let encoder = AVAudioConverter(from: pcm, to: eld)!
        let source = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 48000)!
        source.frameLength = 48000
        for i in 0..<48000 {
            let v = Float(sin(Double(i) * 2 * .pi * 440 / 44100)) * 0.3
            source.floatChannelData![0][i] = v
            source.floatChannelData![1][i] = v
        }
        var packets: [Data] = []
        var supplied = false
        while packets.count < 90 {
            let out = AVAudioCompressedBuffer(format: eld, packetCapacity: 1, maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            _ = encoder.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return source
            }
            if out.packetCount == 0 { break }
            packets.append(Data(bytes: out.data, count: Int(out.byteLength)))
        }
        return packets
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// Translations as the mirror window, screenshots and recordings show them: the test screen
    /// with a few text blocks on it, once as BGRA and once as 4:2:0 video, which is what the
    /// devices send. The boxes and texts should look the same in both pictures.
    private static func renderTranslations(into directory: URL) {
        guard let screen = testScreen(size: CGSize(width: 1170, height: 2532)), let bgra = pixelBuffer(from: screen),
              let video = videoBuffer(from: bgra) else { return }
        for (name, frame) in [("translation-bgra", bgra), ("translation-420", video)] {
            guard let translated = TranslationCompositor().compose(frame, blocks: translationBlocks(on: frame)),
                  let image = FrameRenderer.cgImage(from: translated) else {
                print("\(name): not rendered")
                continue
            }
            FrameRenderer.writePNG(image, to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// Blocks as the tracker places them (pixels of the frame, counted from the top left)
    private static func translationBlocks(on frame: CVPixelBuffer) -> [PlacedBlock] {
        // colors: nil = those of the frame at this place, as when a block was read from it
        func block(_ id: Int, _ text: String, _ rect: CGRect, lines: Int = 1, visible: CGRect? = nil,
                   colors: BlockColors? = nil) -> PlacedBlock {
            PlacedBlock(id: id, text: text, rect: rect, visibleRect: visible, lineCount: lines,
                        colors: colors ?? FramePixels.blockColors(in: rect, of: frame))
        }
        // on a white tile, in a color of its own: the background of the tile, the blue of a link
        var link = block(4, "Mehr erfahren", CGRect(x: 141, y: 960, width: 210, height: 44))
        link.colors.foreground = RGBColor(red: 0, green: 102, blue: 204)
        let ink = RGBColor(red: 28, green: 28, blue: 30)
        return [
            block(1, "Übersetzter Titel", CGRect(x: 117, y: 300, width: 620, height: 84)),
            block(2, "Ein längerer Absatz, der in der Übersetzung mehr Platz braucht als das Original und deshalb kleiner gesetzt wird.",
                  CGRect(x: 117, y: 440, width: 936, height: 132), lines: 2,
                  colors: BlockColors(background: RGBColor(red: 246, green: 246, blue: 248), foreground: ink)),
            block(3, "Farben aus dem Bild: der Kasten hebt sich kaum vom Verlauf ab.",
                  CGRect(x: 117, y: 630, width: 700.5, height: 150.5), lines: 3),
            link,
            block(5, "Löschen", CGRect(x: 469, y: 950, width: 208, height: 64),
                  colors: BlockColors(background: RGBColor(red: 215, green: 0, blue: 21), foreground: .white)),
            // far too long for its place: set smaller
            block(6, "Benachrichtigungseinstellungen", CGRect(x: 790, y: 960, width: 222, height: 40)),
            block(7, "Zwei Zeilen im Kästchen", CGRect(x: 135, y: 1290, width: 222, height: 96), lines: 2),
            // a comma stays with its word; fullwidth digits break like the kana around them
            block(12, "Mitteilungen, Töne und Haptik", CGRect(x: 480, y: 1290, width: 150, height: 96), lines: 2),
            block(13, "パスワードは数字１２３４５６を含めてください", CGRect(x: 790, y: 1290, width: 222, height: 96), lines: 2),
            // too long even in the smallest font: the last line that fits ends with an ellipsis
            block(14, String(repeating: "Diese Übersetzung ist viel länger als der Platz, den das Original auf dem Bildschirm hatte. ",
                             count: 6),
                  CGRect(x: 117, y: 1520, width: 936, height: 48)),
            // the upper third is hidden, as under a title bar: nothing may be drawn there
            block(8, "Dieser Absatz ist oben abgeschnitten, als läge eine Titelleiste darüber: nur der sichtbare Teil wird gezeichnet.",
                  CGRect(x: 117, y: 1620, width: 936, height: 180), lines: 3,
                  visible: CGRect(x: 117, y: 1680, width: 936, height: 120), colors: .blackOnWhite),
            // the title on that bar: within the paragraph's rectangle, but where it is hidden
            block(15, "Titelleiste", CGRect(x: 117, y: 1624, width: 260, height: 44)),
            // written from the right: aligned at the right
            block(9, "مرحبا بالعالم، هذه ترجمة", CGRect(x: 117, y: 1900, width: 936, height: 72),
                  colors: BlockColors(background: RGBColor(red: 44, green: 44, blue: 46), foreground: .white)),
            block(10, "设置与隐私：翻译后的文字", CGRect(x: 117, y: 2040, width: 936, height: 72),
                  colors: BlockColors(background: ink, foreground: RGBColor(red: 255, green: 214, blue: 10))),
            // hangs over the right edge of the frame
            block(11, "Über den Rand hinaus", CGRect(x: 900, y: 2200, width: 420, height: 64),
                  colors: BlockColors(background: RGBColor(red: 36, green: 138, blue: 61), foreground: .white)),
        ]
    }

    /// The same picture as bi-planar 4:2:0 video (BT.709, video range), which is what the decoders deliver
    private static func videoBuffer(from bgra: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(bgra), height = CVPixelBufferGetHeight(bgra)
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        }
        guard let source = CVPixelBufferGetBaseAddress(bgra), let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(bgra)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            let pixels = (source + y * sourceRowBytes).assumingMemoryBound(to: UInt8.self)
            let row = (luma + y * lumaRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let color = RGBColor(red: pixels[x * 4 + 2], green: pixels[x * 4 + 1], blue: pixels[x * 4])
                row[x] = YCbCrColor(color, fullRange: false).y
            }
        }
        // one color for every 2 × 2 pixels: that of their mean
        for y in 0..<(height + 1) / 2 {
            let upper = (source + 2 * y * sourceRowBytes).assumingMemoryBound(to: UInt8.self)
            let lower = (source + min(2 * y + 1, height - 1) * sourceRowBytes).assumingMemoryBound(to: UInt8.self)
            let row = (chroma + y * chromaRowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<(width + 1) / 2 {
                let left = 2 * x * 4, right = min(2 * x + 1, width - 1) * 4
                func mean(_ channel: Int) -> UInt8 {
                    let above = Int(upper[left + channel]) + Int(upper[right + channel])
                    let below = Int(lower[left + channel]) + Int(lower[right + channel])
                    return UInt8((above + below + 2) / 4)
                }
                let color = YCbCrColor(RGBColor(red: mean(2), green: mean(1), blue: mean(0)), fullRange: false)
                row[2 * x] = color.cb
                row[2 * x + 1] = color.cr
            }
        }
        // What kind of video this is. The compositor passes it on to its copy, and the way
        // back into an image goes by it.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    @MainActor
    private static func renderView<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.cgImage {
            FrameRenderer.writePNG(image, to: url)
        }
    }

    /// Gradient with a status bar, so Notch and corners can be judged
    static func testScreen(size: CGSize, hue: CGFloat = 0) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = hue == 0
            ? [CGColor(srgbRed: 0.18, green: 0.45, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.65, green: 0.25, blue: 0.80, alpha: 1)]
            : [CGColor(srgbRed: 0.10, green: 0.70, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.95, green: 0.75, blue: 0.20, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        let bar = CGFloat(min(w, h)) * 0.12
        ctx.fill(CGRect(x: 0, y: CGFloat(h) - bar, width: CGFloat(w), height: 4))
        for i in 0..<6 {
            let r = CGRect(x: CGFloat(w) * 0.1 + CGFloat(i % 3) * CGFloat(w) * 0.28,
                           y: CGFloat(h) * 0.55 - CGFloat(i / 3) * CGFloat(w) * 0.3,
                           width: CGFloat(w) * 0.22, height: CGFloat(w) * 0.22)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.width * 0.22, cornerHeight: r.width * 0.22, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }
}
