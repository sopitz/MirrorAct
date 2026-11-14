// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest
@testable import MirrorAct

/// Keep on top, and its reach into every desktop and other apps' full-screen Spaces.
/// What macOS shows there cannot be tested here (it takes another app in full screen): only a
/// panel that does not activate the app is shown, so the tests hold the window to that shape.
@MainActor
final class OnTopTests: XCTestCase {
    private final class Counter { var count = 0 }

    private var controller: MirrorWindowController!
    private var closes = Counter()
    private var stored = (onTop: false, everywhere: false)
    private var settings: AppSettings { .shared }

    override func setUp() async throws {
        stored = (settings.alwaysOnTop, settings.onTopEverywhere)
        settings.alwaysOnTop = false
        settings.onTopEverywhere = false
        let session = MirrorSession(id: "test", kind: .cable, deviceName: "iPhone",
                                    modelIdentifier: "iPhone14,2", muted: true)
        let closes = Counter()
        session.onClose = { closes.count += 1 }
        self.closes = closes
        controller = MirrorWindowController(session: session)
        controller.present()
    }

    override func tearDown() async throws {
        if controller.isPresenting { controller.togglePresentation() }
        controller.close()
        controller = nil
        settings.alwaysOnTop = stored.onTop
        settings.onTopEverywhere = stored.everywhere
    }

    func testKeepOnTopFloatsOnItsOwnDesktop() throws {
        settings.alwaysOnTop = true
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window is NSPanel)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        settings.alwaysOnTop = false
        XCTAssertEqual(controller.window?.level, .normal)
    }

    func testAboveFullScreenAppsTheWindowIsAPanelThatDoesNotActivateTheApp() throws {
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window is NSPanel)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.canBecomeKey)
    }

    func testThePanelTakesOverPlaceAndContent() throws {
        let before = try XCTUnwrap(controller.window)
        let frame = before.frame
        let content = try XCTUnwrap(before.contentView)
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window === before)
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(window.contentView === content)
        XCTAssertEqual(window.title, "iPhone")
        XCTAssertTrue(window.delegate === controller)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(before.isVisible)
    }

    func testWithoutKeepOnTopItStaysAnOrdinaryWindow() {
        settings.onTopEverywhere = true
        XCTAssertFalse(controller.window is NSPanel)
        XCTAssertEqual(controller.window?.level, .normal)
    }

    func testTurningItOffBringsTheWindowBack() throws {
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        settings.onTopEverywhere = false
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window is NSPanel)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.isVisible)

        settings.onTopEverywhere = true
        XCTAssertTrue(controller.window is NSPanel)
        settings.alwaysOnTop = false
        XCTAssertFalse(controller.window is NSPanel)
        XCTAssertEqual(controller.window?.level, .normal)
    }

    func testAWindowOpenedWithTheOptionOnStartsAsThePanel() {
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        let other = MirrorWindowController(session: MirrorSession(id: "other", kind: .cable, deviceName: "iPad",
                                                                  modelIdentifier: "iPad13,16", muted: true))
        defer { other.close() }
        XCTAssertTrue(other.window is NSPanel)
        XCTAssertEqual(other.window?.level, .floating)
    }

    /// replacing the window must not end the mirroring; closing the new one must
    func testOnlyClosingEndsTheSession() {
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        settings.onTopEverywhere = false
        settings.onTopEverywhere = true
        XCTAssertEqual(closes.count, 0)
        controller.close()
        XCTAssertEqual(closes.count, 1)
    }

    /// a panel with a close button closes on Esc
    func testEscDoesNotCloseThePanel() throws {
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        let window = try XCTUnwrap(controller.window)
        window.cancelOperation(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(closes.count, 0)
    }

    func testSwitchingWhilePresentingKeepsTheWindowHidden() {
        controller.togglePresentation()
        settings.alwaysOnTop = true
        settings.onTopEverywhere = true
        XCTAssertTrue(controller.window is NSPanel)
        XCTAssertEqual(controller.window?.isVisible, false)
        controller.togglePresentation()
        XCTAssertEqual(controller.window?.isVisible, true)
    }

    func testContextMenuOffersItOnlyWithKeepOnTop() throws {
        var menu = controller.contextMenu()
        menu.update()
        XCTAssertFalse(try item(in: menu).isEnabled)

        settings.alwaysOnTop = true
        menu = controller.contextMenu()
        menu.update()
        let entry = try item(in: menu)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.state, .off)
        menu.performActionForItem(at: menu.index(of: entry))
        XCTAssertTrue(settings.onTopEverywhere)
        XCTAssertTrue(controller.window is NSPanel)
        XCTAssertEqual(try item(in: controller.contextMenu()).state, .on)
    }

    private func item(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == String(localized: "Also Above Full-Screen Apps") })
    }
}
