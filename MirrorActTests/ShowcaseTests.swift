// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import XCTest
@testable import MirrorAct

// Showcase exists in debug builds only (the Release build of the tests runs the tracking bench)
#if DEBUG
/// The README pictures are drawn at the scale asked for, whatever the displays attached are:
/// each scale is tried, and on any Mac at least one of them differs from the displays'.
@MainActor
final class ShowcaseTests: XCTestCase {
    private var folder: URL!
    private var screenshotExisted = false
    /// the editor's picture goes there (Showcase.editor)
    private let screenshotFile = FileManager.default.temporaryDirectory.appendingPathComponent("iPhone Screenshot.png")

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShowcaseTests-\(UUID().uuidString)")
        screenshotExisted = FileManager.default.fileExists(atPath: screenshotFile.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        if !screenshotExisted { try? FileManager.default.removeItem(at: screenshotFile) }
    }

    /// Hairlines drawn by SwiftUI and by an AppKit view: at 2x a 1 pt line is two full rows of
    /// pixels and a 0.5 pt line one, with dark rows on both sides; a 1x picture enlarged would
    /// blur the 0.5 pt line over two rows. At 1x the 1 pt line is one full row.
    func testHairlinesAreSharpAtEachScale() throws {
        for scale in [1.0, 2.0] {
            AppKitLines.Lines.lastDeviceScale = 0
            let host = NSHostingView(rootView: HairlineProbe())
            let image = try XCTUnwrap(Showcase.capture(host, size: HairlineProbe.size, scale: scale))
            XCTAssertEqual(image.width, Int(HairlineProbe.size.width * scale), "\(scale)x")
            XCTAssertEqual(image.height, Int(HairlineProbe.size.height * scale), "\(scale)x")
            let pixels = Gray(image)
            for (name, x) in [("SwiftUI", 20.0), ("AppKit", 60.0)] {
                let column = pixels.column(Int(x * scale))
                let context = "\(name) at \(scale)x, column \(Array(column.prefix(Int(24 * scale))))"
                func row(_ y: CGFloat) -> UInt8 { column[Int(y * scale)] }
                if scale == 2 {
                    for y in [10, 10.5, 20] as [CGFloat] { XCTAssertGreaterThan(row(y), 245, context) }
                    for y in [9.5, 11, 19.5, 20.5] as [CGFloat] { XCTAssertLessThan(row(y), 10, context) }
                } else {
                    XCTAssertGreaterThan(row(10), 245, context)
                    for y in [9, 11, 19, 21] as [CGFloat] { XCTAssertLessThan(row(y), 10, context) }
                    XCTAssertEqual(Double(row(20)), 127.5, accuracy: 30, context)
                }
            }
            // laid out for the scale: a 1 pt bar below 10.5 pt of frames lands on whole pixels
            // at 1x (one full row), at 2x it stays at 10.5 pt; laid out for 2x and drawn at 1x
            // it would be two half-bright rows
            let layout = pixels.column(Int(90 * scale))
            let bar = Array(layout[Int(6 * scale)..<Int(16 * scale)])
            XCTAssertEqual(bar.filter { $0 > 245 }.count, Int(scale), "layout at \(scale)x: \(bar)")
            XCTAssertEqual(bar.filter { $0 >= 10 && $0 <= 245 }.count, 0, "layout at \(scale)x: \(bar)")
            if scale == 2 { XCTAssertGreaterThan(layout[21], 245, "layout at 2x: \(bar)") }
            // AppKit views draw into the picture itself, at its scale
            XCTAssertEqual(AppKitLines.Lines.lastDeviceScale, scale, "\(scale)x")
            // every layer SwiftUI drew a bitmap into has the scale asked for (those of AppKit
            // views keep the screen's, cacheDisplay does not use them)
            var wrong: [String] = []
            func visit(_ layer: CALayer) {
                if layer.contents != nil, layer.contentsScale != scale, !(layer.delegate is NSView) {
                    wrong.append("\(type(of: layer)) of \(layer.delegate.map { "\(type(of: $0))" } ?? "-"): \(layer.contentsScale)")
                }
                layer.sublayers?.forEach(visit)
            }
            visit(try XCTUnwrap(host.layer))
            XCTAssertEqual(wrong, [], "\(scale)x")
        }
    }

    /// The tool rail and the style panel have the same size in points at each scale, so at 2x
    /// they have twice the pixels of 1x (they once followed the display, the device did not)
    func testRailAndPanelFollowTheScale() throws {
        let session = MirrorSession(id: "showcase-test", kind: .android, deviceName: "Phone",
                                    modelIdentifier: "Pixel", muted: true)
        session.state = .live
        let chrome = MirrorChrome()
        chrome.hovering = true
        let actions = MirrorActions(close: {}, present: {}, zoomIn: {}, zoomOut: {}, actualSize: {}, lifeSize: {},
                                    pixelPerfect: {}, fitToScreen: {}, saveScreenshot: {}, copyScreenshot: {},
                                    screenshotFile: { nil }, toggleRecording: {}, disconnect: {})
        let shots: [(String, (CGFloat) -> CGImage?)] = [
            ("rail", { Showcase.snapshot(MirrorToolRail(session: session, chrome: chrome, actions: actions), scale: $0) }),
            ("panel", { Showcase.snapshot(StylePanel(session: session, actions: actions), scale: $0) }),
        ]
        for (name, shot) in shots {
            let single = try XCTUnwrap(shot(1), name), double = try XCTUnwrap(shot(2), name)
            XCTAssertGreaterThan(single.width, 20, name)
            XCTAssertEqual(Double(double.width), Double(single.width * 2), accuracy: 2, name)
            XCTAssertEqual(Double(double.height), Double(single.height * 2), accuracy: 2, name)
        }
    }

