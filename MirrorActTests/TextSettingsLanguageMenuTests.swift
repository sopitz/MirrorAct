// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// The rows of “Translate into”
final class TextSettingsLanguageMenuTests: XCTestCase {
    /// what Apple's Translation offered on macOS 26.5, in its order
    private let supported = [
        "en-IN", "it-CH", "ko", "nb", "da", "en-CA", "en-SG", "es-MX", "uk", "fr-CA", "it", "zh-TW", "es",
        "nl", "ar-AE", "zh-HK", "vi", "zh", "ru", "en-GB", "es-US", "fr", "hi", "en-ZA", "th", "en-AU",
        "de-CH", "de", "en", "pt", "pl", "en-IE", "en-NZ", "sv", "id", "tr", "ja", "pt-PT",
    ].map { Locale.Language(identifier: $0) }

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
    private let onDevice = [
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
}
