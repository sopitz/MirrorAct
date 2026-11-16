// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import XCTest
@testable import MirrorAct

/// The setting "Experimental features": off by default, and with it off the app shows nothing
/// of Text and Translate. Nothing here shows a window: the windows the tests need are never
/// ordered front.
@MainActor
final class ExperimentalFeaturesTests: XCTestCase {
    private var settings: AppSettings { .shared }

    // MARK: The setting

    func testTheSettingIsOffByDefaultAndStored() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(AppSettings.testSuiteName)))
        let stored = suite.object(forKey: "experimentalFeatures")
        defer { suite.set(stored, forKey: "experimentalFeatures") }
        // what a user who never opened the settings has
        suite.removeObject(forKey: "experimentalFeatures")
        XCTAssertEqual(settings.defaults.object(forKey: "experimentalFeatures") as? Bool, false,
                       "registered off")

        setExperimentalFeatures(true)
        XCTAssertEqual(suite.object(forKey: "experimentalFeatures") as? Bool, true)
        XCTAssertTrue(settings.featureGate.allows(.textOnScreen))
        settings.experimentalFeatures = false
        XCTAssertEqual(suite.object(forKey: "experimentalFeatures") as? Bool, false)
        XCTAssertFalse(settings.featureGate.allows(.textOnScreen))
    }

    // MARK: The gate

    func testTheGateShowsTextAndTranslateOnlyWithTheSetting() {
        let off = FeatureGate(experimental: false), on = FeatureGate(experimental: true)
        XCTAssertFalse(off.allows(.textOnScreen))
        XCTAssertEqual(off.railItems, [])
        XCTAssertEqual(off.menuItems, [])
        XCTAssertEqual(off.settingsTabs, [.general, .design])

        XCTAssertTrue(on.allows(.textOnScreen))
        XCTAssertEqual(on.railItems, [.copyText, .translate])
        XCTAssertEqual(on.menuItems, [.copyText, .translate])
        XCTAssertEqual(on.settingsTabs, [.general, .design, .text])
    }

    /// A stored selection of the Text tab, from a time with the setting on, shows General
    func testAStoredTextTabFallsBackToGeneralWhileTheSettingIsOff() {
        let off = FeatureGate(experimental: false), on = FeatureGate(experimental: true)
        XCTAssertEqual(off.settingsTab(forStored: "text"), .general)
        XCTAssertEqual(on.settingsTab(forStored: "text"), .text)
        XCTAssertEqual(off.settingsTab(forStored: "design"), .design)
        XCTAssertEqual(on.settingsTab(forStored: "general"), .general)
        XCTAssertEqual(on.settingsTab(forStored: "unknown"), .general)
    }

    // MARK: The tool rail

    private func railHeight() -> CGFloat {
        let session = MirrorSession(id: "test", kind: .cable, deviceName: "iPhone", modelIdentifier: "iPhone14,2",
                                    muted: true)
        let chrome = MirrorChrome()
        chrome.hovering = true
        let actions = MirrorActions(close: {}, present: {}, zoomIn: {}, zoomOut: {}, actualSize: {}, lifeSize: {},
                                    pixelPerfect: {}, fitToScreen: {}, saveScreenshot: {}, copyScreenshot: {},
                                    screenshotFile: { nil }, toggleRecording: {}, disconnect: {})
        let host = NSHostingView(rootView: MirrorToolRail(session: session, chrome: chrome, actions: actions))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The rail without Text and Translate is two buttons lower, as it is without the feature
    func testTheRailShowsTextAndTranslateOnlyWithTheSetting() {
        setExperimentalFeatures(false)
        let off = railHeight()
        settings.experimentalFeatures = true
        let on = railHeight()
        // a rail button is about 50 points high
        XCTAssertGreaterThan(on - off, 80, "off \(off), on \(on)")
        XCTAssertLessThan(on - off, 130, "off \(off), on \(on)")
    }

    /// The mirror window is never lower than its rail: a small window grows when Text and
    /// Translate come and shrinks back when they go. The window is never shown.
    func testTheWindowFollowsTheRailWhenTheSettingChanges() throws {
        setExperimentalFeatures(false)
        let session = MirrorSession(id: "test", kind: .cable, deviceName: "iPhone", modelIdentifier: "iPhone14,2",
                                    muted: true)
        let controller = MirrorWindowController(session: session)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)
        // the device is then lower than the rail
        controller.setZoom(0.25)
        let low = window.frame.height
        settings.experimentalFeatures = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(window.frame.height, low + 80, "low \(low)")
        settings.experimentalFeatures = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(window.frame.height, low, accuracy: 1)
        XCTAssertFalse(window.isVisible)
    }

    /// A layout of the window right after the setting changed has the rail as it is now. The
    /// rail's view takes a change on only when it is laid out. The window used to be measured
    /// around the rail from before, and followed the setting only when SwiftUI had brought the
    /// rail up to date first: on macOS 26 that held in the tests as long as the host had its
    /// start window, and failed about every second time without it.
    func testALayoutRightAfterTheSettingChangesHasTheNewRail() throws {
        setExperimentalFeatures(false)
        let session = MirrorSession(id: "test", kind: .cable, deviceName: "iPhone", modelIdentifier: "iPhone14,2",
                                    muted: true)
        let controller = MirrorWindowController(session: session)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.setZoom(0.25)
        let low = window.frame.height
        // (setting the zoom lays the window out at once, before anything else can run)
        settings.experimentalFeatures = true
        controller.setZoom(0.25)
        XCTAssertGreaterThan(window.frame.height, low + 80, "low \(low)")
        settings.experimentalFeatures = false
        controller.setZoom(0.25)
        XCTAssertEqual(window.frame.height, low, accuracy: 1)
        XCTAssertFalse(window.isVisible)
    }

    // MARK: The settings window

    /// The settings window hosted in a window that is never shown, with a Text page that never
    /// touches the keychain
    private func hostSettingsWindow() -> (window: NSWindow, tabs: () -> NSTabView?) {
        let keys = TextSettingsView.KeyStore(hasKey: { _ in false }, key: { _ in nil }, set: { _, _ in true })
        let languages = AppleTranslationLanguages(onDevice: TextSettingsLanguageMenuTests.onDevice,
                                                  all: TextSettingsLanguageMenuTests.supported)
        let host = NSHostingView(rootView: SettingsView(textKeys: keys, textLanguages: languages))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: SettingsView.width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        func tabView(in view: NSView) -> NSTabView? {
            (view as? NSTabView) ?? view.subviews.lazy.compactMap(tabView(in:)).first
        }
        return (window, {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            return tabView(in: host)
        })
    }

    private var tabNames: (off: [String], on: [String]) {
        let off = [String(localized: "General"), String(localized: "Style")]
        return (off, off + [String(localized: "Text")])
    }

    /// With the setting off the settings window has no tab "Text", and a stored selection of it
    /// shows General
    func testTheSettingsWindowHasNoTextTabWhileTheSettingIsOff() throws {
        setExperimentalFeatures(false)
        let stored = settings.defaults.string(forKey: "settingsTab")
        settings.defaults.set("text", forKey: "settingsTab")
        defer { settings.defaults.set(stored, forKey: "settingsTab") }
        let (window, tabs) = hostSettingsWindow()
        defer { window.contentView = nil }
        let tabView = try XCTUnwrap(tabs())
        XCTAssertEqual(tabView.tabViewItems.map(\.label), tabNames.off)
        XCTAssertEqual(tabView.selectedTabViewItem?.label, String(localized: "General"))
        XCTAssertFalse(window.isVisible)
    }

    /// The open settings window follows the setting: the tab "Text" goes while it is shown, the
    /// window shows General and keeps it once the tab is back
    func testTheSettingsWindowFollowsTheSetting() throws {
        setExperimentalFeatures(true)
        let stored = settings.defaults.string(forKey: "settingsTab")
        settings.defaults.set("text", forKey: "settingsTab")
        defer { settings.defaults.set(stored, forKey: "settingsTab") }
        let (window, tabs) = hostSettingsWindow()
        defer { window.contentView = nil }
        var tabView = try XCTUnwrap(tabs())
        XCTAssertEqual(tabView.tabViewItems.map(\.label), tabNames.on)
        XCTAssertEqual(tabView.selectedTabViewItem?.label, String(localized: "Text"))

        settings.experimentalFeatures = false
        tabView = try XCTUnwrap(tabs())
        XCTAssertEqual(tabView.tabViewItems.map(\.label), tabNames.off)
        XCTAssertEqual(tabView.selectedTabViewItem?.label, String(localized: "General"))
        XCTAssertEqual(settings.defaults.string(forKey: "settingsTab"), "general")

        settings.experimentalFeatures = true
        tabView = try XCTUnwrap(tabs())
        XCTAssertEqual(tabView.tabViewItems.map(\.label), tabNames.on)
        XCTAssertEqual(tabView.selectedTabViewItem?.label, String(localized: "General"))
        XCTAssertFalse(window.isVisible)
    }

    // MARK: The menus

    private func textItems(_ gate: FeatureGate) -> [NSMenuItem] {
        let actions = MirrorActions(close: {}, present: {}, zoomIn: {}, zoomOut: {}, actualSize: {}, lifeSize: {},
                                    pixelPerfect: {}, fitToScreen: {}, saveScreenshot: {}, copyScreenshot: {},
                                    screenshotFile: { nil }, toggleRecording: {}, disconnect: {})
        return MirrorWindowController.textMenuItems(gate: gate, translating: false, actions: actions)
    }

    func testTheContextMenuHasTheTextItemsOnlyWithTheSetting() {
        XCTAssertEqual(textItems(FeatureGate(experimental: false)), [])
        let items = textItems(FeatureGate(experimental: true))
        XCTAssertEqual(items.map(\.title), [String(localized: "Copy Text on Screen"),
                                            String(localized: "Translate Text on Screen")])
        XCTAssertEqual(items.map(\.keyEquivalentModifierMask), [[.command, .option], [.command, .shift]])
    }

    /// The menu bar's items with ⌥⌘T and ⇧⌘T, wherever they are
    private func textShortcuts(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { item -> [NSMenuItem] in
            let mask = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
            let own = item.keyEquivalent.lowercased() == "t"
                && (mask == [.command, .option] || mask == [.command, .shift]) ? [item] : []
            return own + textShortcuts(in: item.submenu)
        }
    }

    /// The menu bar's text items once SwiftUI has brought its menus up to date, as it does
    /// when a menu opens
    private func waitForMenuBar(count: Int) -> [NSMenuItem] {
        func update() -> [NSMenuItem] {
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
            }
            return textShortcuts(in: NSApp.mainMenu)
        }
        let deadline = Date().addingTimeInterval(5)
        var items = update()
        while items.count != count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            items = update()
        }
        return items
    }

    /// The Device menu of the test host's own menu bar: without the setting neither the items
    /// nor their shortcuts are there, and they follow the setting while the app runs
    func testTheDeviceMenuHasTheTextItemsOnlyWithTheSetting() throws {
        try XCTSkipIf(NSApp.mainMenu == nil, "the test host has no menu bar")
        setExperimentalFeatures(false)
        XCTAssertEqual(waitForMenuBar(count: 0).map(\.title), [])
        settings.experimentalFeatures = true
        XCTAssertEqual(Set(waitForMenuBar(count: 2).map(\.title)),
                       [String(localized: "Copy Text on Screen"), String(localized: "Translate Text on Screen")])
        settings.experimentalFeatures = false
        XCTAssertEqual(waitForMenuBar(count: 0).map(\.title), [])
    }
}
