// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MirrorAct

final class LogTests: XCTestCase {
    /// The tests drive translation services through scripted failures, which are logged. They
    /// must not land in the log file users read.
    func testTestsDoNotWriteIntoTheLogFileOfTheUser() {
        XCTAssertTrue(AppDelegate.isTesting)
        XCTAssertNil(Log.fileURL)
        Log.error("Translation: a failure of a test")
    }
}
