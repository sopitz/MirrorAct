// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import MirrorAct

/// The screen sits at a fractional position inside the frame. Its outermost pixel row must stay
/// opaque, otherwise the background shows through as a hairline around the screen (in the duo
/// image as a line in the background color).
final class SceneRendererTests: XCTestCase {
    private let style = FrameStyle(bezelColor: .naturalTitanium, background: .color,
                                   color: RGBA(red: 1, green: 0.5, blue: 0), padding: 0.1, shadow: false)

    /// screenshots, the editor and the duo image: canvas in the screen's own size
    func testFramedScreenshotHasNoSeeThroughPixels() throws {
        let profile = try XCTUnwrap(DeviceProfile.forModelIdentifier("iPhone14,2"))
        let image = try XCTUnwrap(SceneRenderer(style: style, profile: profile, showFrame: true)
            .cgImage(screen: Self.black(width: 1170, height: 2532)))
        XCTAssertEqual(Self.seeThroughPixels(in: image), 0)
    }

    /// recordings and edited videos: the scene scaled into a fixed canvas
    func testFixedCanvasHasNoSeeThroughPixels() throws {
        let profile = try XCTUnwrap(DeviceProfile.forModelIdentifier("iPhone19,4",
                                                                     screenSize: CGSize(width: 1398, height: 2034)))
        let image = try XCTUnwrap(SceneRenderer(style: style, profile: profile, showFrame: true,
                                                fixedCanvas: CGSize(width: 1920, height: 1080))
            .cgImage(screen: Self.black(width: 1398, height: 2034)))
        XCTAssertEqual(Self.seeThroughPixels(in: image), 0)
    }

    private static func black(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// pixels that are not fully opaque; on an opaque background there should be none
    private static func seeThroughPixels(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] < 255 }.count
    }
}
