//
//  Styles.swift
//  Cling
//
//  Created by Alin Panaitiu on 06.02.2025.
//

import Foundation
import KeyboardShortcuts
import Lowtech
import SwiftUI

/// One radius shared by the results table, the file preview panel and the action-row background so
/// their rounded corners read as nested inside the window. macOS doesn't expose the window's own
/// radius, and these panels sit only ~16pt in from the edge, so a true concentric inset (via
/// `ContainerRelativeShape`) would round to almost square; a single tuned value tracks the window
/// far better here. Tune this one number to taste.
let windowCornerRadius: CGFloat = 16

// MARK: - TextButtonContent

/// The rendered body shared by the text button styles. This is a real `View` (not the ButtonStyle
/// struct), so its `@State hovering` is actually installed and tracked by SwiftUI. The styles used
/// to call each other's `makeBody` by hand, which left that `@State` dead — the hover and press
/// feedback never updated. Hover/press now drive both the background fill and a subtle scale.
private struct TextButtonContent<Label: View>: View {
    enum Variant { case glass, vibrant, opaque }

    let label: Label
    let isPressed: Bool
    let variant: Variant
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    var body: some View {
        label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .contentShape(isSquare ? AnyShape(squareShape) : AnyShape(Capsule(style: .continuous)))
            .opacity(enabled ? (hovering ? 1 : 0.82) : 0.5)
            .background { fillBackground }
            .overlay { border }
            .scaleEffect(enabled && hovering ? 1.06 : 1)
            .onHover { hover in
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.14)) { hovering = hover }
            }
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var enabled: Bool {
        isEnabledOverride ?? isEnabled
    }

    /// Opaque pills are squarish (small radius); glass/vibrant are capsules.
    private var isSquare: Bool {
        variant == .opaque
    }
    private var squareShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
    }

    private var fillColor: Color {
        if active { return activeTint.opacity(0.22) }

        if variant == .glass {
            // A contrasting fill against the translucent window: whiter in light, blacker in dark,
            // getting more opaque on hover/press.
            let base = scheme == .dark ? Color.black : Color.white
            guard enabled else { return base.opacity(scheme == .dark ? 0.12 : 0.22) }
            if isPressed { return base.opacity(scheme == .dark ? 0.5 : 0.72) }
            if hovering { return base.opacity(scheme == .dark ? 0.4 : 0.6) }
            return base.opacity(scheme == .dark ? 0.28 : 0.45)
        }

        // Bordered variants rely on their stroke at rest, filling in only on hover/press.
        guard enabled else { return .clear }
        if isPressed { return .primary.opacity(0.18) }
        if hovering { return .primary.opacity(0.12) }
        return .clear
    }

    @ViewBuilder
    private var fillBackground: some View {
        if isSquare {
            squareShape.fill(fillColor)
        } else {
            Capsule(style: .continuous).fill(fillColor)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .glass:
            // A caller that opts out (e.g. the status bar passes `.clear`) wins; otherwise the glass
            // pills get a modern top-lit bevel edge that reads as a thin glass rim.
            if let borderColor {
                Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 0.5)
            } else {
                Capsule(style: .continuous).strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(scheme == .dark ? 0.30 : 0.65),
                            .black.opacity(scheme == .dark ? 0.04 : 0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
        case .vibrant:
            Capsule(style: .continuous).strokeBorder(borderColor ?? color, lineWidth: 0.5)
        case .opaque:
            squareShape.strokeBorder((borderColor ?? color).opacity(0.4), lineWidth: 1)
        }
    }

}

// MARK: - GlassTextButton

struct GlassTextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .glass, color: color, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

}

// MARK: - VibrantTextButton

struct VibrantTextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .vibrant, color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

}

// MARK: - OpaqueTextButton

struct OpaqueTextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .opaque, color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

}

// MARK: - TextButton

struct TextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let variant: TextButtonContent<Configuration.Label>.Variant = AM.useGlass ? .glass : (AM.useVibrant ? .vibrant : .opaque)
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: variant, color: color, borderColor: borderColor, active: active, activeTint: activeTint)
    }

}

extension ButtonStyle where Self == TextButton {
    static var text: TextButton {
        TextButton()
    }
    static func text(color: Color = .primary.opacity(0.8), borderColor: Color? = nil, active: Bool = false, activeTint: Color = .accentColor) -> TextButton {
        TextButton(color: color, borderColor: borderColor, active: active, activeTint: activeTint)
    }
}

