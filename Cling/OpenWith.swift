import Defaults
import Lowtech
import SwiftUI
import System

// MARK: - OpenWithMenuView

struct OpenWithMenuView: View {
    let fileURLs: [URL]
    var hintVisible = false

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
            Group {
                switch labelStyle {
                case .iconAndText: Label("Open With", systemImage: "square.and.arrow.up.on.square")
                case .textOnly: Text("Open With")
                case .iconOnly: Image(systemName: "square.and.arrow.up.on.square")
                }
            }
            .shortcutPrefix("⌘O", visible: hintVisible, color: ShortcutTint.apps)
        }
        .help("Open the selected files with a specific app (⌘O)")
        .menuIndicator(labelStyle == .iconOnly ? .hidden : .visible)
        .fixedSize()
        .frame(minWidth: ActionRowLayout.leadingWidth(for: labelStyle, density: density), alignment: .leading)
    }

    @Default(.toolbarLabelStyle) private var labelStyle
    @Default(.toolbarDensity) private var density

}

// MARK: - OpenWithGroupRequest

/// A set of apps to scope the Open With picker to (e.g. every app whose name starts with the
/// pressed letter), plus the files to open.
struct OpenWithGroupRequest: Identifiable {
    let id = UUID()
    let apps: [URL]
    let files: [URL]
}

// MARK: - OpenWithPickerView

struct OpenWithPickerView: View {
    let fileURLs: [URL]
    /// When set, the unfiltered list shows these apps (a shared-letter group) instead of all common
    /// apps; typing still searches every installed app.
    var initialApps: [URL]?

    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            TextField("Filter apps...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300)
                .focused($filterFocused)
                .onSubmit {
                    if let first = apps.first {
                        openWithApp(first)
                    }
                }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(apps.enumerated()), id: \.element.path) { index, app in
                        // First nine rows get a 1–9 quick-select key.
                        appButton(app, number: index < 9 ? index + 1 : nil)
                            .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
                    }.focusable(false)
                }
            }
        }
        .padding(18)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: 500)
        .onAppear { filterFocused = true; installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    func appButton(_ app: URL, number: Int?) -> some View {
        Button(action: { openWithApp(app) }) {
            HStack(spacing: 8) {
                numberBadge(number)
                SwiftUI.Image(nsImage: icon(for: app))
                Text(app.lastPathComponent.ns.deletingPathExtension)
            }
            .padding(.leading, 4)
            .padding(.trailing, 24)
            .padding(.vertical, 6)
            .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
        }
    }

    func openWithApp(_ app: URL) {
        RH.trackRun(fileURLs.compactMap(\.existingFilePath))
        NSWorkspace.shared.open(
            fileURLs, withApplicationAt: app, configuration: .init(),
            completionHandler: { _, _ in }
        )
        dismiss()
    }

    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var filterText = ""
    @State private var keyMonitor: Any?
    @FocusState private var filterFocused: Bool

    private var apps: [URL] {
        matchedApps(filterText)
    }

    @ViewBuilder
    private func numberBadge(_ number: Int?) -> some View {
        if let number {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 17, height: 17)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Color.clear.frame(width: 17, height: 17)
        }
    }

    private func matchedApps(_ filter: String) -> [URL] {
        if filter.isEmpty {
            return initialApps ?? fuzzy.commonOpenWithApps
        }
        let query = filter.lowercased()
        return fuzzy.installedApps
            .compactMap { url -> (URL, Int)? in
                let name = url.lastPathComponent.ns.deletingPathExtension.lowercased()
                guard let score = fuzzyMatchScore(query: query, target: name) else { return nil }
                return (url, score)
            }
            .sorted(by: { $0.1 > $1.1 })
            .map(\.0)
    }

    /// Captures bare 1–9 to open that row; letters and everything else keep flowing to the filter
    /// field. Runs as a local monitor (before the field) and reads the live filter via a binding.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let filterB = $filterText
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1 ... 9).contains(digit)
            else { return event }
            let list = matchedApps(filterB.wrappedValue)
            guard digit <= list.count else { return event }
            openWithApp(list[digit - 1])
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - OpenWithActionButtons

struct OpenWithActionButtons: View {
    let selectedResults: Set<FilePath>

