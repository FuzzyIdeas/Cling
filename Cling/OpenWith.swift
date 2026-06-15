import Defaults
import Lowtech
import SwiftUI
import System

// MARK: - OpenWithMenuView

struct OpenWithMenuView: View {
    let fileURLs: [URL]
    @Default(.toolbarLabelStyle) private var labelStyle

    var body: some View {
        Menu {
            let apps = commonApplications(for: fileURLs).sorted(by: \.lastPathComponent)
            ForEach(apps, id: \.path) { app in
                Button(action: {
                    NSWorkspace.shared.open(
                        fileURLs, withApplicationAt: app, configuration: .init(),
                        completionHandler: { _, _ in }
                    )
                }) {
                    SwiftUI.Image(nsImage: icon(for: app))
                    Text(app.lastPathComponent.ns.deletingPathExtension)
                }
            }
        } label: {
            switch labelStyle {
            case .iconAndText: Label("Open With", systemImage: "square.and.arrow.up.on.square")
            case .textOnly:    Text("Open With")
            case .iconOnly:    Image(systemName: "square.and.arrow.up.on.square")
            }
        }
        .help("Open the selected files with a specific app")
        .fixedSize()
    }

}

// MARK: - OpenWithPickerView

struct OpenWithPickerView: View {
    let fileURLs: [URL]
    @Environment(\.dismiss) var dismiss
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var filterText = ""

    private var apps: [URL] {
        if filterText.isEmpty {
            return fuzzy.commonOpenWithApps
        }
        let query = filterText.lowercased()
        return fuzzy.installedApps
            .compactMap { url -> (URL, Int)? in
                let name = url.lastPathComponent.ns.deletingPathExtension.lowercased()
                guard let score = fuzzyMatchScore(query: query, target: name) else { return nil }
                return (url, score)
            }
            .sorted(by: { $0.1 > $1.1 })
            .map(\.0)
    }

    func openWithApp(_ app: URL) {
        RH.trackRun(fileURLs.compactMap(\.existingFilePath))
        NSWorkspace.shared.open(
            fileURLs, withApplicationAt: app, configuration: .init(),
            completionHandler: { _, _ in }
        )
        dismiss()
    }

    func appButton(_ app: URL) -> some View {
        Button(action: { openWithApp(app) }) {
            HStack(spacing: 8) {
                SwiftUI.Image(nsImage: icon(for: app))
                Text(app.lastPathComponent.ns.deletingPathExtension)
            }
            .padding(.leading, 4)
            .padding(.trailing, 24)
            .padding(.vertical, 6)
            .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            TextField("Filter apps...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300)
                .onSubmit {
                    if let first = apps.first {
                        openWithApp(first)
                    }
                }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(apps, id: \.path) { app in
                        appButton(app)
                            .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
                    }.focusable(false)
                }
            }
        }
        .padding(18)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: 500)
    }
}

// MARK: - OpenWithActionButtons

struct OpenWithActionButtons: View {
    let selectedResults: Set<FilePath>

    @State private var fuzzy: FuzzyClient = FUZZY
    @ObservedObject private var km = KM
    @Default(.toolbarLabelStyle) private var labelStyle
    @Default(.toolbarDensity) private var density
    @State private var hintsVisible = false

    /// ⌘⌥ held: the prefix of every open-with app shortcut, so its hints reveal on hold.
    private var cmdOptHeld: Bool { (km.lcmd || km.rcmd) && (km.lalt || km.ralt) }

    var buttons: some View {
        ForEach(fuzzy.openWithAppShortcuts.sorted(by: \.key.lastPathComponent), id: \.0.path) { app, key in
            ActionPillButton(
                title: app.lastPathComponent.ns.deletingPathExtension,
                icon: .image(icon(for: app)),
                shortcut: "⌘⌥\(key.uppercased())",
                badgesVisible: hintsVisible,
                labelStyle: labelStyle
            ) {
                RH.trackRun(selectedResults)
                NSWorkspace.shared.open(selectedResults.map(\.url), withApplicationAt: app, configuration: .init(), completionHandler: { _, _ in })
            }
        }
    }

    var body: some View {
        HStack(spacing: density.spacing) {
            OpenWithMenuView(fileURLs: selectedResults.map(\.url))
                .disabled(selectedResults.isEmpty || fuzzy.openWithAppShortcuts.isEmpty)

            Divider().frame(height: 16)

            if fuzzy.openWithAppShortcuts.isEmpty {
                Text("Open with app hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: density.fontSize))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: density.spacing) { buttons }
                }
                Divider().frame(height: 16)
                ShareButton(urls: selectedResults.map(\.url))
                    .bold()
            }
        }
        .font(.system(size: density.fontSize))
        .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
        .revealShortcutHints(held: cmdOptHeld, visible: $hintsVisible)
    }

}

func icon(for app: URL) -> NSImage {
    if let cached = FUZZY.appIconCache[app.path] {
        return cached
    }
    let thumb = appIconThumbnail(forFile: app.path)
    FUZZY.appIconCache[app.path] = thumb
    return thumb
}

/// Renders a small, memory-light thumbnail of a file/app icon. `NSWorkspace.icon(forFile:)` returns
/// an image backed by several large representations (up to 512×512); drawing it once into a points
/// sized bitmap at screen scale keeps it crisp while caching only a few KB per icon. Uses an
/// offscreen bitmap context (not `lockFocus`) so it is safe to call off the main thread.
func appIconThumbnail(forFile path: String, points: CGFloat = 18, scale: CGFloat = 2) -> NSImage {
    let raw = NSWorkspace.shared.icon(forFile: path)
    let pixels = max(1, Int((points * scale).rounded()))
    let size = NSSize(width: points, height: points)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        raw.size = size
        return raw
    }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        raw.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        ctx.flushGraphics()
    }
    NSGraphicsContext.restoreGraphicsState()
    let thumb = NSImage(size: size)
    thumb.addRepresentation(rep)
    return thumb
}

extension URL {
    var bundleIdentifier: String? {
        guard let bundle = Bundle(url: self) else {
            return nil
        }
        return bundle.bundleIdentifier
    }
}

/// Returns a score for how well `query` fuzzy-matches `target`, or nil if no match.
/// Higher scores indicate better matches. Rewards consecutive and first-character matches.
/// Penalizes matches that span across word boundaries (spaces/hyphens).
func fuzzyMatchScore(query: String, target: String) -> Int? {
    var score = 0
    var consecutive = 0
    var lastMatchIdx = -1
    let targetChars = Array(target)

    var ti = 0
    for qChar in query {
        var found = false
        while ti < targetChars.count {
            if targetChars[ti] == qChar {
                if ti == 0 {
                    score += 10
                } else if targetChars[ti - 1] == " " || targetChars[ti - 1] == "-" {
                    score += 3
                }

                consecutive += 1
                score += consecutive

                if lastMatchIdx >= 0, lastMatchIdx + 1 != ti {
                    for gi in (lastMatchIdx + 1) ..< ti where targetChars[gi] == " " || targetChars[gi] == "-" {
                        score -= 4
                        break
                    }
                }

                lastMatchIdx = ti
                ti += 1
                found = true
                break
            }
            consecutive = 0
            ti += 1
        }
        if !found { return nil }
    }

    return score
}
