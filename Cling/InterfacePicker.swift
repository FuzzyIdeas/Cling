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
        guard let screen = NSScreen.screens.first, var url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        #if SEARCHBAR_BENCH
            if let path = UserDefaults.standard.string(forKey: "searchBarShowcaseWallpaper") {
                url = URL(fileURLWithPath: path)
            }
        #endif
        guard url != loadedURL else { return }
        loadedURL = url
        Task.detached(priority: .userInitiated) {
            let image = Self.thumbnail(of: url)
            await MainActor.run { self.image = image }
        }
    }

    private var loadedURL: URL?

    /// Nil for a file that is gone (macOS keeps showing a deleted wallpaper) or isn't a still image.
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

/// The search window, centred as it opens by default.
private struct MiniWindow: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.74
            let h = geo.size.height * 0.72
            let row = h * 0.105
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: row * 0.25) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in
                        Circle().fill(color.opacity(0.85)).frame(width: row * 0.32, height: row * 0.32)
                    }
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: row * 0.45, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, row * 0.4)
                    Capsule().fill(.primary.opacity(0.2)).frame(width: w * 0.24, height: max(row * 0.16, 1.5))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, row * 0.4)
                .frame(height: row * 1.3)
                ForEach(Array(miniFiles.prefix(5).enumerated()), id: \.offset) { i, file in
                    MiniRow(file: file, width: w, height: row, highlighted: i == 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: row * 0.25) {
                    ForEach(0 ..< 5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: row * 0.12).fill(.primary.opacity(0.12)).frame(width: w * 0.11, height: row * 0.42)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, row * 0.4)
                .padding(.bottom, row * 0.4)
            }
            .frame(width: w, height: h)
            .background { WindowBackground() }
            .clipShape(RoundedRectangle(cornerRadius: row * 0.7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: row * 0.7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: row * 0.5, y: row * 0.2)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

// MARK: - MiniBar

/// The search bar at Spotlight's spot: only its field, or the field over a short list when it shows recent files or
/// the run history before typing.
private struct MiniBar: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.62
            let row = geo.size.height * 0.075
            let field = row * 1.35
            let listRows = beforeTyping == .fieldOnly ? 0 : 4
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
            .animation(.easeOut(duration: 0.2), value: beforeTyping)
        }
    }

    @Default(.searchBarBeforeTyping) private var beforeTyping
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
