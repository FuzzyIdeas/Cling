//
//  InterfacePicker.swift
//  Cling
//
//  Settings > Style: the choice between the search window and the search bar, as two previews over the
//  desktop's own wallpaper, drawn in the current window style so they double as a live preview of it.
//

import Defaults
import ImageIO
import SwiftUI

// MARK: - DesktopWallpaper

/// A small copy of the main display's wallpaper, read off the main thread once per Settings visit.
@MainActor @Observable
final class DesktopWallpaper {
    static let shared = DesktopWallpaper()

    private(set) var image: NSImage?

    func load() {
        var url = NSScreen.screens.first.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        #if SEARCHBAR_BENCH
            if let path = UserDefaults.standard.string(forKey: "searchBarShowcaseWallpaper") {
                url = URL(fileURLWithPath: path)
            }
        #endif
        guard image == nil || url != loadedURL else { return }
        loadedURL = url
        Task.detached(priority: .userInitiated) {
            let image = url.flatMap { Self.thumbnail(of: $0) } ?? Self.systemDefaults.lazy.compactMap { Self.thumbnail(of: URL(fileURLWithPath: $0)) }.first
            await MainActor.run { self.image = image }
        }
    }

    /// Pictures that ship with macOS, for when the wallpaper can't be read: the default aerial's still where the
    /// system has one, then a release's own picture.
    private nonisolated static let systemDefaults = [
        "/System/Library/Wallpapers/.default/DefaultAerial.heic",
        "/System/Library/Wallpapers/.default/DefaultAerial.jpg",
        "/System/Library/Desktop Pictures/Sonoma.heic",
        "/System/Library/Desktop Pictures/Ventura Graphic.madesktop",
        "/System/Library/Desktop Pictures/Monterey Graphic.madesktop",
    ]

    private var loadedURL: URL?

