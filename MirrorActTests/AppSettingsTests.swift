// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MirrorAct

/// The settings store while the app runs as the test host
@MainActor
final class AppSettingsTests: XCTestCase {
    /// Whatever a test changes ends up in a domain of the tests, never in the preferences of the
    /// installed app, which the test host shares its bundle identifier with
    func testTheTestsKeepTheirSettingsApartFromTheApp() throws {
        let settings = AppSettings.shared
        let suiteName = try XCTUnwrap(AppSettings.testSuiteName)
        XCTAssertNotEqual(suiteName, Bundle.main.bundleIdentifier)
        XCTAssertFalse(settings.defaults === UserDefaults.standard)

        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let language = settings.translationLanguage
        defer { settings.translationLanguage = language }
        settings.translationLanguage = "fr"
        XCTAssertEqual(suite.string(forKey: "translationLanguage"), "fr")
    }

    /// The code and the device ID are kept where the other settings are
    func testPinAndDeviceIDAreStoredWithTheOtherSettings() throws {
        let settings = AppSettings.shared
        let suite = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(AppSettings.testSuiteName)))
        XCTAssertEqual(suite.string(forKey: "pin"), settings.pin)
        XCTAssertEqual(suite.string(forKey: "receiverDeviceID"), settings.receiverDeviceID)
    }
}
