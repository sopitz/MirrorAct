// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Translation
import XCTest
@testable import MirrorAct

/// Translating with Apple's framework, as far as it can be tested without a session: nothing in
/// here asks macOS to translate or to load a language. (How the texts of a request are sorted by
/// language is tested with plain values in TextCore/LanguageMatchingTests.)
@MainActor
final class AppleTranslationEngineTests: XCTestCase {
    /// some of the languages macOS translates, as it lists them
    private let supported = ["de-DE", "en-GB", "en-US", "es-ES", "fr-FR", "it-IT", "ja-JP", "zh-CN", "zh-TW"]
        .map { Locale.Language(identifier: $0) }

    private func language(_ identifier: String) -> Locale.Language {
        Locale.Language(identifier: identifier)
    }

    private func languages(of texts: [String]) -> (findings: [LanguageMatching.Finding], common: Locale.Language?) {
        AppleTranslationEngine.readLanguages(of: texts, tags: LanguageMatching.recognizerTags(for: supported),
                                             supported: supported)
    }

    // MARK: The engine

    func testTheEngineTranslatesOnThisMac() {
        let engine = AppleTranslationEngine()
        let client = AppleTranslationClient(engine: engine)
        XCTAssertEqual(client.name, "Apple")
        XCTAssertFalse(client.isRemote)
        XCTAssertFalse(client.prefersSettledText)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    func testAClientWithoutWorkCanBeCancelled() async throws {
        let engine = AppleTranslationEngine()
        let client = AppleTranslationClient(engine: engine)
        client.cancel()
        // from another thread it goes to the main actor by itself
        let other = AppleTranslationClient(engine: engine)
        await Task.detached { other.cancel() }.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.isCancelled)
        XCTAssertTrue(other.isCancelled)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    func testNotifyCanBeSetAndReadFromAnyThread() async {
        let client = AppleTranslationClient(engine: AppleTranslationEngine())
        XCTAssertNil(client.notify)
        client.notify = { _ in }
        let isSet = await Task.detached { client.notify != nil }.value
        XCTAssertTrue(isSet)
        await Task.detached { client.notify = nil }.value
        XCTAssertNil(client.notify)
    }

    func testARequestWithoutTextsNeedsNoSession() async throws {
        let engine = AppleTranslationEngine()
        let translations = try await AppleTranslationClient(engine: engine).translate([], into: language("de"))
        XCTAssertTrue(translations.isEmpty)
        XCTAssertTrue(engine.hosts.isEmpty)
    }

    /// A window that turns translating off ends its own turn only: another window's client
    /// goes on, and a cancelled client asks nothing of the engine anymore
    func testACancelledClientIsDoneAndLeavesTheOthersAlone() async throws {
        let engine = AppleTranslationEngine()
        let first = AppleTranslationClient(engine: engine)
        let second = AppleTranslationClient(engine: engine)
        first.cancel()
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        let translations = try await first.translate(["Einstellungen", "Allgemein"], into: language("en"))
        XCTAssertEqual(translations, [nil, nil])
        XCTAssertTrue(engine.hosts.isEmpty)
        second.cancel()
    }

    func testEveryHostIsANewViewWithAConfigurationOfItsOwn() {
        let first = AppleTranslationHost(pair: "en→de", source: language("en-US"), target: language("de-DE"))
        let second = AppleTranslationHost(pair: "en→de", source: language("en-US"), target: language("de-DE"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.configuration.source?.maximalIdentifier, language("en-US").maximalIdentifier)
        XCTAssertEqual(first.configuration.target?.maximalIdentifier, language("de-DE").maximalIdentifier)
        // a copy of a host hands the view the same configuration: its task is not started again
        let copy = first
        XCTAssertEqual(copy.id, first.id)
        XCTAssertEqual(copy.configuration, first.configuration)
    }

    func testTheWindowForTheViewsIsNotToBeSeen() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen")
        // without hosts it holds no view that would ask for a session
        let window = AppleTranslationHostWindow.make(for: AppleTranslationEngine())
        defer { window.close() }
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertEqual(window.alphaValue, 0.02, accuracy: 0.001)
        XCTAssertTrue(window.contentView is PassthroughHostingView<AppleTranslationHostView>)
        // outside of every screen, except while macOS asks whether it may load languages
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        AppleTranslationHostWindow.place(window, onScreen: true)
        XCTAssertTrue(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        AppleTranslationHostWindow.place(window, onScreen: false)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }

    // MARK: Languages of the texts (the language recognizer of macOS; needs no download)

    func testTheLanguageOfWholeSentencesIsDecided() {
        let found = languages(of: [
            "Das ist ein ganz gewöhnlicher deutscher Satz über das Wetter von heute und von morgen.",
            "This is an ordinary English sentence about the weather today.",
            "OK",
        ])
        XCTAssertEqual(found.findings.count, 3)
        XCTAssertEqual(found.findings[0].decided?.languageCode?.identifier, "de")
        XCTAssertEqual(found.findings[1].decided?.languageCode?.identifier, "en")
        // too short to tell
        XCTAssertNil(found.findings[2].decided)
        XCTAssertEqual(found.findings[2].letters, 2)
        // most of the text is German
        XCTAssertEqual(found.common?.languageCode?.identifier, "de")
    }

    func testTextsAreSortedByTheirLanguage() {
        let texts = [
            "This is an ordinary English sentence about the weather today.",
            "Das ist ein ganz gewöhnlicher deutscher Satz über das Wetter von heute und von morgen.",
            "OK",
            "Ceci est une phrase française tout à fait ordinaire sur le temps qu’il fait aujourd’hui.",
            "12:30",
        ]
        let found = languages(of: texts)
        let plan = LanguageMatching.Plan(findings: found.findings, common: language("en"), target: language("de-DE"),
                                         supported: supported)
        XCTAssertEqual(plan.groups.map(\.indices), [[0, 2], [3]])
        XCTAssertEqual(plan.groups.map { $0.source.languageCode?.identifier }, ["en", "fr"])
        XCTAssertEqual(plan.unchanged, [1, 4])
        XCTAssertEqual(plan.postponed, [])
        XCTAssertEqual(plan.results(for: texts), [nil, texts[1], nil, nil, "12:30"])
    }

    func testATextInALanguageMacOSDoesNotTranslateStaysAsItIs() {
        let finnish = "Tämä on aivan tavallinen suomenkielinen lause tämän päivän säästä ja huomisesta."
        let found = languages(of: [finnish])
        XCTAssertEqual(found.findings.first?.decided?.languageCode?.identifier, "fi")
        let plan = LanguageMatching.Plan(findings: found.findings, common: found.common, target: language("de-DE"),
                                         supported: supported)
        XCTAssertEqual(plan.unchanged, [0])
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.unknown.map { $0.languageCode?.identifier }, ["fi"])
    }

    func testShortLabelsAreReadTogether() {
        // none is long enough on its own
        let labels = ["Allgemein", "Datenschutz", "Abbrechen", "Speichern", "Löschen", "Hinzufügen", "Nachrichten",
                      "Einladung"]
        let found = languages(of: labels)
        XCTAssertTrue(found.findings.allSatisfy { $0.decided == nil })
        XCTAssertEqual(found.common?.languageCode?.identifier, "de")
    }
}
