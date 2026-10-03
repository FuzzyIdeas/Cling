//
//  SearchBarSettings.swift
//  Cling
//
//  Settings and stored state for the floating search bar.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

// MARK: - HotkeyTarget

/// What the show/hide hotkey (and the Dock and menu bar icons) bring up.
enum HotkeyTarget: String, CaseIterable, Defaults.Serializable {
    case window
    case searchBar

    var label: String {
        switch self {
        case .window: "Search window"
        case .searchBar: "Search bar"
        }
    }
}

// MARK: - SearchBarBeforeTyping

/// What the bar shows while the query is empty.
enum SearchBarBeforeTyping: String, CaseIterable, Defaults.Serializable {
    case fieldOnly
    case recents
    case runHistory

    var label: String {
        switch self {
        case .fieldOnly: "Search field only"
        case .recents: "Recent files"
        case .runHistory: "Run history"
        }
    }
}

extension Defaults.Keys {
    static let hotkeyTarget = Key<HotkeyTarget>("hotkeyTarget", default: .window)
    static let searchBarBeforeTyping = Key<SearchBarBeforeTyping>("searchBarBeforeTyping", default: .fieldOnly)
    /// The compact field stays on screen while the bar is collapsed.
    static let searchBarPinned = Key<Bool>("searchBarPinned", default: false)
    /// Floating level for the compact field; off puts it on the desktop, under every window.
    static let searchBarAboveWindows = Key<Bool>("searchBarAboveWindows", default: true)
    /// Bottom-left corner of the compact field in global screen coordinates, empty until it is first dragged.
    static let searchBarPillOrigin = Key<[Double]>("searchBarPillOrigin", default: [])
    static let searchBarShowPreview = Key<Bool>("searchBarShowPreview", default: true)
    /// Width and height of the expanded bar, empty for the default.
    static let searchBarSize = Key<[Double]>("searchBarSize", default: [])
    /// Where the unpinned bar sits, as fractions of its display's usable area: centre x and top edge.
    static let searchBarPosition = Key<[Double]>("searchBarPosition", default: [])
}

extension KeyboardShortcuts.Name {
    /// A real global hotkey, unlike the `cl_` action names which are dispatched window-locally.
    static let clSearchBar = Self("cl_searchBar")
}

// MARK: - SearchBarSettingsSection

/// Lives in Settings > General; the choice between the bar and the window is in Settings > Style. Labels only: what
/// each setting does shows up on screen the moment it is flipped.
struct SearchBarSettingsSection: View {
    var body: some View {
        Section("Search bar") {
            LabeledContent("Search bar hotkey") {
                ShortcutRecorder(name: .clSearchBar, label: "Search bar hotkey")
            }
            .labeledContentStyle(ShortcutRowStyle())

            Toggle("Pin to desktop", isOn: $pinned)
            if pinned {
                Toggle("Keep above windows", isOn: $aboveWindows)
            }
        }
    }

    @Default(.searchBarPinned) private var pinned
    @Default(.searchBarAboveWindows) private var aboveWindows
}
