// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import XCTest
@testable import MirrorAct

/// The mirror window is never lower than its tool rail, also when the rail changes from the
/// session: its "Latest" button comes with the first saved file, and its control part changes with
/// the control's state. Nothing here shows a window: the windows are never ordered front, and no
/// test lets control fail (that would put up an alert).
@MainActor
final class MirrorWindowRailTests: XCTestCase {
    /// A control that does nothing, with a state the test sets
    @MainActor
    final class FakeControl: @preconcurrency DeviceControl {
        let buttons: [DeviceButton] = [.back, .home, .recents]
        var state: ControlState {
            didSet { if state != oldValue { onStateChange?(state) } }
        }
        var onStateChange: ((ControlState) -> Void)?
        let startsOnDemand: Bool

        init(state: ControlState, startsOnDemand: Bool = true) {
            self.state = state
            self.startsOnDemand = startsOnDemand
        }

        func touch(_ phase: TouchPhase, at point: CGPoint) {}
        func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, precise: Bool) {}
        func key(_ event: NSEvent) -> Bool { false }
        func press(_ button: DeviceButton) {}
        func paste(_ text: String) {}
    }

    private func makeSession() -> MirrorSession {
        MirrorSession(id: "test", kind: .cable, deviceName: "iPhone", modelIdentifier: "iPhone14,2", muted: true)
    }

    /// lets the window's sinks run (they hop to the main queue once)
    private func turnTheRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func rail(in window: NSWindow) throws -> NSHostingView<MirrorToolRail> {
        try XCTUnwrap(window.contentView?.subviews.lazy.compactMap { $0 as? NSHostingView<MirrorToolRail> }.first)
    }

    /// the rail's height as it is now, measured as the window measures it
    private func railHeight(in window: NSWindow) throws -> CGFloat {
        let rail = try rail(in: window)
        rail.needsLayout = true
        rail.layoutSubtreeIfNeeded()
        return max(rail.fittingSize.height, 100)
    }

    /// the window is as high as the rail, and the rail lies within it at its full height
    private func assertTheWindowFitsTheRail(_ window: NSWindow, _ step: String,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let height = try railHeight(in: window)
        XCTAssertEqual(window.frame.height, height, accuracy: 1, "\(step): rail \(height)", file: file, line: line)
        let rail = try rail(in: window), bounds = try XCTUnwrap(window.contentView?.bounds)
        // a frame from before the change would lie within the window too
        XCTAssertEqual(rail.frame.height, height, accuracy: 1, "\(step): rail \(rail.frame), fitting \(height)",
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(rail.frame.minY, bounds.minY - 0.5, "\(step): rail \(rail.frame), window \(bounds)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(rail.frame.maxY, bounds.maxY + 0.5, "\(step): rail \(rail.frame), window \(bounds)",
                                 file: file, line: line)
    }

    /// A small window grows by the "Latest" button when the first file is saved
    func testTheWindowGrowsWhenTheFirstFileIsSaved() throws {
        setExperimentalFeatures(false)
        let session = makeSession()
        let controller = MirrorWindowController(session: session)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)
        // the device is then lower than the rail
        controller.setZoom(0.25)
        turnTheRunLoop()
        let low = window.frame.height
        try assertTheWindowFitsTheRail(window, "before")

        // no file is written: the rail reads only the name
        session.noteExport(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iPhone test.png"),
                           editable: nil)
        turnTheRunLoop()
        // a rail button with its spacing is about 54 points high
        XCTAssertGreaterThan(window.frame.height, low + 40, "low \(low)")
        XCTAssertLessThan(window.frame.height, low + 70, "low \(low)")
        try assertTheWindowFitsTheRail(window, "after the file")
        XCTAssertFalse(window.isVisible)
    }

    /// A small window gets lower when control is ready (a row of small buttons in place of the
    /// switch) and higher again when it is turned off, as on an iPhone
    func testTheWindowFollowsTheRailWhenControlTurnsOnAndOff() throws {
        setExperimentalFeatures(false)
        let session = makeSession()
        let control = FakeControl(state: .off)
        // as the app does for an iPhone: control comes before the window
        session.control = control
        let controller = MirrorWindowController(session: session)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)
        controller.setZoom(0.25)
        turnTheRunLoop()
        let low = window.frame.height
        try assertTheWindowFitsTheRail(window, "off")

        control.state = .ready
        turnTheRunLoop()
        // the switch is 48 points high, the row 30
        XCTAssertLessThan(window.frame.height, low - 10, "low \(low)")
        XCTAssertGreaterThan(window.frame.height, low - 25, "low \(low)")
        try assertTheWindowFitsTheRail(window, "ready")

        control.state = .off
        turnTheRunLoop()
        XCTAssertEqual(window.frame.height, low, accuracy: 1)
        try assertTheWindowFitsTheRail(window, "off again")
        XCTAssertFalse(window.isVisible)
    }

    /// A small window grows when a control comes to an open window and shrinks back when it goes,
    /// as on an Android phone whose cable is unplugged and plugged in again
    func testTheWindowFollowsTheRailWhenControlComesAndGoes() throws {
        setExperimentalFeatures(false)
        let session = makeSession()
        let controller = MirrorWindowController(session: session)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)
        controller.setZoom(0.25)
        turnTheRunLoop()
        let low = window.frame.height
        try assertTheWindowFitsTheRail(window, "without control")

        session.control = FakeControl(state: .ready, startsOnDemand: false)
        turnTheRunLoop()
        // the row of small buttons with its spacing is about 32 points high
        XCTAssertGreaterThan(window.frame.height, low + 20, "low \(low)")
        XCTAssertLessThan(window.frame.height, low + 45, "low \(low)")
        try assertTheWindowFitsTheRail(window, "with control")

        session.control = nil
        turnTheRunLoop()
        XCTAssertEqual(window.frame.height, low, accuracy: 1)
        try assertTheWindowFitsTheRail(window, "control gone")
        XCTAssertFalse(window.isVisible)
    }
}
