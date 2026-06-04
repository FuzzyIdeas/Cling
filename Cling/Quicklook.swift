import Foundation
import Lowtech
import SwiftUI

/// Drives the system Quick Look panel through SwiftUI's `.quickLookPreview(_:in:)`
/// modifier. Setting `selection` shows the floating, fully interactive Quick Look
/// window; the user dismissing it sets `selection` back to nil.
@MainActor @Observable
final class QuickLookPresenter {
    static let shared = QuickLookPresenter()

    /// The currently previewed URL (bound to `.quickLookPreview`).
    var selection: URL?
    /// The set the panel can arrow through.
    var items: [URL] = []

    var isVisible: Bool { selection != nil }

    func present(urls: [URL], selectedItemIndex: Int = 0) {
        guard !urls.isEmpty else { return }
        items = urls
        selection = urls[safe: selectedItemIndex] ?? urls.first
    }

    func close() {
        selection = nil
    }
}

@MainActor let QLP = QuickLookPresenter.shared