    /// Nil for a file that is gone (macOS keeps showing a deleted wallpaper) or isn't a still image, like an aerial's
    /// video.
    private nonisolated static func thumbnail(of url: URL) -> NSImage? {
        var url = url
        // The system wallpapers are .madesktop plists that point at a downloaded asset and a preview of it.
        if url.pathExtension == "madesktop" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let path = plist["thumbnailPath"] as? String
            else { return nil }
            url = URL(fileURLWithPath: path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

}

// MARK: - InterfacePicker

struct InterfacePicker: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(HotkeyTarget.allCases, id: \.self) { target in
                InterfaceTile(target: target, selected: hotkeyTarget == target) {
                    hotkeyTarget = target
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { DesktopWallpaper.shared.load() }
    }

    @Default(.hotkeyTarget) private var hotkeyTarget
}

// MARK: - InterfaceTile

private struct InterfaceTile: View {
    let target: HotkeyTarget
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    wallpaper
                    switch target {
                    case .window: MiniWindow()
                    case .searchBar: MiniBar()
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // The one not picked steps back: dimmer and nearly grey.
                .saturation(selected ? 1 : 0.15)
                .opacity(selected ? 1 : 0.55)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                }
                Text(target.label)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(target.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    @ViewBuilder private var wallpaper: some View {
        if let image = DesktopWallpaper.shared.image {
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            LinearGradient(colors: [Color(hue: 0.6, saturation: 0.5, brightness: 0.75), Color(hue: 0.8, saturation: 0.45, brightness: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Miniatures

/// Stand-ins for files in the miniatures: a few icon colours and name lengths, so the rows read as a list of files.
private let miniFiles: [(symbol: String, color: Color, name: CGFloat, path: CGFloat)] = [
    ("folder.fill", .blue, 0.22, 0.46),
    ("swift", .orange, 0.3, 0.38),
    ("doc.text.fill", .gray, 0.26, 0.5),
    ("photo.fill", .teal, 0.18, 0.42),
    ("folder.fill", .blue, 0.24, 0.34),
    ("doc.richtext.fill", .indigo, 0.32, 0.44),
]

// MARK: - MiniRow

private struct MiniRow: View {
    let file: (symbol: String, color: Color, name: CGFloat, path: CGFloat)
    let width: CGFloat
    let height: CGFloat
    let highlighted: Bool

    var body: some View {
        HStack(spacing: height * 0.3) {
            Image(systemName: file.symbol)
                .font(.system(size: height * 0.55))
                .foregroundStyle(file.color)
                .frame(width: height * 0.7)
            VStack(alignment: .leading, spacing: height * 0.14) {
                Capsule().fill(.primary.opacity(0.55)).frame(width: width * file.name, height: max(height * 0.16, 1.5))
                Capsule().fill(.primary.opacity(0.25)).frame(width: width * file.path, height: max(height * 0.12, 1))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, height * 0.35)
        .frame(height: height)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: height * 0.25, style: .continuous)
                    .fill(Color.accentColor.opacity(0.3))
                    .padding(.horizontal, height * 0.15)
            }
        }
    }
}

// MARK: - MiniWindow

/// The search window, centred as it opens by default: traffic lights, a thin search field, the results table under
/// its column headers, the action rows and the status bar.
private struct MiniWindow: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.8
            let h = geo.size.height * 0.8
            // The window laid out on a grid of 30 units down its height.
            let unit = h / 30
            let inset = unit * 1.2
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: unit * 0.55) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in
                        Circle().fill(color.opacity(0.85)).frame(width: unit * 1.05, height: unit * 1.05)
                    }
                }
                .padding(.leading, inset)
                .frame(height: unit * 2.4)

                HStack(spacing: unit * 0.6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: unit * 0.9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Capsule().fill(.primary.opacity(0.22)).frame(width: w * 0.1, height: max(unit * 0.32, 1.2))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, unit * 0.7)
                .frame(height: unit * 1.9)
                .background(RoundedRectangle(cornerRadius: unit * 0.55, style: .continuous).fill(.primary.opacity(0.06)))
                .padding(.horizontal, inset)

                MiniTable(width: w - inset * 2, unit: unit, rows: defaultResults == .empty ? 0 : 9)
                    .padding(.horizontal, inset)
                    .padding(.top, unit)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: unit * 0.5) {
                    MiniButtons(widths: [0.06, 0.1, 0.06, 0.08, 0.11], unit: unit, total: w)
                    MiniButtons(widths: [0.08, 0.09, 0.06, 0.07, 0.08], unit: unit, total: w, tinted: true)
                }
                .padding(.horizontal, inset)

                HStack(spacing: unit * 0.8) {
                    Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 0.6).frame(width: unit * 0.8, height: unit * 0.8)
                    ForEach([0.12, 0.07, 0.06], id: \.self) { fraction in
                        Capsule().fill(.primary.opacity(0.18)).frame(width: w * fraction, height: max(unit * 0.28, 1))
                    }
                    Spacer(minLength: 0)
                    Capsule().fill(.primary.opacity(0.14)).frame(width: w * 0.14, height: max(unit * 0.28, 1))
                    Image(systemName: "gearshape")
                        .font(.system(size: unit * 0.8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, inset)
                .frame(height: unit * 2.2)
            }
            .frame(width: w, height: h)
            .background { WindowBackground() }
            .clipShape(RoundedRectangle(cornerRadius: unit * 1.6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: unit * 1.6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: unit * 1.2, y: unit * 0.5)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .animation(.easeOut(duration: 0.2), value: defaultResults)
        }
    }

    @Default(.defaultResultsMode) private var defaultResults
}

// MARK: - MiniTable

/// The window's results table: column headers with their dividers, then rows with a line under each.
private struct MiniTable: View {
    let width: CGFloat
    let unit: CGFloat
    let rows: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: width * Self.columns[0])
                ForEach(1 ..< Self.columns.count, id: \.self) { column in
                    HStack(spacing: unit * 0.5) {
                        Rectangle().fill(.primary.opacity(0.14)).frame(width: 0.5, height: unit * 0.9)
                        Capsule().fill(.primary.opacity(0.32)).frame(width: width * Self.columns[column] * 0.32, height: max(unit * 0.3, 1.2))
                        Spacer(minLength: 0)
                    }
                    .frame(width: width * Self.columns[column])
                }
            }
            .frame(height: unit * 1.7)
            Rectangle().fill(.primary.opacity(0.16)).frame(height: 0.5)
            ForEach(0 ..< rows, id: \.self) { row in
                let file = miniFiles[row % miniFiles.count]
                HStack(spacing: 0) {
                    Image(systemName: file.symbol)
                        .font(.system(size: unit * 0.85))
                        .foregroundStyle(file.color)
                        .frame(width: width * Self.columns[0])
                    cell(column: 1, fill: file.name * 2.6, opacity: 0.5)
                    cell(column: 2, fill: file.path * 1.6, opacity: 0.22)
                    cell(column: 3, fill: 0.45, opacity: 0.28)
                    cell(column: 4, fill: 0.75, opacity: 0.28)
                }
                .frame(height: unit * 1.5)
                .background(row == 0 ? Color.primary.opacity(0.09) : .clear)
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5)
            }
        }
    }

    /// Icon, name, path, size and date, as fractions of the table's width.
    private static let columns: [CGFloat] = [0.05, 0.22, 0.42, 0.12, 0.19]

    private func cell(column: Int, fill: CGFloat, opacity: Double) -> some View {
        HStack(spacing: 0) {
            Capsule().fill(.primary.opacity(opacity)).frame(width: width * Self.columns[column] * min(fill, 0.9), height: max(unit * 0.3, 1.2))
            Spacer(minLength: 0)
        }
        .padding(.leading, unit * 0.5)
        .frame(width: width * Self.columns[column])
    }
}