extension ButtonStyle where Self == GlassTextButton {
    static var glassText: GlassTextButton {
        GlassTextButton()
    }
}

extension ButtonStyle where Self == VibrantTextButton {
    static var vibrantText: VibrantTextButton {
        VibrantTextButton()
    }
}

extension ButtonStyle where Self == OpaqueTextButton {
    static var opaqueText: OpaqueTextButton {
        OpaqueTextButton()
    }
}

extension ButtonStyle where Self == BorderlessTextButton {
    static var borderlessText: BorderlessTextButton {
        BorderlessTextButton()
    }
    static func borderlessText(color: Color) -> BorderlessTextButton {
        BorderlessTextButton(color: color)
    }
}

// MARK: - BorderlessTextButton

struct BorderlessTextButton: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    var color = Color.primary.opacity(0.8)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 4.0)
            .contentShape(Rectangle())
            .onHover { hover in
                guard isEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) { hovering = hover }
            }
            .opacity(isEnabled ? (hovering ? 1 : 0.8) : 0.6)
    }

    @State private var hovering = false

}

// MARK: - ButtonFlash

/// Transient confirmation message ("Copied", "Link copied", …) that overlays a button.
/// Fills the button's footprint so it shares the button's width and capsule radius; longer
/// text scales down to fit rather than spilling past the button.
struct ButtonFlash: ViewModifier {
    let text: String
    let visible: Bool
    var fontSize: CGFloat = 10
    var tint: Color = .accentColor

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint, in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

extension View {
    func buttonFlash(_ text: String, visible: Bool, fontSize: CGFloat = 10, tint: Color = .accentColor) -> some View {
        modifier(ButtonFlash(text: text, visible: visible, fontSize: fontSize, tint: tint))
    }
}

extension View {
    func transparentTableBackground() -> some View {
        onAppear {
            // Remove opaque backgrounds from NSTableView header and enclosing scroll view
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    for tableView in window.contentView?.findViews(ofType: NSTableView.self) ?? [] {
                        tableView.backgroundColor = .clear
                        tableView.enclosingScrollView?.backgroundColor = .clear
                        tableView.enclosingScrollView?.drawsBackground = false
                        tableView.headerView?.wantsLayer = true
                        tableView.headerView?.layer?.backgroundColor = .clear
                        if let headerClip = tableView.headerView?.superview {
                            headerClip.wantsLayer = true
                            headerClip.layer?.backgroundColor = .clear
                        }
                        // Clear the corner view (top-right square)
                        tableView.enclosingScrollView?.wantsLayer = true
                        if let cornerView = tableView.cornerView {
                            cornerView.wantsLayer = true
                            cornerView.layer?.backgroundColor = .clear
                        }
                    }
                }
            }
        }
    }

    func raisedPanel(cornerRadius: CGFloat = windowCornerRadius) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.background.opacity(0.4))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    func glassOrMaterial(cornerRadius: CGFloat = 18) -> some View {
        if AM.useGlass, #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Full-width translucent bar for floating over preview content: Liquid
    /// Glass on macOS 26 (when enabled), ultra-thin material otherwise. The
    /// image or text underneath shows through it. Outer corners are left square
    /// and clipped to shape by the enclosing panel.
    @ViewBuilder
    func glassBar() -> some View {
        if AM.useGlass, #available(macOS 26, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.ultraThinMaterial)
        }
    }

    /// Adds a double click handler this view (macOS only)
    ///
    /// Example
    /// ```
    /// Text("Hello")
    ///     .onDoubleClick { print("Double click detected") }
    /// ```
    /// - Parameters:
    ///   - handler: Block invoked when a double click is detected
    func onDoubleClick(handler: @escaping () -> Void) -> some View {
        modifier(DoubleClickHandler(handler: handler))
    }
}

extension NSView {
    func findViews<T: NSView>(ofType type: T.Type) -> [T] {
        var found = [T]()
        for sub in subviews {
            if let match = sub as? T { found.append(match) }
            found.append(contentsOf: sub.findViews(ofType: type))
        }
        return found
    }
}

