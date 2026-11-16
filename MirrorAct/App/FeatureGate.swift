// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the app shows of the functions that are still being tried out, for the setting
/// "Experimental features" (`AppSettings.experimentalFeatures`). With the setting off the app
/// shows none of them, and none of their ways in does anything.
///
/// The tool rail, the Device menu, the mirror window's context menu, the settings window and
/// the mirror session ask this one type. Another experimental function gets a case in `Feature`
/// and its items below; where it shows, the app asks for them.
struct FeatureGate: Equatable {
    /// the setting "Experimental features"
    let experimental: Bool

    /// The functions behind the setting
    enum Feature: CaseIterable {
        /// "Text" and "Translate": copy and translate the text on the mirrored screen
        case textOnScreen
    }

    /// The tool rail's buttons that depend on the setting, in the rail's order
    enum RailItem: CaseIterable {
        case copyText, translate
    }

    /// The items of the Device menu and of the mirror window's context menu that depend on the
    /// setting, in the menus' order
    enum MenuItem: CaseIterable {
        /// "Copy Text on Screen" (⌥⌘T)
        case copyText
        /// "Translate Text on Screen" (⇧⌘T)
        case translate
    }

    /// The tabs of the settings window; the raw value is what `settingsTab` stores
    enum SettingsTab: String, CaseIterable {
        case general, design, text
    }

    /// Whether `feature` is there: every function in `Feature` is experimental
    func allows(_ feature: Feature) -> Bool {
        switch feature {
        case .textOnScreen: return experimental
        }
    }

    var railItems: [RailItem] {
        allows(.textOnScreen) ? [.copyText, .translate] : []
    }

    var menuItems: [MenuItem] {
        allows(.textOnScreen) ? [.copyText, .translate] : []
    }

    var settingsTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            switch tab {
            case .general, .design: return true
            case .text: return allows(.textOnScreen)
            }
        }
    }

    /// The tab the settings window shows for the stored selection: a tab that is not there (the
    /// Text tab with the setting off) or an unknown one falls back to General
    func settingsTab(forStored stored: String) -> SettingsTab {
        guard let tab = SettingsTab(rawValue: stored), settingsTabs.contains(tab) else { return .general }
        return tab
    }
}