    /// The picture of the mirror window shows Translate the way the mirrored session has it: lit
    /// while that one translates (a picture of a translated screen once showed the button as off,
    /// because the picture is drawn from a session of its own). The start window, which shows no
    /// session, comes out the same both times.
    func testTheRailShowsTranslateAsTheMirroredSessionHasIt() throws {
        let session = MirrorSession(id: "showcase-test", kind: .android, deviceName: "Phone",
                                    modelIdentifier: "Pixel", muted: true)
        func pixels(_ name: String, translating: Bool) throws -> Data {
            session.showTranslating(translating)
            let dir = folder.appendingPathComponent(translating ? "on" : "off")
            Showcase.export(to: dir, session: session, scale: 1)
            let file = dir.appendingPathComponent("\(name).png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil), name)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
            return try XCTUnwrap(image.dataProvider?.data as Data?, name)
        }
        let mirrorOff = try pixels("mirror", translating: false), startOff = try pixels("start-window", translating: false)
        let mirrorOn = try pixels("mirror", translating: true), startOn = try pixels("start-window", translating: true)
        XCTAssertEqual(startOn, startOff, "the same picture is drawn the same twice")
        XCTAssertNotEqual(mirrorOn, mirrorOff, "the Translate button is lit")
    }

    /// The pictures have the size of their canvas at the scale asked for
    func testExportedPicturesHaveTheScaleAskedFor() throws {
        let session = MirrorSession(id: "showcase-test", kind: .cable, deviceName: "iPhone",
                                    modelIdentifier: "iPhone14,2", muted: true)
        for scale in [1.0, 2.0] {
            let dir = folder.appendingPathComponent("\(Int(scale))x")
            Showcase.export(to: dir, session: session, scale: scale)
            for (name, points) in [("mirror", CGSize(width: 1400, height: 900)),
                                   ("start-window", CGSize(width: 960, height: 700)),
                                   ("editor", CGSize(width: 1320, height: 900))] {
                let file = dir.appendingPathComponent("\(name).png")
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil), "\(name) at \(scale)x")
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(name) at \(scale)x")
                XCTAssertEqual(image.width, Int(points.width * scale), "\(name) at \(scale)x")
                XCTAssertEqual(image.height, Int(points.height * scale), "\(name) at \(scale)x")
            }
        }
    }
}

/// A 1 pt line at y = 10 and a 0.5 pt line at y = 20 (from the top), white on black: on the
/// left drawn by SwiftUI, in the middle by an AppKit view; on the right a 1 pt bar placed by
/// layout 10.5 pt from the top; below them a color well and text, so that AppKit controls and
/// text are among the layers
private struct HairlineProbe: View {
    static let size = CGSize(width: 100, height: 72)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    context.fill(Path(CGRect(x: 0, y: 10, width: size.width, height: 1)), with: .color(.white))
                    context.fill(Path(CGRect(x: 0, y: 20, width: size.width, height: 0.5)), with: .color(.white))
                }
                .frame(width: 40, height: 32)
                AppKitLines().frame(width: 40, height: 32)
                VStack(spacing: 0) {
                    Color.black.frame(height: 10.5)
                    Color.white.frame(height: 1)
                    Color.black
                }
                .frame(width: 20, height: 32)
            }
            ColorPicker("Color", selection: .constant(.red), supportsOpacity: false)
            Text("Hairline")
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}

private struct AppKitLines: NSViewRepresentable {
    final class Lines: NSView {
        /// the scale of the device space of the latest drawing
        static var lastDeviceScale: CGFloat = 0

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            if let context = NSGraphicsContext.current?.cgContext {
                Self.lastDeviceScale = abs(context.userSpaceToDeviceSpaceTransform.d)
            }
            NSColor.black.setFill()
            bounds.fill()
            NSColor.white.setFill()
            NSRect(x: 0, y: 10, width: bounds.width, height: 1).fill()
            NSRect(x: 0, y: 20, width: bounds.width, height: 0.5).fill()
        }
    }

    func makeNSView(context: Context) -> Lines { Lines() }
    func updateNSView(_ view: Lines, context: Context) {}
}

/// Gray values of a picture, row 0 at the top
private struct Gray {
    let width: Int, height: Int
    let values: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var values = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &values, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.values = values
    }

    func column(_ x: Int) -> [UInt8] { (0..<height).map { values[$0 * width + x] } }
}
#endif
