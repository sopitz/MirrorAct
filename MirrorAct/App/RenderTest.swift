// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import SwiftUI

/// `MirrorAct --render-test <ordner>`: rendert Gehäuse für einige Geräte als PNG (zur Kontrolle ohne Gerät)
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
        // Gestaltung: Hintergründe, Farben, Formate
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
        // Duo in allen Posen
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

    /// Aufnahme-Test: 2 s synthetische Bilder (mit Drehung) ohne und mit Rahmen, danach Kontrolle mit AVAsset
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
                // Ton wie bei AirPlay: AAC-ELD-Pakete alle ~11 ms
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
                // wie in echt: ein Bild alle ~16 ms
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
            // vorhandenes Video rahmen (wie im Editor)
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

    /// 440-Hz-Ton als AAC-ELD (44.1 kHz, stereo, 480 Frames), wie ihn das iPhone schickt
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

    @MainActor
    private static func renderView<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.cgImage {
            FrameRenderer.writePNG(image, to: url)
        }
    }

    /// Verlauf mit Statusleiste, damit Notch und Ecken beurteilbar sind
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
