// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import XCTest
@testable import MirrorAct

/// The app while it runs as the test host
@MainActor
final class TestHostTests: XCTestCase {
    /// The host opens no start window. The window would be on the screen of whoever runs the
    /// tests for the whole run, and AppKit would save its frame into the preferences of the
    /// installed app, which the test host shares its bundle identifier with.
    func testTheHostOpensNoStartWindow() {
        // SwiftUI opens the window of the first scene while the app launches, before the first
        // test runs; waiting a second covers a launch that is slower at it
        let deadline = Date().addingTimeInterval(1)
        while startWindows.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(startWindows.isEmpty, "the start window is open: \(describe(startWindows))")
    }

    /// The windows SwiftUI made for the scene of the start window, shown or not. It gives such a
    /// window the scene's id as its identifier and as the name its frame is saved under.
    private var startWindows: [NSWindow] {
        NSApp.windows.filter {
            $0.identifier?.rawValue == MirrorActApp.launcherID || $0.frameAutosaveName == MirrorActApp.launcherID
        }
    }

    private func describe(_ windows: [NSWindow]) -> String {
        windows.map {
            "[identifier \($0.identifier?.rawValue ?? "none"), frame saved as \"\($0.frameAutosaveName)\", "
                + "visible \($0.isVisible), frame \($0.frame)]"
        }
        .joined(separator: " ")
    }
}