extension View {
    /// SwiftUI's `Table` leaves the backing `NSTableView` on automatic row heights,
    /// which forces an Auto Layout measuring pass over EVERY inserted row when the
    /// data changes in bulk (a fresh search replacing the whole result set). Each
    /// measured row instantiates its cells, and those read `path.memoz.size/.date/.icon`
    /// — synchronous `stat` + icon fetches for local files — so a search returning
    /// thousands of rows ran thousands of disk calls on the main thread inside one
    /// `endUpdates`, freezing the app for 30s+ (CLING-B). The rows here are uniform
    /// single-line cells, so we pin a fixed row height and turn automatic heights off:
    /// `NSTableView` then derives the total content height as `rowCount × rowHeight`
    /// without measuring off-screen rows, and only ever instantiates cells (and touches
    /// `memoz`) for the handful that are actually visible.
    func fixedTableRowHeight(_ height: CGFloat) -> some View {
        background(TableRowHeightConfigurator(rowHeight: height))
    }
}

// MARK: - TableRegistry

/// Weak handles to the results and stash tables' scroll views, so the header-hosted buttons
/// (score sort, stash clear) and the ⌘ sort hints can find their tables.
@MainActor
final class TableRegistry {
    static let shared = TableRegistry()

    /// The results table, which carries the primary column headers (the stash panel has its own
    /// header, but the ⌘ sort hints and the score button live on the results header).
    var headerTableView: NSTableView? {
        resultsScrollView?.documentView as? NSTableView
    }

    /// The stash table, while its panel is on screen (its icon column header hosts the clear button).
    var stashTableView: NSTableView? {
        guard let scrollView = stashScrollView, scrollView.window != nil else { return nil }
        return scrollView.documentView as? NSTableView
    }

    func register(_ scrollView: NSScrollView, isStash: Bool) {
        if isStash { stashScrollView = scrollView } else { resultsScrollView = scrollView }
    }

    private weak var stashScrollView: NSScrollView?
    private weak var resultsScrollView: NSScrollView?
}

extension View {
    /// Registers the table with `TableRegistry` (for the header-hosted buttons). With
    /// `isStash: true` it also hides the scrollbars and blocks user scrolling entirely
    /// while every row fits (`lockVertical`).
    func tableRegistration(
        isStash: Bool,
        lockVertical: Bool = false
    ) -> some View {
        background(TableScrollConfigurator(isStash: isStash, lockVertical: lockVertical))
    }
}

// MARK: - TableScrollConfigurator

private struct TableScrollConfigurator: NSViewRepresentable {
    let isStash: Bool
    let lockVertical: Bool

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        apply(from: nsView)
    }

    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            // The background view spans exactly the frame of the Table it's attached to, so the
            // right scroll view is the one containing its center (in window coordinates). A
            // superview walk can't be trusted here: SwiftUI hosts backgrounds outside the table's
            // subtree, so both tables' walks escalate to the shared container and find the SAME
            // (first) table — which broke mirroring and applied the stash lock to the wrong table.
            guard let window = view.window, let contentView = window.contentView else { return }
            let probe = view.convert(view.bounds, to: nil)
            guard probe.width > 0, probe.height > 0 else { return }
            let center = NSPoint(x: probe.midX, y: probe.midY)
            let scrollView = contentView.findViews(ofType: NSTableView.self)
                .compactMap(\.enclosingScrollView)
                .first { $0.convert($0.bounds, to: nil).contains(center) }
            guard let scrollView else { return }
            // Hard-block scrolling while everything fits: swap in a clip view whose
            // constrainBoundsRect clamps the origin, so pans, momentum and bounces can't
            // move the rows at all.
            // Only when the table uses a plain NSClipView; never discard a custom subclass.
            if isStash, type(of: scrollView.contentView) == NSClipView.self, let doc = scrollView.documentView {
                let old = scrollView.contentView
                let clip = LockableClipView()
                clip.automaticallyAdjustsContentInsets = old.automaticallyAdjustsContentInsets
                clip.contentInsets = old.contentInsets
                clip.drawsBackground = old.drawsBackground
                clip.backgroundColor = old.backgroundColor
                scrollView.contentView = clip
                scrollView.documentView = doc
            }
            TableRegistry.shared.register(scrollView, isStash: isStash)
            // Both tables call these on every update so the header buttons install as soon as
            // their table exists and get cleaned up when it goes away.
            SortHintBadges.shared.syncScoreButton()
            SortHintBadges.shared.syncStashClearButton()
            guard isStash else { return }

            (scrollView.contentView as? LockableClipView)?.lockScrolling = lockVertical
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.hasVerticalScroller = !lockVertical
            scrollView.verticalScrollElasticity = lockVertical ? .none : .automatic
        }
    }
}

