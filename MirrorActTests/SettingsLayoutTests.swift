// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import XCTest
@testable import MirrorAct

/// Settings on small screens (issue #14: MacBook Air 13" with 1470 × 956)
@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// visible height at 1470 × 956: minus the menu bar with Notch
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

    func testTextFitsOnSmallScreen() {
        let height = pageHeight(TextSettingsView(), visibleHeight: smallScreen)
        XCTAssertLessThanOrEqual(height + SettingsView.windowChrome, smallScreen)
    }

    /// the longest the text page gets: a service with address, key and all its lines
    func testTextWithALanguageModelServiceFitsOnSmallScreen() {
        let settings = AppSettings.shared
        let engine = settings.translationEngine, provider = settings.llmProvider
        defer {
            settings.translationEngine = engine
            settings.llmProvider = provider
        }
        settings.translationEngine = "llm"
        settings.llmProvider = LLMProvider.custom.id
        let height = pageHeight(TextSettingsView(), visibleHeight: smallScreen)
        XCTAssertLessThanOrEqual(height + SettingsView.windowChrome, smallScreen)
    }

    /// on large screens everything stays visible without scrolling
    func testPagesKeepTheirFullHeightOnLargeScreens() {
        XCTAssertEqual(pageHeight(GeneralSettingsView(), visibleHeight: largeScreen),
                       naturalHeight(GeneralSettingsView()), accuracy: 1)
        XCTAssertEqual(pageHeight(DesignSettingsView(), visibleHeight: largeScreen),
                       naturalHeight(DesignSettingsView()), accuracy: 1)
    }

    /// windowChrome must cover the title bar and toolbar of the real settings window
    func testWindowChromeCoversTheRealSettingsWindow() throws {
        let window = try openSettingsWindow()
        defer { window.close() }
        let chrome = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(chrome, 0)
        XCTAssertLessThanOrEqual(chrome, SettingsView.windowChrome)
    }

    // MARK: The Text page in every language

    /// Each menu button shows its whole choice, in every language of the app and for every
    /// service: in German, "Übersetzen mit" read "Ein Sprachmodell-Dienst, mit eigenem API-…".
    /// The language chosen is the one with the longest name of those that need Apple Intelligence.
    func testTheTextPageShowsEveryChoiceInFull() throws {
        try forEachTextPage { page, situation in
            let popUps = self.popUpButtons(in: page)
            XCTAssertGreaterThanOrEqual(popUps.count, 2, situation)
            // the button shows the language's name; the note “needs Apple Intelligence” is in the
            // menu and in a line of its own
            XCTAssertTrue(popUps.contains { $0.title == self.chosenLanguage.name }, situation)
            for popUp in popUps {
                let cell = try XCTUnwrap(popUp.cell as? NSPopUpButtonCell)
                // (not rounded up to whole points: at 2x a button is laid out in half points)
                let room = cell.titleRect(forBounds: popUp.bounds).width
                let needed = popUp.attributedTitle.size().width
                XCTAssertGreaterThanOrEqual(room, needed, "“\(popUp.title)” is cut off, \(situation)")
            }
        }
    }

    /// No field looks empty: with nothing entered, each says what belongs there. For Azure,
    /// Custom, Ollama and LM Studio the model field showed nothing, as they have no default model.
    func testEveryEmptyFieldSaysWhatBelongsThere() throws {
        try forEachTextPage { page, situation in
            let fields = self.textFields(in: page).filter { !($0 is NSSecureTextField) }
            // a service has a model field at least
            XCTAssertEqual(fields.isEmpty, situation.hasSuffix("this Mac"), situation)
            for field in fields {
                XCTAssertEqual(field.stringValue, "", situation)
                XCTAssertFalse(field.placeholderString?.trimmingCharacters(in: .whitespaces).isEmpty ?? true,
                               "a field without a placeholder, \(situation)")
            }
        }
    }

    // MARK: Helpers

    /// The Text page as the settings window shows it, in each language of the app (as SwiftUI
    /// looks its texts up), with “This Mac” and with each service. The page gets a key store of
    /// its own, so that the keychain is never read.
    private func forEachTextPage(_ check: (NSView, String) throws -> Void) throws {
        let settings = AppSettings.shared
        let saved = (settings.translationEngine, settings.llmProvider, settings.translationLanguage,
                     settings.llmModels, settings.llmBaseURLs)
        defer {
            settings.translationEngine = saved.0
            settings.llmProvider = saved.1
            settings.translationLanguage = saved.2
            settings.llmModels = saved.3
            settings.llmBaseURLs = saved.4
        }
        settings.translationLanguage = chosenLanguage.id
        settings.llmModels = [:]
        settings.llmBaseURLs = [:]
        let keys = TextSettingsView.KeyStore(hasKey: { _ in false }, key: { _ in nil }, set: { _, _ in true })
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        XCTAssertTrue(languages.contains("de") && languages.contains("en"), "\(languages)")
        let services: [String?] = [nil] + LLMProvider.all.map(\.id)
        for language in languages {
            for service in services {
                settings.translationEngine = service == nil ? "apple" : "llm"
                if let service { settings.llmProvider = service }
                let view = TextSettingsView(keys: keys, languages: Self.languages)
                    .settingsPage(maxHeight: 2000)
                    .frame(width: SettingsView.width)
                    .environment(\.locale, Locale(identifier: language))
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: SettingsView.width, height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFrontRegardless()
                defer {
                    window.orderOut(nil)
                    window.contentView = nil
                }
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(waitUntil { self.popUpButtons(in: host).count >= (service == nil ? 2 : 4) },
                              "the menus of the page did not appear: \(self.popUpButtons(in: host).map(\.title))")
                try check(host, "in “\(language)” with \(service ?? "this Mac")")
            }
        }
    }

    /// what Apple's Translation offers on macOS 26.5, whatever this Mac has
    private static let languages = AppleTranslationLanguages(onDevice: TextSettingsLanguageMenuTests.onDevice,
                                                             all: TextSettingsLanguageMenuTests.supported)

    /// of the languages that need Apple Intelligence, the one with the longest name
    private var chosenLanguage: TextSettingsView.LanguageRow {
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return TextSettingsView.languageRows(for: Self.languages, engine: "apple", in: locale)
            .filter(\.needsAppleIntelligence)
            .max { ($0.name as NSString).size(withAttributes: [.font: font]).width
                < ($1.name as NSString).size(withAttributes: [.font: font]).width }!
    }

    /// the fields the user types into
    private func textFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap(textFields)
    }

    private func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popUpButtons)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

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

    /// like “MirrorAct > Settings…” (⌘,)
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
