//
//  FilterDiscovery.swift
//  Cling
//
//  What the toolbar rows show before there is anything to act on. With no query typed and nothing
//  selected the action rows have no subject, so the space goes to the filters instead: the feature
//  most worth finding, and the one least likely to be found by pressing keys at random.
//

import Defaults
import Lowtech
import SwiftUI

// MARK: - KeyCap

/// One key drawn as a key, so a hotkey reads as something to press rather than as punctuation.
struct KeyCap: View {
    let label: String
    /// Sized by the caller: a cap marking an icon sits below it in the hierarchy, which means below
    /// it in size too.
    var size: CGFloat = 9.5
    /// Raised under the pointer, or while the modifier is down. The cap is always legible; this
    /// only decides how much it asks for.
    var prominent = false

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            // Wide enough for the modifier and its letter, tall as a single cap: one key with two
            // glyphs on it, the way a real modifier-marked key is printed.
            .frame(minWidth: size + 5, minHeight: size + 5)
            .padding(.horizontal, 3)
            // The ink carries the change, not the container. A filled chip outweighs the name above
            // it however small the type is, so the fill stays almost nothing at either state and the
            // text is what comes forward.
            .foregroundStyle(.primary.opacity(prominent ? 0.85 : 0.5))
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.primary.opacity(prominent ? 0.26 : 0.13), lineWidth: 0.5)
            )
    }
}

// MARK: - FilterCard

// One filter as an icon carrying its own shortcut: a rounded square washed in the filter's colour,
// the symbol drawn opaque in that colour on top, and the hotkey hung off the corner as a keycap so
// it matches the keys used everywhere else in the window.

struct FilterCard: View {
    let name: String
    let icon: String
    let color: FilterColor
    let key: Character?
    /// Whether the shortcut caps have arrived yet. See `FilterDiscoveryPanel`.
    let revealed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.opacity(fillOpacity))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accent.opacity(hovering ? 0.45 : 0), lineWidth: 1)
                    )
                    // Hung off the icon's corner rather than sat under the name: the cap marks the
                    // icon, so it stays out of the name's column and off its baseline.
                    .overlay(alignment: .topTrailing) {
                        // Holding Option always shows its own letters, whatever the timer says.
                        if let key, revealed || optionHeld {
                            KeyCap(
                                label: "⌥\(String(key).uppercased())",
                                size: Self.capSize,
                                prominent: hovering || optionHeld
                            )
                            .offset(x: 9, y: -5)
                            .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .topTrailing)))
                        }
                    }
                caption
            }
            .frame(width: 76)
            .padding(.top, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: optionHeld)
    }

    private static let capSize: CGFloat = 8

    @State private var hovering = false
    @ObservedObject private var km = KM
    @Environment(\.colorScheme) private var colorScheme

    /// The wash deepens under the pointer, so the card answers before it is clicked.
    private var fillOpacity: Double {
        let base = dark ? 0.20 : 0.13
        return hovering ? base + 0.12 : base
    }

    private var optionHeld: Bool {
        km.lalt || km.ralt
    }

    private var dark: Bool {
        colorScheme == .dark
    }
    private var accent: Color {
        color.accent(dark: dark)
    }

    /// Small caps: the name reads as a label for the thing rather than as prose, which is what a
    /// word repeating along a row wants to be.
    private var caption: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold).smallCaps())
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

}

// MARK: - FilterDiscoveryPanel

/// The shortcut caps are a teaching aid, not chrome. They arrive a few seconds into the first window
/// of the session, once the eye has settled on the icons, and stay from then on.
@MainActor private var filterKeysRevealed = false

// MARK: - FilterDiscoveryPanel

/// The two kinds of filter, side by side: a search window is far wider than it is tall here, so
/// stacking them would push the second kind off the bottom.
struct FilterDiscoveryPanel: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Quick filters take whatever is left over, because there are twice as many of them.
            column(title: "Search only", cards: quickCards)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().frame(maxHeight: 90)
            column(title: "Search inside", cards: folderCards)
                .frame(maxWidth: folderColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .task {
            guard !revealed else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            filterKeysRevealed = true
            withAnimation(.easeOut(duration: 0.16)) { revealed = true }
        }
    }

    @State private var defaults = DEFAULTS_CACHE
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var wm = WM
    @State private var revealed = filterKeysRevealed

    @Default(.toolbarRowBackground) private var toolbarRowBackground

    /// Puts the divider on the seam between the results table and the file preview, so the bottom
    /// row repeats a split the window already draws above it at any size. The inset is the padding
    /// stacked between this HStack and the table's (this panel's own 4, plus the row background's 10
    /// when it is on), the 14 of column spacing and half the divider, less half the 10pt gutter the
    /// table leaves for the preview, since the divider lands in the middle of that gutter.
    private var folderColumnWidth: CGFloat {
        let inset = 4 + (toolbarRowBackground ? 10.0 : 0) + 14 + 0.5 - 5
        return max(WindowManager.previewWidth(forWindowWidth: wm.size.width) - inset, 160)
    }

    private var quickCards: some View {
        ForEach(defaults.quickFilters, id: \.uuid) { filter in
            FilterCard(
                name: filter.id,
                icon: filter.icon ?? "line.3.horizontal.decrease.circle.fill",
                color: filter.color ?? .forName(filter.id),
                key: filter.key,
                revealed: revealed
            ) {
                fuzzy.quickFilter = filter
            }
        }
    }

    private var folderCards: some View {
        ForEach(defaults.folderFilters, id: \.uuid) { filter in
            FilterCard(
                name: filter.id,
                icon: filter.icon ?? "folder.fill",
                color: filter.color ?? .forName(filter.id),
                key: filter.key,
                revealed: revealed
            ) {
                fuzzy.folderFilter = filter
            }
        }
    }

    private func column(title: String, cards: some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded).smallCaps())
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) { cards }
                    .padding(.bottom, 2)
            }
        }
    }

}
