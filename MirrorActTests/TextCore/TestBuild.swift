// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How much of their settings the tracker's long tests play. `scripts/test.sh` tests a debug
/// build, fifty to a hundred times slower at tracking than a release build, before every commit:
/// there a long test plays a part of its settings, chosen so that it still fails without the rule
/// it guards. Everything plays in a release build and with `TRACKING_ALL=1` (as
/// `TrackingBenchTests`).
enum TestBuild {
    /// all settings of the long tests
    static var playsEverything: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TRACKING_ALL"] == "1"
        #else
        return true
        #endif
    }
}