    var buttons: some View {
        ForEach(appGroups, id: \.letter) { group in
            if group.apps.count == 1, let app = group.apps.first {
                appPill(app, letter: group.letter)
            } else if pillHintsVisible {
                // ⌘⌥ held: collapse the shared-letter apps into one pill so the key shows once.
                groupedPill(letter: group.letter, apps: group.apps)
            } else {
                ForEach(group.apps, id: \.path) { app in
                    appPill(app, letter: nil)
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: density.spacing) {
            OpenWithMenuView(fileURLs: selectedResults.map(\.url), hintVisible: comboHintVisible)
                .disabled(selectedResults.isEmpty || fuzzy.openWithAppShortcuts.isEmpty)

            Divider().frame(height: 16)

            if fuzzy.openWithAppShortcuts.isEmpty {
                Text("Open with app hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: density.fontSize))
            } else {
                if comboHintVisible {
                    ModifierComboHint(secondary: "⌥", secondaryHeld: optHeld, tint: ShortcutTint.apps)
                        .transition(.opacity)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: density.spacing) { buttons }
                        .padding(.vertical, ActionRowLayout.badgeClearance)
                        .padding(.trailing, 6)
                }
                Divider().frame(height: 16)
                ShareButton(urls: selectedResults.map(\.url))
                    .bold()
            }
        }
        .font(.system(size: density.fontSize))
        .buttonStyle(.text(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
        .revealShortcutHints(held: cmdHeld, visible: $comboHintVisible)
        .revealShortcutHints(held: cmdOptHeld, visible: $pillHintsVisible, instant: comboHintVisible)
    }

    @State private var fuzzy: FuzzyClient = FUZZY
    @ObservedObject private var km = KM
    @State private var comboHintVisible = false
    @State private var pillHintsVisible = false

    @Default(.toolbarLabelStyle) private var labelStyle
    @Default(.toolbarDensity) private var density

    /// ⌘ held: surfaces the "⌘ + ⌥" discoverability hint and the leading button's ⌘O, without
    /// flooding the row with every app's badge.
    private var cmdHeld: Bool {
        km.lcmd || km.rcmd
    }
    /// ⌥ held alongside ⌘: the actual combo for the app pills, so their ⌘⌥<key> badges reveal.
    private var optHeld: Bool {
        km.lalt || km.ralt
    }
    private var cmdOptHeld: Bool {
        cmdHeld && optHeld
    }

    /// Apps grouped by their first-letter shortcut, ordered by name.
    private var appGroups: [(letter: Character, apps: [URL])] {
        Dictionary(grouping: fuzzy.openWithAppShortcuts.keys, by: { fuzzy.openWithAppShortcuts[$0]! })
            .map { (letter: $0.key, apps: $0.value.sorted(by: \.lastPathComponent)) }
            .sorted { ($0.apps.first?.lastPathComponent ?? "") < ($1.apps.first?.lastPathComponent ?? "") }
    }

    private func appPill(_ app: URL, letter: Character?) -> some View {
        ActionPillButton(
            title: app.lastPathComponent.ns.deletingPathExtension,
            icon: .image(icon(for: app)),
            shortcut: letter.map { String($0).uppercased() } ?? "",
            badgesVisible: pillHintsVisible,
            labelStyle: labelStyle,
            hintColor: ShortcutTint.apps
        ) { openApp(app) }
    }

    @ViewBuilder
    private func appGlyph(_ app: URL) -> some View {
        switch labelStyle {
        case .iconAndText:
            HStack(spacing: 4) {
                SwiftUI.Image(nsImage: icon(for: app)).resizable().interpolation(.high).frame(width: 14, height: 14)
                Text(app.lastPathComponent.ns.deletingPathExtension)
            }
        case .textOnly:
            Text(app.lastPathComponent.ns.deletingPathExtension)
        case .iconOnly:
            SwiftUI.Image(nsImage: icon(for: app)).resizable().interpolation(.high).frame(width: 14, height: 14)
        }
    }

    /// One pill holding the shared key and every app for that letter, divided. Tapping it opens the
    /// Open With picker scoped to the group (same as pressing ⌘⌥<letter>).
    private func groupedPill(letter: Character, apps: [URL]) -> some View {
        Button {
            fuzzy.openWithGroupRequest = OpenWithGroupRequest(apps: apps, files: selectedResults.map(\.url))
        } label: {
            HStack(spacing: 6) {
                Text(String(letter).uppercased())
                    .fontWeight(.semibold)
                    .monospaced()
                    .foregroundStyle(ShortcutTint.apps)
                ForEach(Array(apps.enumerated()), id: \.element.path) { index, app in
                    Divider().frame(height: 12)
                    appGlyph(app)
                }
            }
        }
        .help("Open with: \(apps.map(\.lastPathComponent.ns.deletingPathExtension).joined(separator: ", "))")
    }

    private func openApp(_ app: URL) {
        RH.trackRun(selectedResults)
        NSWorkspace.shared.open(selectedResults.map(\.url), withApplicationAt: app, configuration: .init(), completionHandler: { _, _ in })
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