// MARK: - SortHintBadges

/// Shows each sort shortcut as a badge at the right edge of its column header while ⌘ is held.
/// Badges are absolutely-positioned subviews INSIDE the table's header view, so they never change
/// any layout, and they ride along with column resizing and horizontal scrolling for free.
@MainActor
final class SortHintBadges {
    static let shared = SortHintBadges()

    func setVisible(_ visible: Bool) {
        hintsVisible = visible
        hide()
        syncScoreButton()
        syncStashClearButton()
        guard visible, let table = TableRegistry.shared.headerTableView,
              let header = table.headerView else { return }
        for (index, column) in table.tableColumns.enumerated() {
            guard let name = Self.shortcutByColumnTitle[column.title],
                  let shortcut = KeyboardShortcuts.getShortcut(for: name) else { continue }
            let badge = NSHostingView(rootView: SortHintBadge(text: shortcut.description))
            badge.frame.size = badge.fittingSize
            let colRect = table.rect(ofColumn: index)
            let x = colRect.maxX - badge.frame.width - 6
            // Skip badges that wouldn't fit next to the title in a narrow column.
            guard x >= colRect.minX + 30 else { continue }
            badge.frame.origin = NSPoint(x: x, y: (header.frame.height - badge.frame.height) / 2)
            header.addSubview(badge)
            badges.append(badge)
        }
    }

    /// Keeps the score-sort button installed in the (otherwise empty) icon column's header slot
    /// of whichever table currently shows headers. While ⌘ is held the button's spot shows the
    /// relevance shortcut badge instead: the 20pt column only fits one element at a time.
    /// Idempotent; the table configurators call it on every update so the button follows the
    /// headers when they move between the stash and results tables.
    func syncScoreButton() {
        guard let table = TableRegistry.shared.headerTableView, let header = table.headerView,
              !table.tableColumns.isEmpty
        else {
            scoreHost?.removeFromSuperview()
            scoreHost = nil
            return
        }
        let host = scoreHost ?? NSHostingView(rootView: ScoreHeaderCell(hintText: nil))
        scoreHost = host
        host.rootView = ScoreHeaderCell(
            hintText: hintsVisible ? KeyboardShortcuts.getShortcut(for: .clSortByScore)?.description : nil
        )
        if host.superview !== header {
            host.removeFromSuperview()
            header.addSubview(host)
        }
        host.frame.size = host.fittingSize
        let colRect = table.rect(ofColumn: 0)
        host.frame.origin = NSPoint(
            // Center in the icon column; a wider hint badge left-anchors and overflows rightward.
            x: colRect.minX + max(2, (colRect.width - host.frame.width) / 2),
            y: (header.frame.height - host.frame.height) / 2
        )
    }

    /// Same idea as `syncScoreButton`, for the stash table: a red trash button in its icon
    /// column's header that clears the stash, swapped for the clear-shortcut badge while ⌘ is held.
    func syncStashClearButton() {
        guard let table = TableRegistry.shared.stashTableView, let header = table.headerView,
              !table.tableColumns.isEmpty
        else {
            stashClearHost?.removeFromSuperview()
            stashClearHost = nil
            return
        }
        let host = stashClearHost ?? NSHostingView(rootView: StashClearHeaderCell(hintText: nil))
        stashClearHost = host
        host.rootView = StashClearHeaderCell(
            hintText: hintsVisible ? KeyboardShortcuts.getShortcut(for: .clStashClear)?.description : nil
        )
        if host.superview !== header {
            host.removeFromSuperview()
            header.addSubview(host)
        }
        host.frame.size = host.fittingSize
        let colRect = table.rect(ofColumn: 0)
        host.frame.origin = NSPoint(
            x: colRect.minX + max(2, (colRect.width - host.frame.width) / 2),
            y: (header.frame.height - host.frame.height) / 2
        )
    }

