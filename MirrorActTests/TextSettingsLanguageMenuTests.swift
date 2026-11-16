// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// The rows of “Translate into”
final class TextSettingsLanguageMenuTests: XCTestCase {
    /// what Apple's Translation offered on macOS 26.5, in its order
    static let supported = [
        "en-IN", "it-CH", "ko", "nb", "da", "en-CA", "en-SG", "es-MX", "uk", "fr-CA", "it", "zh-TW", "es",
        "nl", "ar-AE", "zh-HK", "vi", "zh", "ru", "en-GB", "es-US", "fr", "hi", "en-ZA", "th", "en-AU",
        "de-CH", "de", "en", "pt", "pl", "en-IE", "en-NZ", "sv", "id", "tr", "ja", "pt-PT",
    ].map { Locale.Language(identifier: $0) }

    private var supported: [Locale.Language] { Self.supported }
    private var onDevice: [Locale.Language] { Self.onDevice }

    /// Nine rows reading “English” cannot be told apart
    func testEveryRowHasALabelOfItsOwn() {
        for identifier in ["en", "de", "fr", "ja"] {
            let rows = TextSettingsView.languageRows(for: supported, in: Locale(identifier: identifier))
            XCTAssertEqual(rows.count, supported.count)
            XCTAssertEqual(Set(rows.map(\.label)).count, rows.count, "in \(identifier): \(rows.map(\.label))")
            XCTAssertEqual(Set(rows.map(\.id)), Set(supported.map(\.minimalIdentifier)))
        }
    }

