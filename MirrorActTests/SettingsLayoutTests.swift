// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import XCTest
@testable import MirrorAct

/// Einstellungen auf kleinen Bildschirmen (Issue #14: MacBook Air 13" mit 1470 × 956)
@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// sichtbare Höhe bei 1470 × 956: abzüglich Menüleiste mit Notch
    private let smallScreen: CGFloat = 956 - 37
    private let largeScreen: CGFloat = 1692 - 25

    func testGeneralFitsOnSmallScreen() {
        let height = pageHeight(GeneralSettingsView(), visibleHeight: smallScreen)
        XCTAssertLessThanOrEqual(height + SettingsView.windowChrome, smallScreen)
    }

    func testStyleFitsOnSmallScreen() {
        let height = pageHeight(DesignSettingsView(), visibleHeight: smallScreen)
        XCTAssertLessThanOrEqual(height + SettingsView.windowChrome, smallScreen)
    }

    /// auf grossen Bildschirmen bleibt alles ohne Scrollen sichtbar
    func testPagesKeepTheirFullHeightOnLargeScreens() {
        XCTAssertEqual(pageHeight(GeneralSettingsView(), visibleHeight: largeScreen),
                       naturalHeight(GeneralSettingsView()), accuracy: 1)
        XCTAssertEqual(pageHeight(DesignSettingsView(), visibleHeight: largeScreen),
                       naturalHeight(DesignSettingsView()), accuracy: 1)
    }

    /// windowChrome muss Titel- und Symbolleiste des echten Einstellungsfensters abdecken
    func testWindowChromeCoversTheRealSettingsWindow() throws {
        let window = try openSettingsWindow()
        defer { window.close() }
        let chrome = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(chrome, 0)
        XCTAssertLessThanOrEqual(chrome, SettingsView.windowChrome)
    }

    // MARK: Hilfen

    private func pageHeight<V: View>(_ page: V, visibleHeight: CGFloat) -> CGFloat {
        let maxHeight = SettingsView.maxPageHeight(visibleHeight: visibleHeight)
        return fittingHeight(page.settingsPage(maxHeight: maxHeight))
    }

    private func naturalHeight<V: View>(_ page: V) -> CGFloat {
        fittingHeight(page.fixedSize(horizontal: false, vertical: true))
    }

    private func fittingHeight<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: SettingsView.width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// wie «MirrorAct > Einstellungen …» (⌘,)
    private func openSettingsWindow() throws -> NSWindow {
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let index = try XCTUnwrap(appMenu.items.firstIndex { $0.keyEquivalent == "," })
        appMenu.performActionForItem(at: index)
        var window: NSWindow?
        let deadline = Date().addingTimeInterval(5)
        while window == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
        }
        return try XCTUnwrap(window, "Einstellungsfenster nicht gefunden")
    }
}
