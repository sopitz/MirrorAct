// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest
@testable import MirrorAct

/// The style panel is dark like the tool rail, also in light mode (issue #19)
@MainActor
final class StylePanelAppearanceTests: XCTestCase {
    private var controller: MirrorWindowController!
    private var appAppearance: NSAppearance?

    override func setUp() async throws {
        appAppearance = NSApp.appearance
        controller = MirrorWindowController(session: MirrorSession(id: "test", kind: .cable, deviceName: "iPhone",
                                                                   modelIdentifier: "iPhone14,2", muted: true))
        controller.present()
    }

    override func tearDown() async throws {
        controller.close()
        controller = nil
        NSApp.appearance = appAppearance
    }

    func testStylePanelIsDarkInLightMode() throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(try stylePanelAppearance(), .darkAqua)
    }

    func testStylePanelIsDarkInDarkMode() throws {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(try stylePanelAppearance(), .darkAqua)
    }

    /// opens the style panel like ⌘K and returns the appearance of its popover window
    private func stylePanelAppearance() throws -> NSAppearance.Name? {
        controller.showStylePanel()
        var popover: NSWindow?
        let deadline = Date().addingTimeInterval(5)
        while popover == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            popover = NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") }
        }
        return try XCTUnwrap(popover, "style panel not found").effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }
}
