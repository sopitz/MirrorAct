// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest
@testable import MirrorAct

/// Presenting (⌃⌘F) must be possible to end without a keyboard shortcut (issue #14)
@MainActor
final class PresentationTests: XCTestCase {
    private var controller: MirrorWindowController!

    override func setUp() async throws {
        let session = MirrorSession(id: "test", kind: .cable, deviceName: "iPhone",
                                    modelIdentifier: "iPhone14,2", muted: true)
        controller = MirrorWindowController(session: session)
        controller.present()
    }

    override func tearDown() async throws {
        if controller.isPresenting { controller.togglePresentation() }
        controller.close()
        controller = nil
        PresentationWindow.controlsHideDelay = 3
    }

    func testExitButtonIsShownWhenPresentationStarts() throws {
        controller.togglePresentation()
        let window = try XCTUnwrap(controller.presentation)
        XCTAssertTrue(isShown(window.exitButton, in: window))
    }

    func testExitButtonEndsPresentation() throws {
        controller.togglePresentation()
        let window = try XCTUnwrap(controller.presentation)
        window.exitButton.performClick(nil)
        XCTAssertFalse(controller.isPresenting)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.window?.isVisible, true)
    }

    func testMenuBarStaysReachableWhilePresenting() {
        controller.togglePresentation()
        XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar))
        XCTAssertFalse(NSApp.presentationOptions.contains(.hideMenuBar))
        controller.togglePresentation()
        XCTAssertEqual(NSApp.presentationOptions, [])
    }

    func testEscEndsPresentation() throws {
        controller.togglePresentation()
        try XCTUnwrap(controller.presentation).cancelOperation(nil)
        XCTAssertFalse(controller.isPresenting)
    }

    func testContextMenuOffersToExit() throws {
        controller.togglePresentation()
        let menu = controller.contextMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == String(localized: "Exit Presentation") })
        menu.performActionForItem(at: menu.index(of: item))
        XCTAssertFalse(controller.isPresenting)
    }

    func testExitButtonHidesWhenIdleAndReturnsWhenMouseMoves() throws {
        PresentationWindow.controlsHideDelay = 0.2
        controller.togglePresentation()
        let window = try XCTUnwrap(controller.presentation)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(isShown(window.exitButton, in: window))

        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 200, y: 200),
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 0, pressure: 0))
        window.content.mouseMoved(with: event)
        XCTAssertTrue(isShown(window.exitButton, in: window))
    }

    /// several mirror windows: menu and keyboard shortcuts target the presenting one
    func testCommandsTargetThePresentingMirror() {
        let other = MirrorWindowController(session: MirrorSession(id: "other", kind: .cable, deviceName: "iPad",
                                                                  modelIdentifier: "iPad13,16", muted: true))
        defer { other.close() }
        other.present()
        controller.togglePresentation()
        XCTAssertTrue(AppModel.keyMirror(among: [other, controller]) === controller)
    }

    // MARK: Helpers

    /// in the window, not hidden, not transparent and within the screen
    private func isShown(_ view: NSView, in window: NSWindow) -> Bool {
        guard view.window === window, !view.isHiddenOrHasHiddenAncestor,
              let content = window.contentView else { return false }
        var current: NSView? = view
        while let v = current {
            if v.alphaValue < 0.5 { return false }
            current = v.superview
        }
        return content.bounds.contains(view.convert(view.bounds, to: content))
    }
}