    private static let shortcutByColumnTitle: [String: KeyboardShortcuts.Name] = [
        "Name": .clSortByName,
        "Path": .clSortByPath,
        "Size": .clSortBySize,
        "Date Modified": .clSortByDate,
    ]

    private var badges: [NSView] = []
    private var hintsVisible = false
    private var scoreHost: NSHostingView<ScoreHeaderCell>?
    private var stashClearHost: NSHostingView<StashClearHeaderCell>?

    private func hide() {
        badges.forEach { $0.removeFromSuperview() }
        badges = []
    }
}

// MARK: - ScoreHeaderCell

/// The icon column's header content: the relevance-sort flag button, or (while ⌘ is held)
/// the same hint badge style the other column headers use.
private struct ScoreHeaderCell: View {
    let hintText: String?

    var body: some View {
        if let hintText, !hintText.isEmpty {
            SortHintBadge(text: hintText)
        } else {
            Button {
                NotificationCenter.default.post(name: .clingSortByScore, object: nil)
            } label: {
                Image(systemName: "flag.pattern.checkered.circle" + (fuzzy.sortField == .score ? ".fill" : ""))
                    .font(.system(size: 13))
                    .opacity(fuzzy.sortField == .score ? 1 : 0.5)
            }
            .buttonStyle(.borderless)
            .help("Sort by score (\(KeyboardShortcuts.getShortcut(for: .clSortByScore)?.description ?? "⌃0"))")
        }
    }

    @State private var fuzzy: FuzzyClient = FUZZY
}

// MARK: - SortHintBadge

private struct SortHintBadge: View {
    let text: String
    var color: Color = ShortcutTint.action

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - StashClearHeaderCell

/// The stash table's icon column header content: a red trash button that clears the stash,
/// or (while ⌘ is held) the clear shortcut's hint badge.
private struct StashClearHeaderCell: View {
    let hintText: String?

    var body: some View {
        if let hintText, !hintText.isEmpty {
            SortHintBadge(text: hintText, color: .red)
        } else {
            Button {
                STASH.clear()
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
                    .opacity(0.75)
            }
            .buttonStyle(.borderless)
            .help("Remove all files from the stash (\(KeyboardShortcuts.getShortcut(for: .clStashClear)?.description ?? "⇧⌘S"))")
        }
    }
}

// MARK: - LockableClipView

/// Clip view that refuses user scrolling entirely while `lockScrolling` is set: the stash table
/// shows all its rows, so pans/momentum/bounces would only jiggle the pinned rows. User scrolls
/// come through `scroll(to:)` and hit this clamp; the horizontal mirroring from the results table
/// mutates the bounds origin directly, bypassing it, so column alignment still follows.
private final class LockableClipView: NSClipView {
    var lockScrolling = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if lockScrolling {
            rect.origin.y = -contentInsets.top
            rect.origin.x = bounds.origin.x
        }
        return rect
    }
}

// MARK: - TableRowHeightConfigurator

private struct TableRowHeightConfigurator: NSViewRepresentable {
    let rowHeight: CGFloat

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        apply(from: nsView)
    }

    /// The table may not be in the window hierarchy yet on the first pass, so run on
    /// the next tick and re-run on every SwiftUI update (which fires when results
    /// change, covering a table that gets rebuilt). Scoped to this view's own window
    /// so it never touches tables in other windows (e.g. Settings).
    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            guard let contentView = view.window?.contentView else { return }
            for table in contentView.findViews(ofType: NSTableView.self) {
                guard table.usesAutomaticRowHeights || table.rowHeight != rowHeight else { continue }
                table.usesAutomaticRowHeights = false
                table.rowHeight = rowHeight
            }
        }
    }
}

// MARK: - DoubleClickHandler

struct DoubleClickHandler: ViewModifier {
    let handler: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            DoubleClickListeningViewRepresentable(handler: handler)
        }
    }
}

// MARK: - DoubleClickListeningViewRepresentable

struct DoubleClickListeningViewRepresentable: NSViewRepresentable {
    let handler: () -> Void

    func makeNSView(context: Context) -> DoubleClickListeningView {
        DoubleClickListeningView(handler: handler)
    }
    func updateNSView(_ nsView: DoubleClickListeningView, context: Context) {}
}

// MARK: - DoubleClickListeningView

class DoubleClickListeningView: NSView {
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    let handler: () -> Void

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            handler()
        }
    }
}
