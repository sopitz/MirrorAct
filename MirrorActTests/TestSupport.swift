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
}