    func testTheRegionIsNamedWhereALanguageComesMoreThanOnce() {
        let rows = TextSettingsView.languageRows(for: supported, in: Locale(identifier: "en"))
        let labels = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.label) })
        XCTAssertEqual(labels["de"], "German")
        XCTAssertEqual(labels["de-CH"], "German (Switzerland)")
        XCTAssertEqual(labels["en-GB"], "English (United Kingdom)")
        XCTAssertEqual(labels["pt-PT"], "Portuguese (Portugal)")
        XCTAssertEqual(labels["zh-TW"], "Chinese, Traditional (Taiwan)")
        // alone in its language
        XCTAssertEqual(labels["zh"], "Chinese, Simplified")
        XCTAssertEqual(labels["ar-AE"], "Arabic")
        XCTAssertEqual(labels["ko"], "Korean")
    }

    /// the languages of the on-device models of macOS 26.5, in their order
    static let onDevice = [
        "vi", "pt", "uk", "it", "zh-TW", "ko", "de", "en-GB", "zh", "ja", "id", "nl", "fr", "th", "es", "tr", "pl",
        "ar-AE", "ru", "en", "hi",
    ].map { Locale.Language(identifier: $0) }

    /// Every language stays; those only the models that need Apple Intelligence know say so
    func testTheRowsThatNeedAppleIntelligenceSaySo() {
        let needing: Set = ["da", "de-CH", "en-AU", "en-CA", "en-IE", "en-IN", "en-NZ", "en-SG", "en-ZA", "es-MX",
                            "es-US", "fr-CA", "it-CH", "nb", "pt-PT", "sv", "zh-HK"]
        for identifier in ["en", "de", "fr", "ja"] {
            let locale = Locale(identifier: identifier)
            let rows = TextSettingsView.languageRows(for: supported, onDevice: onDevice, in: locale)
            let plain = Dictionary(uniqueKeysWithValues: TextSettingsView.languageRows(for: supported, in: locale)
                .map { ($0.id, $0.label) })
            XCTAssertEqual(Set(rows.map(\.id)), Set(supported.map(\.minimalIdentifier)), identifier)
            XCTAssertEqual(Set(rows.filter(\.needsAppleIntelligence).map(\.id)), needing, identifier)
            for row in rows {
                let name = plain[row.id] ?? ""
                if row.needsAppleIntelligence {
                    // the name, and a few words more
                    XCTAssertTrue(row.label.hasPrefix(name) && row.label.count > name.count, row.label)
                    XCTAssertLessThan(row.label.count - name.count, 40, row.label)
                } else {
                    XCTAssertEqual(row.label, name, identifier)
                }
            }
            XCTAssertEqual(Set(rows.map(\.label)).count, rows.count, identifier)
            let labels = rows.map(\.label)
            XCTAssertEqual(labels, labels.sorted { $0.compare($1, locale: locale) == .orderedAscending }, identifier)
        }
        // one kind of models (before macOS 26.4), or nothing but on-device models: no row says so
        for list in [nil, supported] {
            let rows = TextSettingsView.languageRows(for: supported, onDevice: list, in: Locale(identifier: "en"))
            XCTAssertFalse(rows.contains(where: \.needsAppleIntelligence))
            XCTAssertEqual(rows, TextSettingsView.languageRows(for: supported, in: Locale(identifier: "en")))
        }
    }

    func testTheRowsAreInTheOrderOfTheirLabels() {
        let locale = Locale(identifier: "de")
        let labels = TextSettingsView.languageRows(for: supported, in: locale).map(\.label)
        XCTAssertEqual(labels, labels.sorted { $0.compare($1, locale: locale) == .orderedAscending })
    }

    /// "System language" comes to the row the engine translates into: the on-device models' form
    /// of the language wherever they have it. Where that row needs Apple Intelligence, the line
    /// under the menu says so as it does for a language chosen.
    func testTheSystemLanguageComesToTheRowTheEngineTranslatesInto() {
        let languages = AppleTranslationLanguages(onDevice: onDevice, all: supported)
        let locale = Locale(identifier: "en")
        let apple = TextSettingsView.languageRows(for: languages, engine: "apple", in: locale)
        let service = TextSettingsView.languageRows(for: languages, engine: "llm", in: locale)
        let cases: [(system: String, row: String?, needsAppleIntelligence: Bool)] = [
            ("da-DK", "da", true),
            ("da", "da", true),
            ("sv-SE", "sv", true),
            ("nb-NO", "nb", true),
            ("de-CH", "de", false),
            ("de-DE", "de", false),
            ("pt-PT", "pt", false),
            ("en-DE", "en-GB", false),
            ("zh-HK", "zh-TW", false),
            ("fi-FI", nil, false),
        ]
        for entry in cases {
            let system = Locale.Language(identifier: entry.system)
            let row = TextSettingsView.systemRow(for: system, in: apple, lists: languages.lists)
            XCTAssertEqual(row?.id, entry.row, entry.system)
            XCTAssertEqual(row?.needsAppleIntelligence ?? false, entry.needsAppleIntelligence, entry.system)
            // the engine comes to the same language
            XCTAssertEqual(row?.id, LanguageMatching.match(system, inFirstOf: languages.lists)?.minimalIdentifier,
                           entry.system)
            // a service needs no Apple Intelligence
            XCTAssertFalse(TextSettingsView.systemRow(for: system, in: service, lists: languages.lists)?
                .needsAppleIntelligence ?? false, entry.system)
        }
    }

    /// A language model service needs no Apple Intelligence: with it, no row says so
    func testOnlyThisMacNeedsAppleIntelligence() {
        let languages = AppleTranslationLanguages(onDevice: onDevice, all: supported)
        for identifier in ["en", "de"] {
            let locale = Locale(identifier: identifier)
            let apple = TextSettingsView.languageRows(for: languages, engine: "apple", in: locale)
            let service = TextSettingsView.languageRows(for: languages, engine: "llm", in: locale)
            XCTAssertEqual(apple, TextSettingsView.languageRows(for: supported, onDevice: onDevice, in: locale))
            XCTAssertEqual(service, TextSettingsView.languageRows(for: supported, in: locale))
            XCTAssertTrue(apple.contains(where: \.needsAppleIntelligence), identifier)
            XCTAssertFalse(service.contains(where: \.needsAppleIntelligence), identifier)
            // the same languages under the same names
            XCTAssertEqual(apple.map(\.id).sorted(), service.map(\.id).sorted(), identifier)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: apple.map { ($0.id, $0.name) }),
                           Dictionary(uniqueKeysWithValues: service.map { ($0.id, $0.name) }), identifier)
            for row in service {
                XCTAssertEqual(row.label, row.name, identifier)
            }
        }
    }
}
