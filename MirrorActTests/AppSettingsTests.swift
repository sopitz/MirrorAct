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

    /// What the test host registers to run when the test run ends: nothing the tests stored
    /// stays behind, the code and the device ID least of all. The test catches the registration
    /// instead of exiting, so it shows that the store registers it and what it does, not that
    /// the process runs it on exit.
    func testTheTestsSettingsAreEmptiedAtTheEnd() throws {
        // the settings are made, and with them the code and the device ID
        _ = AppSettings.shared
        let suiteName = try XCTUnwrap(AppSettings.testSuiteName)
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let stored = try XCTUnwrap(suite.persistentDomain(forName: suiteName))
        defer { suite.setPersistentDomain(stored, forName: suiteName) }
        XCTAssertNotNil(suite.string(forKey: "pin"))

        var atExit: [@convention(c) () -> Void] = []
        _ = AppSettings.makeDefaults(atExit: { atExit.append($0) })
        XCTAssertEqual(atExit.count, 1)
        // making the store empties the domain as well; what is to be emptied at the end is put back
        suite.setPersistentDomain(stored, forName: suiteName)
        XCTAssertNotNil(suite.string(forKey: "pin"))

        atExit.forEach { $0() }
        XCTAssertTrue((suite.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
        XCTAssertNil(suite.string(forKey: "pin"))
        XCTAssertNil(suite.string(forKey: "receiverDeviceID"))
    }
}