// MARK: - MiniButtons

/// A row of the window's action buttons; `tinted` gives them app colours, like the Open With row.
private struct MiniButtons: View {
    let widths: [CGFloat]
    let unit: CGFloat
    let total: CGFloat
    var tinted = false

    var body: some View {
        HStack(spacing: unit * 0.45) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, fraction in
                HStack(spacing: unit * 0.35) {
                    RoundedRectangle(cornerRadius: unit * 0.2)
                        .fill(tinted ? miniFiles[index % miniFiles.count].color.opacity(0.85) : Color.primary.opacity(0.35))
                        .frame(width: unit * 0.75, height: unit * 0.75)
                    Capsule().fill(.primary.opacity(0.3)).frame(width: total * fraction, height: max(unit * 0.28, 1.2))
                }
                .padding(.horizontal, unit * 0.5)
                .frame(height: unit * 1.55)
                .background(RoundedRectangle(cornerRadius: unit * 0.5, style: .continuous).fill(.primary.opacity(0.05)))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - MiniBar

/// The search bar at Spotlight's spot: only its field, or the field over a short list when its default results are
/// recent files or the run history.
private struct MiniBar: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.62
            let row = geo.size.height * 0.075
            let field = row * 1.35
            let listRows = defaultResults == .empty ? 0 : 4
            let h = field + (listRows > 0 ? CGFloat(listRows) * row + row * 1.1 : 0)
            let radius = SearchBarMetrics.modern ? min(field / 2, row * 0.75) : row * 0.4
            VStack(spacing: 0) {
                HStack(spacing: row * 0.3) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: row * 0.55))
                        .foregroundStyle(.secondary)
                    Text("Search files…")
                        .font(.system(size: row * 0.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ForEach(["asterisk", "arrow.up.arrow.down", "sidebar.right"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: row * 0.32, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: row * 0.62, height: row * 0.62)
                            .background(RoundedRectangle(cornerRadius: row * 0.18, style: .continuous).fill(.primary.opacity(0.06)))
                    }
                }
                .padding(.horizontal, row * 0.4)
                .frame(height: field)
                if listRows > 0 {
                    ForEach(Array(miniFiles.suffix(listRows).enumerated()), id: \.offset) { _, file in
                        MiniRow(file: file, width: w, height: row, highlighted: false)
                    }
                    Spacer(minLength: 0)
                    // The hint bar.
                    HStack(spacing: row * 0.3) {
                        ForEach(0 ..< 4, id: \.self) { _ in
                            HStack(spacing: row * 0.12) {
                                RoundedRectangle(cornerRadius: row * 0.08).fill(.primary.opacity(0.12)).frame(width: row * 0.32, height: row * 0.3)
                                Capsule().fill(.primary.opacity(0.18)).frame(width: w * 0.07, height: max(row * 0.1, 1))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, row * 0.45)
                    .padding(.bottom, row * 0.35)
                }
            }
            .frame(width: w, height: h)
            .background { MiniBarBackground() }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: row * 0.5, y: row * 0.2)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.18 + h / 2)
            .animation(.easeOut(duration: 0.2), value: defaultResults)
        }
    }

    @Default(.searchBarDefaultResults) private var defaultResults
}

// MARK: - MiniBarBackground

/// The bar's background in SwiftUI, with SearchBarBackgroundView's materials and tints.
private struct MiniBarBackground: View {
    var body: some View {
        switch appearance {
        case .glassy:
            if #available(macOS 26, *) {
                tint(light: 0.12, dark: 0.18).background(Color.clear.glassEffect(.regular, in: .rect))
            } else {
                tint(light: 0.1, dark: 0.15).background(.regularMaterial)
            }
        case .vibrant:
            tint(light: 0.1, dark: 0.15).background(.regularMaterial)
        case .opaque:
            Color(.windowBackgroundColor)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    @Default(.windowAppearance) private var appearance

    private func tint(light: Double, dark: Double) -> Color {
        colorScheme == .dark ? .black.opacity(dark) : .white.opacity(light)
    }
}
