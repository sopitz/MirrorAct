// SPDX-License-Identifier: GPL-3.0-or-later
@testable import MirrorAct

/// QuickDraw, which the tests see through Foundation and Core Graphics, has a type of the same
/// name, so `RGBColor` alone is ambiguous in the test bundle. A name of the test bundle itself
/// comes before the imported ones.
typealias RGBColor = MirrorAct.RGBColor
