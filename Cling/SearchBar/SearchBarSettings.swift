//
//  SearchBarSettings.swift
//  Cling
//
//  Settings and stored state for the floating search bar.
//

import Defaults
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

extension Defaults.Keys {
    /// The bar for new installs. Installs from before it became the default keep the window, see `Migration.migrateV4`.
    static let hotkeyTarget = Key<HotkeyTarget>("hotkeyTarget", default: .searchBar)
    /// The bar's own default results: with `.empty` it opens as a lone field, like Spotlight.
    static let searchBarDefaultResults = Key<DefaultResultsMode>("searchBarDefaultResults", default: .empty)
    /// The compact field stays on screen while the bar is collapsed.
    static let searchBarPinned = Key<Bool>("searchBarPinned", default: false)
    /// Floating level for the compact field; off puts it on the desktop, under every window.
    static let searchBarAboveWindows = Key<Bool>("searchBarAboveWindows", default: true)
    /// Bottom-left corner of the compact field in global screen coordinates, empty until it is first dragged.
    static let searchBarPillOrigin = Key<[Double]>("searchBarPillOrigin", default: [])
    static let searchBarShowPreview = Key<Bool>("searchBarShowPreview", default: true)
    /// Result paths start with their folder's icon, in the rows and the preview's header. Off, they're plain text.
    static let searchBarFolderIcons = Key<Bool>("searchBarFolderIcons", default: true)
    /// Width and height of the expanded bar, empty for the default.
    static let searchBarSize = Key<[Double]>("searchBarSize", default: [])
    /// Where the unpinned bar sits, as fractions of its display's usable area: centre x and top edge.
    static let searchBarPosition = Key<[Double]>("searchBarPosition", default: [])
}
