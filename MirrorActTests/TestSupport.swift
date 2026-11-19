// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MirrorAct

/// QuickDraw, which the tests see through Foundation and Core Graphics, has a type of the same
/// name, so `RGBColor` alone is ambiguous in the test bundle. A name of the test bundle itself
/// comes before the imported ones.
typealias RGBColor = MirrorAct.RGBColor

extension XCTestCase {
    /// Turns the setting "Experimental features" on or off for the test that calls it, in the
    /// tests' own settings; it is set back when that test ends
    @MainActor
    func setExperimentalFeatures(_ on: Bool) {
        let before = AppSettings.shared.experimentalFeatures
        AppSettings.shared.experimentalFeatures = on
        addTeardownBlock { @MainActor in AppSettings.shared.experimentalFeatures = before }
    }

    /// What the app shows for `key` in `language` ("en", "de"), whatever language the tests run
    /// in. Like `String(localized:)`: the entry of the string catalog, or else `defaultValue`,
    /// or else the key itself. (The English table holds no entry for a key taken from the code:
    /// English comes from the code.)
    func appText(_ key: String, defaultValue: String? = nil, in language: String) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "no \(language).lproj in the app")
        let bundle = try XCTUnwrap(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: defaultValue ?? key, table: nil)
    }
}
